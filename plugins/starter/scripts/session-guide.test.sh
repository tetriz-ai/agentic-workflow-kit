#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for session-guide.sh: it emits the guide as SessionStart additionalContext, without the
# skill's frontmatter, stays small, and is silent (exit 0) when it cannot run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/session-guide.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
TMP="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT

out=$(printf '{"hook_event_name":"SessionStart","source":"startup"}' | bash "$SUT"); rc=$?
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
c_exit()     { [ "$rc" = 0 ]; }
c_event()    { [ "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)" = SessionStart ]; }
c_table()    { printf '%s' "$ctx" | grep -q "/ship:pr"; }
c_no_fm()    { ! printf '%s' "$ctx" | grep -q "^description:"; }
c_small()    { [ "$(printf '%s' "$ctx" | wc -c)" -lt 2048 ]; }
# Rows: name | check function
CASES=(
  "exits 0|c_exit"
  "emits SessionStart additionalContext|c_event"
  "carries the situation table|c_table"
  "drops the frontmatter|c_no_fm"
  "stays under 2 KB, since every session pays for it|c_small"
)
for row in "${CASES[@]}"; do
  name=${row%%|*}; check=${row#*|}
  if "$check"; then ok "$name"; else bad "$name"; fi
done

# Silent when jq is missing.
NOJQ="$TMP/bin"; mkdir -p "$NOJQ"; for t in bash awk cat dirname; do ln -s "$(command -v $t)" "$NOJQ/$t"; done
out=$(printf '{}' | PATH="$NOJQ" "$(command -v bash)" "$SUT" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "silent with no jq" || bad "no jq (exit $rc, out [$out])"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
