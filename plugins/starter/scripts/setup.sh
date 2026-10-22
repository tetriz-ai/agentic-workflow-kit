#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# setup.sh: write the repo files the agentic-workflow-kit plugins cannot install themselves. Run
# from inside the repo (the /starter:setup skill shows the plan and asks before applying).
#
# Usage: setup.sh plan
#        setup.sh apply <part>... [--set <key>=<value>]... [--force]
# Parts:
#   config           .agentic-workflow-kit.json: the --set values merged into it (keys from
#                    files/settings.json; the file is the settings channel Codex reads)
#   deny             .claude/settings.json permissions.deny: the kit's deny list merged in, plus
#                    push denies for the base branch when it is not main or master
#   rules            .claude/rules/*.md: the always-on and path-scoped starter rules
#   rule-index       .claude/rules/rule-index.md and scripts/check-rule-index.sh (run it in CI)
#   githooks         .githooks/post-checkout and pre-push; core.hooksPath set only when unset
#   gitignore        .gitignore: the kit's local state folders appended when missing
#   worktreeinclude  .worktreeinclude: an example, for the worktrees plugin to copy local files
# A file the repo already has with different content is kept and reported, unless --force.
# Settings, the deny list and .gitignore are merged, never replaced. Applying twice is a no-op.
# A destination that leads out of the repo through a symlink is refused before anything is written.
# Exit: 0 done | 1 done, but some files were kept (listed) | 2 usage error or a refused destination.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$HERE/../files"
PARTS="config deny rules rule-index githooks gitignore worktreeinclude"
usage() { echo "usage: setup.sh plan | setup.sh apply <part>... [--set key=value]... [--force]   (parts: $PARTS)" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "setup: jq is required" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "setup: run inside a git repository" >&2; exit 2; }

mode="${1:-}"; shift || true
parts=(); sets=(); force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force=1; shift ;;
    --set) [ $# -ge 2 ] || usage; sets+=("$2"); shift 2 ;;
    -*) usage ;;
    *) case " $PARTS " in *" $1 "*) parts+=("$1"); shift ;; *) echo "setup: unknown part '$1'" >&2; usage ;; esac ;;
  esac
done

# Validate every --set before anything is written.
for kv in "${sets[@]:-}"; do
  [ -n "$kv" ] || continue
  k="${kv%%=*}"
  [[ "$k" =~ ^[a-z][a-z0-9_]*$ ]] && [ "$k" != "$kv" ] || { echo "setup: --set wants key=value with a snake_case key (got '$kv')" >&2; exit 2; }
  jq -e --arg k "$k" 'has($k)' "$FILES/settings.json" >/dev/null || { echo "setup: '$k' is not a kit setting (see docs/settings.md)" >&2; exit 2; }
done

kept=0
note() { printf '%-6s %s\n' "$1" "$2"; }

# contained <rel>: refuse (exit 2, nothing written) when <rel>, or a folder above it, is a symlink
# that leads out of the repo. Writing through it would change a file the repo does not own.
[ -r "$HERE/path-contained.sh" ] || { echo "setup: path-contained.sh is missing beside setup.sh" >&2; exit 2; }
# shellcheck source=path-contained.sh
. "$HERE/path-contained.sh"
contained() {
  local real
  real="$(path_contained "$ROOT" "$ROOT/$1")" && return 0
  echo "setup: $1 leads to ${real:-a path that cannot be resolved}, outside the repo ($ROOT), through a symlink; refusing to write it. Nothing was written." >&2
  exit 2
}

# put <source> <dest relative to ROOT> [mode]: copy unless the dest differs and --force is unset.
put() {
  local src="$1" dst="$ROOT/$2"
  contained "$2"
  if [ -e "$dst" ] && cmp -s "$src" "$dst"; then note same "$2"; return 0; fi
  if [ -e "$dst" ] && [ "$force" -eq 0 ]; then note keep "$2 (differs from the kit's; --force to replace)"; kept=1; return 0; fi
  mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; [ -z "${3:-}" ] || chmod "$3" "$dst"; note write "$2"
}

