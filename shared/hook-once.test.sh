#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for hook-once.sh with a counting stub script beside a copy of it. The two-install case
# end to end is bridge/agent-harness/codex-hooks-once.test.sh; this suite pins the edges where
# the claim must step aside and let the script run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
D="$TMP/scripts"; mkdir -p "$D"; cp "$HERE/hook-once.sh" "$D/"
printf '#!/bin/bash\ncat >/dev/null\necho ran >> "$COUNT_LOG"\nexit "${STUB_EXIT:-0}"\n' > "$D/gate.sh"; chmod +x "$D/gate.sh"
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for t in bash cat tr date id mkdir chmod find dirname; do p=$(command -v "$t") && ln -sf "$p" "$NOJQ/$t"; done
CALL='{"session_id":"s","tool_use_id":"t1","tool_input":{"command":"ls"}}'

# go <tmpdir> <env...>: run the stub through hook-once.sh twice on one payload; print
# "<times it ran> <first exit> <second exit>".
go() {
  local tdir="$1"; shift; : > "$TMP/count"
  local a b
  printf '%s' "$CALL" | env TMPDIR="$tdir" COUNT_LOG="$TMP/count" "$@" bash "$D/hook-once.sh" gate.sh; a=$?
  printf '%s' "$CALL" | env TMPDIR="$tdir" COUNT_LOG="$TMP/count" "$@" bash "$D/hook-once.sh" gate.sh; b=$?
  printf '%s %s %s' "$(wc -l < "$TMP/count" | tr -d ' ')" "$a" "$b"
}
mkdir -p "$TMP/t-link-target" "$TMP/t-link"
ln -s "$TMP/t-link-target" "$TMP/t-link/agentic-kit-hook-once-$(id -u)"

# Rows: name | tmpdir | env (space separated) | want "<runs> <exit1> <exit2>"
CASES=(
  "outside Codex the script runs every time|$TMP/t1||2 0 0"
  "as a Codex plugin hook the second delivery is skipped|$TMP/t2|PLUGIN_ROOT=$D|1 0 0"
  "the bridge's request claims too|$TMP/t3|AGENTIC_KIT_HOOK_ONCE=1|1 0 0"
  "the script's exit status is kept|$TMP/t4|PLUGIN_ROOT=$D STUB_EXIT=2|1 2 0"
  "with no jq the script runs every time|$TMP/t5|PLUGIN_ROOT=$D PATH=$NOJQ|2 0 0"
  "a claim folder that is a symlink is not trusted|$TMP/t-link|PLUGIN_ROOT=$D|2 0 0"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name tdir envs want <<<"$row"
  mkdir -p "$tdir"
  # shellcheck disable=SC2086
  got=$(go "$tdir" $envs)
  [ "$got" = "$want" ] && ok "$name" || bad "$name: got [$got], want [$want]"
done

# Two different calls whose ids only differ in where a dot falls each get their own claim.
: > "$TMP/count"; mkdir -p "$TMP/t7"
printf '{"session_id":"a.b","tool_use_id":"c"}' | env TMPDIR="$TMP/t7" COUNT_LOG="$TMP/count" PLUGIN_ROOT="$D" bash "$D/hook-once.sh" gate.sh
printf '{"session_id":"a","tool_use_id":"b.c"}' | env TMPDIR="$TMP/t7" COUNT_LOG="$TMP/count" PLUGIN_ROOT="$D" bash "$D/hook-once.sh" gate.sh
[ "$(wc -l < "$TMP/count" | tr -d ' ')" = 2 ] && ok "ids that join to the same text are still two events" || bad "key collision: ran $(wc -l < "$TMP/count") times, want 2"

# --claim: 0 for the first claimant, 1 for the second; the script itself is not run.
: > "$TMP/count"; mkdir -p "$TMP/t6"
r1=$(printf '%s' "$CALL" | env TMPDIR="$TMP/t6" COUNT_LOG="$TMP/count" AGENTIC_KIT_HOOK_ONCE=1 bash "$D/hook-once.sh" --claim gate.sh; echo $?)
r2=$(printf '%s' "$CALL" | env TMPDIR="$TMP/t6" COUNT_LOG="$TMP/count" AGENTIC_KIT_HOOK_ONCE=1 bash "$D/hook-once.sh" --claim gate.sh; echo $?)
[ "$r1 $r2 $(wc -l < "$TMP/count" | tr -d ' ')" = "0 1 0" ] && ok "--claim answers run, then skip, and runs nothing" || bad "--claim: got [$r1 $r2], ran $(wc -l < "$TMP/count")"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
