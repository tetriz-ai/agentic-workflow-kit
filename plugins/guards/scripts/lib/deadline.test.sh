#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for deadline.sh. Run: bash deadline.test.sh
#   - deadline_cap turns a commit_gate_timeout value into the seconds to wait: at most 570, the
#     default for a value that is not a whole number of seconds, with a warning for each fix-up;
#   - run_with_deadline returns the command's status, or 124 at the deadline, and at the
#     deadline stops the command's whole process tree, grandchildren included.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=deadline.sh
. "$HERE/deadline.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
TMP="$(cd "$(mktemp -d)" && pwd -P)"
MARK="47$$"
trap 'pkill -f "sleep $MARK" 2>/dev/null; rm -rf "$TMP"' EXIT

# Rows: name | value | want seconds | want text in the warning (- = no warning)
CAP_CASES=(
  "a value in range is kept|120|120|-"
  "the top of the range is kept|570|570|-"
  "blank means the default|||-"
  "a value above 570 is clamped|9999|570|above 570"
  "571 is clamped|571|570|above 570"
  "a word is not a number|abc|570|not a whole number"
  "zero is not a deadline|0|570|not a whole number"
  "a negative value is not a number|-5|570|not a whole number"
  "a fraction is not a whole number|1.5|570|not a whole number"
  "a very long number is clamped|123456789012|570|above 570"
)
for row in "${CAP_CASES[@]}"; do
  IFS='|' read -r name value want warn <<<"$row"
  [ -n "$want" ] || want=570
  got=$(deadline_cap "$value" 2>"$TMP/warn"); rc=$?
  if [ "$warn" = - ]; then warned=$([ -s "$TMP/warn" ] && echo yes || echo no); want_warned=no
  else warned=$(grep -c "$warn" "$TMP/warn" | tr -d ' '); want_warned=1; fi
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ] && [ "$warned" = "$want_warned" ]; then ok "$name"
  else bad "$name (got '$got' rc=$rc, warning: $(cat "$TMP/warn"))"; fi
done

# Rows: name | seconds | command | want status
RUN_CASES=(
  "a passing command returns 0|10|true|0"
  "a failing command returns its status|10|exit 3|3"
  "a command past the deadline returns 124|1|sleep 30|124"
)
for row in "${RUN_CASES[@]}"; do
  IFS='|' read -r name cap cmd want <<<"$row"
  rc=0; run_with_deadline "$cap" "$TMP/out" sh -c "$cmd" || rc=$?
  [ "$rc" -eq "$want" ] && ok "$name" || bad "$name (rc=$rc, want $want)"
done

# At the deadline the whole tree stops: a grandchild (a test runner's own child) is not left
# running. The inner sh runs two commands, so it forks sleep rather than exec'ing it.
start=$SECONDS
rc=0; run_with_deadline 1 "$TMP/out" sh -c "sh -c 'sleep $MARK; true'; true" || rc=$?
left=1
for _ in 1 2 3 4 5; do
  pgrep -f "sleep $MARK" >/dev/null 2>&1 || { left=0; break; }
  sleep 1
done
[ "$rc" -eq 124 ] && ok "a timed-out tree returns 124" || bad "a timed-out tree returns 124 (rc=$rc)"
[ "$left" -eq 0 ] && ok "no grandchild is left after the deadline" || bad "a grandchild survived the deadline: $(pgrep -fl "sleep $MARK")"
[ $((SECONDS - start)) -lt 15 ] && ok "the tree is stopped within the grace period" || bad "stopping took $((SECONDS - start))s"

# The deadline is wall-clock time: a watchdog whose `sleep 1` takes longer (a loaded machine,
# here a stub that sleeps 3 seconds a call) still stops the command at the deadline plus grace.
SLOW="$TMP/slow"; mkdir -p "$SLOW"
printf '#!/bin/sh\nexec %s 3\n' "$(command -v sleep)" > "$SLOW/sleep"; chmod +x "$SLOW/sleep"
start=$SECONDS
rc=0; PATH="$SLOW:$PATH" run_with_deadline 4 "$TMP/out" sh -c "$(command -v sleep) 30" || rc=$?
took=$((SECONDS - start))
[ "$rc" -eq 124 ] && [ "$took" -le 10 ] && ok "a slow watchdog sleep does not stretch the deadline (${took}s)" \
  || bad "a slow watchdog sleep stretched the deadline: rc=$rc, ${took}s for a 4-second deadline"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
