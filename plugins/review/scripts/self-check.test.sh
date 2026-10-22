#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for self-check.sh. Run: bash self-check.test.sh
#
# Asserts the size gate (substantial fires, trivial silent), the prose/.claude
# skips, the threshold override, the PostToolUse-only surface, and that the
# emitted nudge carries the anti-noise contract (self-correct/fix, not a report;
# one line only on a change; silent when clean). Deterministic - exits non-zero
# on any failure.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/self-check.sh"
pass=0
fail=0

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

# Build a string of N lines ("line 1\nline 2\n...").
nlines() { seq 1 "$1" | sed 's/^/line /'; }

# run <json> -> hook stdout. Optional env prefix via RUN_ENV.
run() { printf '%s' "$1" | env ${RUN_ENV:-} bash "$HOOK" 2>/dev/null; }

# Payload builders (jq makes the strings JSON-safe).
edit_payload()  { jq -nc --arg fp "$1" --arg ns "$2" '{hook_event_name:"PostToolUse",tool_name:"Edit",tool_input:{file_path:$fp,new_string:$ns}}'; }
write_payload() { jq -nc --arg fp "$1" --arg c  "$2" '{hook_event_name:"PostToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$c}}'; }
multi_payload() { jq -nc --arg fp "$1" --arg a "$2" --arg b "$3" '{hook_event_name:"PostToolUse",tool_name:"MultiEdit",tool_input:{file_path:$fp,edits:[{new_string:$a},{new_string:$b}]}}'; }

assert_empty() {
  local desc="$1" out="$2"
  if [ -z "$out" ]; then echo "PASS: $desc"; pass=$((pass + 1));
  else echo "FAIL: $desc (expected empty, got: $out)"; fail=$((fail + 1)); fi
}
assert_json_contains() {
  local desc="$1" out="$2" needle="$3"
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1 && printf '%s' "$out" | grep -qF "$needle"; then
    echo "PASS: $desc"; pass=$((pass + 1));
  else echo "FAIL: $desc (got: $out)"; fail=$((fail + 1)); fi
}

BIG=$(nlines 35)     # >= default threshold 30
SMALL=$(nlines 5)    # trivial

# 1. Substantial .go edit fires.
out=$(run "$(edit_payload /repo/server/foo.go "$BIG")")
assert_json_contains "substantial .go edit fires" "$out" "SELF-CHECK"
assert_json_contains "names the file" "$out" "/repo/server/foo.go"

# 2. Trivial .go edit is silent (the whole point - no noise on small edits).
out=$(run "$(edit_payload /repo/server/foo.go "$SMALL")")
assert_empty "trivial .go edit silent" "$out"

# 3. Substantial Write fires; non-Go code fires too (.ts, .py).
out=$(run "$(write_payload /repo/web/app/x.ts "$BIG")")
assert_json_contains "substantial .ts write fires" "$out" "SELF-CHECK"
out=$(run "$(write_payload /repo/svc/main.py "$BIG")")
assert_json_contains "substantial .py write fires" "$out" "SELF-CHECK"

# 4. MultiEdit summing over the threshold fires.
out=$(run "$(multi_payload /repo/server/bar.go "$(nlines 20)" "$(nlines 20)")")
assert_json_contains "MultiEdit summing >= threshold fires" "$out" "SELF-CHECK"

# 5. The nudge carries the anti-noise contract (action, not a report; one line; silent when clean).
out=$(run "$(edit_payload /repo/server/foo.go "$BIG")")
assert_json_contains "contract: not a report" "$out" "Do NOT write a Code Change Analysis report"
assert_json_contains "contract: one line only on a change" "$out" "ONE line ONLY if it actually changed something"
assert_json_contains "contract: silent when clean" "$out" "if the self-check was clean, say nothing"

# 6. Prose / docs / harness edits skip even when substantial.
out=$(run "$(write_payload /repo/README.md "$BIG")")
assert_empty ".md skipped" "$out"
out=$(run "$(write_payload /repo/docs/guide.md "$BIG")")
assert_empty "docs/*.md skipped (by extension)" "$out"
out=$(run "$(edit_payload /repo/server/docs/example.go "$BIG")")
assert_json_contains ".go under docs/ still fires (no blanket docs skip)" "$out" "SELF-CHECK"
out=$(run "$(write_payload /repo/.claude/hooks/x.sh "$BIG")")
assert_empty ".claude/ skipped" "$out"

# 7. Threshold is env-tunable both ways.
out=$(RUN_ENV="SELF_CHECK_MIN_LINES=3" run "$(edit_payload /repo/server/foo.go "$SMALL")")
assert_json_contains "low threshold makes a small edit fire" "$out" "SELF-CHECK"
out=$(RUN_ENV="SELF_CHECK_MIN_LINES=99" run "$(edit_payload /repo/server/foo.go "$BIG")")
assert_empty "high line threshold + small bytes makes a big edit silent" "$out"

# 7b. Byte floor: a substantial SINGLE-LINE edit (few lines, many bytes) fires -
# closes the gap where a long literal / minified content evades the line gate.
LONGLINE=$(awk 'BEGIN{for(i=0;i<2000;i++)printf "x"}')   # 1 line, ~2000 bytes
out=$(run "$(edit_payload /repo/server/foo.go "$LONGLINE")")
assert_json_contains "long single-line edit fires by byte floor" "$out" "SELF-CHECK"
out=$(RUN_ENV="SELF_CHECK_MIN_BYTES=99999" run "$(edit_payload /repo/server/foo.go "$LONGLINE")")
assert_empty "high byte threshold makes the long single-line silent" "$out"

# 7c. A malformed env override falls back to the default - no stderr, rc 0.
P=$(edit_payload /repo/server/foo.go "$SMALL")
errout=$(printf '%s' "$P" | env SELF_CHECK_MIN_LINES=abc bash "$HOOK" 2>&1 >/dev/null); rc=$?
if [ -z "$errout" ] && [ "$rc" -eq 0 ]; then echo "PASS: malformed threshold env: no stderr, rc=0"; pass=$((pass + 1));
else echo "FAIL: malformed threshold env (stderr=[$errout] rc=$rc)"; fail=$((fail + 1)); fi
out=$(RUN_ENV="SELF_CHECK_MIN_LINES=abc" run "$(edit_payload /repo/server/foo.go "$BIG")")
assert_json_contains "malformed threshold falls back to default (big edit still fires)" "$out" "SELF-CHECK"

# 8. PostToolUse-only: a non-file tool, and other events, are silent.
out=$(run '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}')
assert_empty "non-file tool skipped" "$out"
out=$(run '{"hook_event_name":"UserPromptSubmit"}')
assert_empty "UserPromptSubmit skipped (PostToolUse-only)" "$out"
out=$(run '{"hook_event_name":"SessionStart"}')
assert_empty "SessionStart skipped" "$out"

# 9. Empty + malformed stdin: exit 0, no output (never crash the tool).
printf '' | bash "$HOOK" >/dev/null 2>&1
if [ "$?" -eq 0 ]; then echo "PASS: empty stdin rc=0"; pass=$((pass + 1)); else echo "FAIL: empty stdin rc!=0"; fail=$((fail + 1)); fi
out=$(printf '' | bash "$HOOK" 2>/dev/null); assert_empty "empty stdin no output" "$out"
out=$(printf 'not json {{' | bash "$HOOK" 2>/dev/null); assert_empty "malformed stdin no output" "$out"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
