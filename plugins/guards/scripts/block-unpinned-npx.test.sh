#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for block-unpinned-npx.sh. Run: bash block-unpinned-npx.test.sh
#
# The hook blocks (exit 2 + a policy reason on stderr) an auto-install npx invocation
# (`-y`/`--yes`) without an exact version pin, wherever it starts a simple command:
# after a separator, after `VAR=value` assignments, or behind a wrapper such as `env`,
# `time` or `sudo`. Pinned invocations, local-bin npx (no -y) and other commands pass.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/block-unpinned-npx.sh"
pass=0; fail=0
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

# A project whose node_modules/.bin holds tsc and foo: the payload's cwd, so `npx tsc` is a local bin.
PROJ="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$PROJ"' EXIT
mkdir -p "$PROJ/node_modules/.bin"
for b in tsc foo; do printf '#!/bin/sh\n' > "$PROJ/node_modules/.bin/$b"; chmod +x "$PROJ/node_modules/.bin/$b"; done
payload() { jq -nc --arg c "$1" --arg d "$PROJ" '{tool_input:{command:$c},cwd:$d}'; }

# Rows: want (block|allow) | name | command
CASES=(
  "block|unpinned npx -y|npx -y @modelcontextprotocol/server-memory"
  "block|npx -y @latest dist-tag|npx -y @playwright/mcp@latest"
  "block|npx --yes unpinned|npx --yes typescript"
  "block|chained, unpinned in tail|npm test && npx -y some-server"
  "block|env assignment prefix|FOO=1 npx -y left-pad"
  "block|two env assignments|A=1 B=two npx -y left-pad"
  "block|env wrapper|env npx -y left-pad"
  "block|env wrapper with option and assignment|env -i PATH=/usr/bin npx -y left-pad"
  "block|time wrapper|time npx --yes left-pad"
  "block|sudo wrapper|sudo -E npx -y left-pad"
  "block|sudo with an option argument|sudo -u root npx -y left-pad"
  "block|nice with a numeric argument|nice -n 10 npx -y left-pad"
  "allow|time wrapper, pinned|time -p npx -y left-pad@2.0.0"
  "block|command wrapper|command npx -y left-pad"
  "block|exec wrapper|exec npx -y left-pad"
  "block|nohup wrapper after a separator|cd x; nohup npx -y left-pad"
  "block|npx by path|./node_modules/.bin/npx -y left-pad"
  "block|inside a subshell|(npx -y left-pad)"
  "block|on a later line|echo hi
npx -y left-pad"
  "allow|pinned npx -y x.y.z|npx -y @modelcontextprotocol/server-memory@2025.10.14"
  "block|a major-only pin is not exact|npx -y cowsay@1"
  "block|a major.minor pin is not exact|npx -y cowsay@1.2"
  "allow|a prerelease pin is exact|npx -y cowsay@1.2.3-rc.1"
  "allow|a build suffix is exact|npx -y cowsay@1.2.3+build.5"
  "block|inside braces|{ npx -y cowsay; }"
  "block|after then|if true; then npx -y cowsay; fi"
  "block|after !|! npx -y cowsay"
  "block|inside backticks|echo \`npx -y cowsay\`"
  "block|behind eval|eval npx -y cowsay"
  "block|with a backslash|\\npx -y cowsay"
  "block|behind timeout with a duration|timeout 60 npx -y cowsay"
  "block|behind xargs|xargs npx -y cowsay"
  "block|a -p package is the package|npx -p cowsay -y cowsay"
  "block|a --package= package is the package|npx --package=cowsay@latest -y cowsay@1.0.0"
  "allow|a pinned -p package|npx -p cowsay@1.0.0 -y cowsay"
  "block|--yes=true is auto-install|npx --yes=true cowsay"
  "allow|chained, pinned|echo hi; npx -y some-server@1.2.3"
  "allow|env prefix, pinned|FOO=1 npx -y left-pad@1.3.0"
  "allow|plain npx local bin (no -y)|npx tsc --noEmit"
  "block|plain npx of a package that is not installed installs it|npx create-widget"
  "block|plain npx of a local bin name from elsewhere|cd /tmp && npx tsc --noEmit"
  "allow|--no never installs|npx --no create-widget"
  "allow|--no-install never installs|npx --no-install create-widget"
  "allow|a pinned plain npx|npx create-widget@2.4.1"
  "block|-y with a local bin name still installs a package|npx -y tsc"
  "allow|env prefix, local bin|FOO=1 npx tsc --noEmit"
  "allow|a bare local bin name|npx foo"
  "block|a dist-tag fetches from the registry despite a local bin|npx foo@latest"
  "block|another dist-tag fetches from the registry despite a local bin|npx foo@next"
  "block|a scoped name fetches from the registry despite a local bin|npx @other/foo"
  "allow|non-npx command|git status"
  "allow|npx only as an argument|echo npx -y left-pad"
  "allow|grep for npx|grep -n npx README.md"
  "allow|empty command|"
  "block|inside a quoted bash -c string|bash -c 'npx -y left-pad'"
  "allow|inherent: npx behind a variable is not seen|X=npx; \$X -y left-pad"
)
for row in "${CASES[@]}"; do
  want=${row%%|*}; rest=${row#*|}; name=${rest%%|*}; cmd=${rest#*|}
  err=$(printf '%s' "$(payload "$cmd")" | bash "$HOOK" 2>&1 >/dev/null); rc=$?
  if [ "$want" = block ]; then
    if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qF "Blocked by policy"; then
      echo "PASS: $name"; pass=$((pass + 1))
    else echo "FAIL: $name (rc=$rc, want 2, stderr: $err)"; fail=$((fail + 1)); fi
  else
    if [ "$rc" -eq 0 ]; then echo "PASS: $name"; pass=$((pass + 1))
    else echo "FAIL: $name (rc=$rc, want 0, stderr: $err)"; fail=$((fail + 1)); fi
  fi
done

# Without jq on PATH: a command that names npx is blocked with a reason naming jq; others pass.
NOJQ="$(mktemp -d)"; for t in bash cat tr grep sed; do p=$(command -v "$t" 2>/dev/null) && [ -n "$p" ] && [ "${p#/}" != "$p" ] && ln -sf "$p" "$NOJQ/$t"; done
# Rows: want exit | name | command
NOJQ_CASES=(
  "2|no jq: unpinned npx -y is blocked|npx -y left-pad"
  "2|no jq: a pinned npx is blocked too, it cannot be checked|npx -y left-pad@1.3.0"
  "2|no jq: npx after a separator is blocked|cd web && npx -y left-pad"
  "2|no jq: npx by path is blocked|./node_modules/.bin/npx tsc"
  "0|no jq: a command without npx passes|git status"
  "0|no jq: a word that contains npx passes|echo npx-cache"
)
for row in "${NOJQ_CASES[@]}"; do
  IFS='|' read -r want name cmd <<<"$row"
  err=$(printf '{"tool_input":{"command":"%s"}}' "$cmd" | PATH="$NOJQ" "$(command -v bash)" "$HOOK" 2>&1 >/dev/null); rc=$?
  if [ "$rc" -eq "$want" ] && { [ "$want" -eq 0 ] || printf '%s' "$err" | grep -q 'jq is not installed'; }; then
    echo "PASS: $name"; pass=$((pass + 1))
  else echo "FAIL: $name (rc=$rc, want $want, stderr: $err)"; fail=$((fail + 1)); fi
done
rm -rf "$NOJQ"

# Robustness: empty or malformed stdin never crashes and never blocks.
for input in '' 'not json {{'; do
  printf '%s' "$input" | bash "$HOOK" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then echo "PASS: stdin [$input] rc=0"; pass=$((pass + 1))
  else echo "FAIL: stdin [$input] rc=$rc"; fail=$((fail + 1)); fi
done

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