# merge_json <dest> <jq filter> [jq args...]: apply a filter to the dest JSON (an empty object when
# missing, empty or only whitespace) and write the result only when it changed. Notes `write` for
# a new or empty file, `merge` for one that had content.
merge_json() {
  local rel="$1" filter="$2"; shift 2
  local dst="$ROOT/$rel" before='{}' after had=0
  contained "$rel"
  if [ -f "$dst" ] && grep -q '[^[:space:]]' "$dst"; then before="$(cat "$dst")"; had=1; fi
  after="$(printf '%s' "$before" | jq "$@" "$filter")" || { echo "setup: $rel is not valid JSON; fix it first" >&2; exit 2; }
  if [ "$had" = 1 ] && [ "$(printf '%s' "$before" | jq -S .)" = "$(printf '%s' "$after" | jq -S .)" ]; then note same "$rel"; return 0; fi
  mkdir -p "$(dirname "$dst")"; printf '%s\n' "$after" > "$dst"
  if [ "$had" = 1 ]; then note merge "$rel"; else note write "$rel"; fi
}

# append_lines <dest> <line>...: append each line the dest lacks (an exact whole-line match),
# first ending the file with a newline when it lacks one. Notes write, merge or same.
append_lines() {
  local rel="$1" dst="$ROOT/$1" line added=0 new=0; shift
  contained "$rel"
  [ -s "$dst" ] || new=1
  mkdir -p "$(dirname "$dst")"; touch "$dst"
  for line in "$@"; do
    grep -qxF -- "$line" "$dst" && continue
    [ -s "$dst" ] && [ -n "$(tail -c 1 "$dst")" ] && printf '\n' >> "$dst"
    printf '%s\n' "$line" >> "$dst"; added=1
  done
  if [ "$added" = 0 ]; then note same "$rel"; elif [ "$new" = 1 ]; then note write "$rel"; else note merge "$rel"; fi
}

base_branch() { # the base branch: a --set value, else the repo settings file, else main
  local kv b=""
  for kv in "${sets[@]:-}"; do [ "${kv%%=*}" = base_branch ] && b="${kv#*=}"; done
  [ -n "$b" ] || b="$(jq -r '.base_branch // empty' "$ROOT/.agentic-workflow-kit.json" 2>/dev/null)"
  printf '%s' "${b:-main}"
}

