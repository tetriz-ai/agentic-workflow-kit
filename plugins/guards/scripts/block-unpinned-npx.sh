#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# PreToolUse hook (matcher: Bash) — blocks an npx call that would install a package from the
# registry without an exact pinned version.
#
# npx installs a missing package without prompting when stdin is not a terminal, which is how an
# agent runs it, so every call counts as an install unless it passes `--no`/`--no-install` or its
# command is a bin already in `<cwd>/node_modules/.bin` (a local `npx tsc`), where `<cwd>` is the
# command's leading `cd <dir>`, else the tool's working directory. `-y`/`--yes`/`--yes=<value>`
# install explicitly. The package is the `-p`/`--package` value when one is given (each one is checked),
# else the first word after npx's options. It must end in an exact `@x.y.z` version, with an
# optional prerelease or build suffix (`@1.2.3-rc.1`); `@latest`, dist-tags, `@1` and `@1.2`
# are blocked.
#
# npx is found wherever it starts a simple command (lib/cwd-resolve.sh simple_commands):
# after a separator, a brace or a backtick, after `VAR=value` assignments and shell keywords
# (`if`, `then`, `!`), behind wrappers such as `env`, `sudo`, `timeout` or `eval`, inside
# `bash -c '...'`, and with a backslash before it. npx behind a variable (`X=npx; $X -y x`)
# is not seen.
#
# Exit 2 + stderr = block the tool call and surface the reason to Claude.
#
# Without jq the payload cannot be parsed, so any command that names npx is blocked with a
# reason (a missing tool must not let an unpinned install through); other commands pass.

input=$(cat)
names_npx() { printf '%s' "$1" | grep -qE '(^|[^A-Za-z0-9_.-])npx([^A-Za-z0-9_.-]|$)'; }
if ! command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$input" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p')
  if names_npx "$cmd"; then
    echo "Blocked by policy: jq is not installed, so this npx command cannot be checked for a pinned version. Install jq." >&2
    exit 2
  fi
  exit 0
fi
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0
names_npx "$cmd" || exit 0

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/cwd-resolve.sh"
if [ ! -r "$lib" ]; then
  echo "Blocked by policy: lib/cwd-resolve.sh is missing, so this npx command cannot be checked." >&2
  exit 2
fi
# shellcheck source=lib/cwd-resolve.sh
. "$lib"

pinned() { printf '%s' "$1" | grep -qE '@[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'; }
block() {
  local name=${1%@*}
  [ -n "$name" ] || name=$1   # a scoped name with no version (`@scope/pkg`)
  echo "Blocked by policy: '$1' is not pinned to an exact version." >&2
  echo "Use: npx -y $name@<x.y.z> (check npm view $name version)" >&2
  exit 2
}

base=$(tool_cwd "$input"); base=${base:-$PWD}
cd_dir=$(leading_cd_dir "$cmd" "$base"); [ -n "$cd_dir" ] && base=$cd_dir
while IFS= read -r line; do
  read -r -a w <<<"$line"
  n=${#w[@]}; auto=1; explicit=0; pkg=""; pkgs=()
  for ((j = 1; j < n; j++)); do
    case "${w[$j]}" in
      --no|--no-install|--yes=false) auto=0 ;;
      -y|--yes|--yes=*) explicit=1 ;;
      -p|--package) j=$((j + 1)); [ "$j" -lt "$n" ] && pkgs+=("${w[$j]}") ;;
      --package=*) pkgs+=("${w[$j]#--package=}") ;;
      -c|--call) j=$((j + 1)) ;;
      -*) ;;
      *) pkg=${w[$j]}; break ;;
    esac
  done
  [ "$explicit" -eq 1 ] || [ "$auto" -eq 1 ] || continue
  # A local bin runs without an install (unless -y or a -p package asks for one). Only a bare
  # name counts: npx fetches `foo@latest` or `@other/foo` from the registry even when a local
  # `foo` exists.
  if [ "$explicit" -eq 0 ] && [ "${#pkgs[@]}" -eq 0 ] && [ -n "$pkg" ]; then
    case "$pkg" in
      *@*|*/*) ;;
      *) [ -x "$base/node_modules/.bin/$pkg" ] && continue ;;
    esac
  fi
  if [ "${#pkgs[@]}" -gt 0 ]; then
    for p in "${pkgs[@]}"; do pinned "$p" || block "$p"; done
  elif [ -n "$pkg" ]; then
    pinned "$pkg" || block "$pkg"
  fi
done < <(simple_commands "$cmd" npx)
exit 0