# destinations <part>: the repo paths a part writes.
destinations() {
  local f
  case "$1" in
    config) echo .agentic-workflow-kit.json ;;
    deny) echo .claude/settings.json ;;
    rules) for f in "$FILES"/rules/*.md; do [ "$(basename "$f")" = rule-index.md ] || echo ".claude/rules/$(basename "$f")"; done ;;
    rule-index) echo .claude/rules/rule-index.md scripts/check-rule-index.sh ;;
    githooks) echo .githooks/post-checkout .githooks/pre-push ;;
    gitignore) echo .gitignore ;;
    worktreeinclude) echo .worktreeinclude ;;
  esac
}

do_part() {
  case "$1" in
    config)
      local args=() kv k v t
      local filter='.'
      for kv in "${sets[@]:-}"; do
        [ -n "$kv" ] || continue
        k="${kv%%=*}"; v="${kv#*=}"; t="$(jq -r --arg k "$k" '.[$k].type' "$FILES/settings.json")"
        if [ "$t" = number ]; then
          [[ "$v" =~ ^[0-9]+$ ]] || { echo "setup: $k takes a whole number (got '$v')" >&2; exit 2; }
          filter="$filter | .[\"$k\"] = $v"
        else
          args+=(--arg "v_$k" "$v"); filter="$filter | .[\"$k\"] = \$v_$k"
        fi
      done
      merge_json .agentic-workflow-kit.json "$filter" ${args[@]+"${args[@]}"} ;;
    deny)
      local b extra='[]'
      b="$(base_branch)"
      case "$b" in main|master) ;; *) extra="$(jq -nc --arg b "$b" '["Bash(git push * \($b))", "Bash(git push * \($b) -*)", "Bash(git push * +\($b))", "Bash(git push * +\($b) *)", "Bash(git push *:\($b))", "Bash(git push *:refs/heads/\($b))", "Bash(git push *:refs/heads/\($b) *)"]')" ;; esac
      merge_json .claude/settings.json \
        '.permissions = (.permissions // {}) | .permissions.deny = (((.permissions.deny // []) + $kit + $extra) | reduce .[] as $d ([]; if index([$d]) then . else . + [$d] end))' \
        --argjson kit "$(jq -c '.deny' "$FILES/settings/deny.json")" --argjson extra "$extra" ;;
    rules)
      local f
      for f in "$FILES"/rules/*.md; do [ "$(basename "$f")" = rule-index.md ] || put "$f" ".claude/rules/$(basename "$f")"; done ;;
    rule-index)
      put "$FILES/rules/rule-index.md" .claude/rules/rule-index.md
      put "$FILES/scripts/check-rule-index.sh" scripts/check-rule-index.sh 755 ;;
    githooks)
      local h cur
      for h in post-checkout pre-push; do put "$FILES/githooks/$h" ".githooks/$h" 755; done
      cur="$(git -C "$ROOT" config --get core.hooksPath || true)"
      # Hooks already live in .git/hooks (anything but the *.sample files git ships): setting
      # core.hooksPath would switch them off, so leave it and say so.
      local gitdir_hooks live
      gitdir_hooks="$(cd "$ROOT" && git rev-parse --path-format=absolute --git-path hooks 2>/dev/null || true)"
      live="$(find "$gitdir_hooks" -maxdepth 1 -type f ! -name '*.sample' 2>/dev/null | sed 's#.*/##' | sort | tr '\n' ' ')"
      if [ -z "$cur" ] && [ -n "$live" ]; then note keep "core.hooksPath unset: .git/hooks has ${live% }, which core.hooksPath would switch off (call .githooks/post-checkout and .githooks/pre-push from them)"
      elif [ -z "$cur" ]; then git -C "$ROOT" config core.hooksPath .githooks; note set "core.hooksPath = .githooks"
      elif [ "$cur" = .githooks ]; then note same "core.hooksPath = .githooks"
      else note keep "core.hooksPath = $cur (call .githooks/post-checkout and .githooks/pre-push from your hooks)"; fi ;;
    gitignore)
      append_lines .gitignore .claude/triage/ .claude/review-cadence/ .claude/worktrees/ ;;
    worktreeinclude)
      put "$FILES/worktreeinclude.example" .worktreeinclude ;;
  esac
}

case "$mode" in
  plan)
    echo "setup plan for $ROOT (nothing is written by plan):"
    for p in $PARTS; do
      case "$p" in
        config) echo "  config           .agentic-workflow-kit.json  ($( [ -f "$ROOT/.agentic-workflow-kit.json" ] && echo "exists, merged" || echo new))" ;;
        deny) echo "  deny             .claude/settings.json permissions.deny  ($( [ -f "$ROOT/.claude/settings.json" ] && echo "exists, merged" || echo new))" ;;
        rules) n=0; for f in "$FILES"/rules/*.md; do [ "$(basename "$f")" = rule-index.md ] || n=$((n + 1)); done
               echo "  rules            .claude/rules/ ($n files)" ;;
        rule-index) echo "  rule-index       .claude/rules/rule-index.md, scripts/check-rule-index.sh" ;;
        githooks) echo "  githooks         .githooks/ (core.hooksPath now: $(git -C "$ROOT" config --get core.hooksPath || echo unset))" ;;
        gitignore) echo "  gitignore        .gitignore: .claude/triage/ .claude/review-cadence/ .claude/worktrees/" ;;
        worktreeinclude) echo "  worktreeinclude  .worktreeinclude ($( [ -f "$ROOT/.worktreeinclude" ] && echo exists || echo new))" ;;
      esac
    done ;;
  apply)
    [ "${#parts[@]}" -gt 0 ] || usage
    # Check every destination first, so a refused one leaves the repo as it was.
    for p in "${parts[@]}"; do for d in $(destinations "$p"); do contained "$d"; done; done
    for p in "${parts[@]}"; do do_part "$p"; done
    [ "$kept" -eq 0 ] || exit 1 ;;
  *) usage ;;
esac
exit 0
