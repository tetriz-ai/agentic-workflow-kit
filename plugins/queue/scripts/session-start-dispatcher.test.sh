#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for session-start-dispatcher.sh. Run: bash session-start-dispatcher.test.sh
#
# Asserts the drop-in fan-out contract: runs every executable handler in
# session-start.d/, pipes the SessionStart payload to each, skips non-executable
# files and *.test.sh, exits 0 with no stdout, and no-ops when the dir is absent.
# The dispatcher resolves session-start.d/ beside itself, so the test copies it
# into a temp dir with a stub handler dir - never touching the real handlers.
# Deterministic - exits non-zero on any failure.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/session-start-dispatcher.sh"
pass=0
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Poll for an async sentinel rather than sleeping a fixed time — the dispatcher
# detaches handlers, so a fixed sleep races on a loaded box (CI flake).
wait_for() { local f="$1" n=0; while [ ! -e "$f" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; }

assert_empty() {
  local desc="$1" out="$2"
  if [ -z "$out" ]; then echo "PASS: $desc"; pass=$((pass + 1));
  else echo "FAIL: $desc (expected empty, got: $out)"; fail=$((fail + 1)); fi
}
assert_file() {
  local desc="$1" f="$2"
  if [ -e "$f" ]; then echo "PASS: $desc"; pass=$((pass + 1));
  else echo "FAIL: $desc (expected $f to exist)"; fail=$((fail + 1)); fi
}
assert_no_file() {
  local desc="$1" f="$2"
  if [ ! -e "$f" ]; then echo "PASS: $desc"; pass=$((pass + 1));
  else echo "FAIL: $desc (expected $f to be absent)"; fail=$((fail + 1)); fi
}

# The dispatcher resolves session-start.d/ relative to its own location, so test
# it via a copy placed beside a temp handler dir.
WORK="$TMP/hooks"
mkdir -p "$WORK/session-start.d"
cp "$HOOK" "$WORK/session-start-dispatcher.sh"
chmod +x "$WORK/session-start-dispatcher.sh"
DISP="$WORK/session-start-dispatcher.sh"
HD="$WORK/session-start.d"

# Pin the staging dir to a temp path so every case is deterministic: absent
# unless a case creates it. Staged-context cases populate $STAGE explicitly.
STAGE="$TMP/stage"
export SESSION_CONTEXT_DIR="$STAGE"

run() { printf '{"hook_event_name":"SessionStart"}' | bash "$DISP" 2>/dev/null; }

# An executable handler that records it ran and that it received the payload on stdin.
RAN="$TMP/ran"
STDIN_SEEN="$TMP/stdin"
cat > "$HD/aaa-handler.sh" <<EOF
#!/bin/bash
touch "$RAN"
cat > "$STDIN_SEEN"
EOF
chmod +x "$HD/aaa-handler.sh"
# A non-executable file and a *.test.sh that must NOT be run.
NOEXEC_RAN="$TMP/noexec_ran"
printf '#!/bin/bash\ntouch %s\n' "$NOEXEC_RAN" > "$HD/zzz-noexec.sh"   # not chmod +x
TEST_RAN="$TMP/test_ran"
printf '#!/bin/bash\ntouch %s\n' "$TEST_RAN" > "$HD/some.test.sh"
chmod +x "$HD/some.test.sh"                                            # exec, but *.test.sh

# 1. Exits 0, no stdout.
out=$(run); rc=$?
if [ "$rc" -eq 0 ]; then echo "PASS: exits 0"; pass=$((pass + 1)); else echo "FAIL: rc=$rc"; fail=$((fail + 1)); fi
assert_empty "no stdout" "$out"

# 2. The executable handler ran and received the payload on stdin.
wait_for "$STDIN_SEEN"
assert_file "runs the executable handler" "$RAN"
assert_file "pipes payload to handler stdin" "$STDIN_SEEN"
if grep -q "SessionStart" "$STDIN_SEEN" 2>/dev/null; then echo "PASS: payload reaches handler"; pass=$((pass + 1));
else echo "FAIL: payload not seen on handler stdin"; fail=$((fail + 1)); fi

# 3. Non-executable file and *.test.sh are skipped.
assert_no_file "skips non-executable file" "$NOEXEC_RAN"
assert_no_file "skips *.test.sh" "$TEST_RAN"

# 4. Missing handler dir -> no-op, rc 0.
BARE="$TMP/bare"
mkdir -p "$BARE"
cp "$HOOK" "$BARE/session-start-dispatcher.sh"
chmod +x "$BARE/session-start-dispatcher.sh"
out=$(printf '{}' | bash "$BARE/session-start-dispatcher.sh" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ]; then echo "PASS: missing dir rc=0"; pass=$((pass + 1)); else echo "FAIL: missing dir rc=$rc"; fail=$((fail + 1)); fi
assert_empty "missing dir no stdout" "$out"

# 5. Empty stdin: exit 0.
printf '' | bash "$DISP" >/dev/null 2>&1
if [ "$?" -eq 0 ]; then echo "PASS: empty stdin rc=0"; pass=$((pass + 1)); else echo "FAIL: empty stdin rc!=0"; fail=$((fail + 1)); fi

# 6. Absent staging dir -> no additionalContext on stdout (baseline).
out=$(run)
assert_empty "no staged dir -> no stdout" "$out"

# --- Staged-context emission (needs jq; skip those asserts if jq is absent). ---
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$STAGE"

  # 7. A staged *.md is emitted as valid SessionStart additionalContext JSON.
  printf '## Your ship-queue\n- #106 fix cursor loss\n' > "$STAGE/ship-queue-nudge.md"
  out=$(run)
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null 2>&1; then
    echo "PASS: emits SessionStart hookSpecificOutput JSON"; pass=$((pass + 1))
  else echo "FAIL: stdout is not the expected SessionStart JSON (got: $out)"; fail=$((fail + 1)); fi
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)
  if printf '%s' "$ctx" | grep -q "Your ship-queue" && printf '%s' "$ctx" | grep -q "#106"; then
    echo "PASS: additionalContext carries the staged markdown"; pass=$((pass + 1))
  else echo "FAIL: staged content missing from additionalContext"; fail=$((fail + 1)); fi

  # 8. Multiple staged files are concatenated into one additionalContext.
  printf '## Reminders\n- finish #103\n' > "$STAGE/zzz-other.md"
  ctx=$(run | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)
  if printf '%s' "$ctx" | grep -q "Your ship-queue" && printf '%s' "$ctx" | grep -q "Reminders"; then
    echo "PASS: multiple staged files concatenated"; pass=$((pass + 1))
  else echo "FAIL: not all staged files present in additionalContext"; fail=$((fail + 1)); fi

  # 8b. Oversized staged data stays on disk and is replaced by an explicit
  # retrieval marker before it can overflow the session prompt.
  printf 'OVERSIZED-STAGED-CONTEXT\n%.0s' $(seq 1 1000) > "$STAGE/oversized.md"
  ctx=$(run | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)
  if printf '%s' "$ctx" | grep -q "omitted to respect the 8192-byte session budget" && ! printf '%s' "$ctx" | grep -q "OVERSIZED-STAGED-CONTEXT"; then
    echo "PASS: oversized staged context is replaced with a retrieval marker"; pass=$((pass + 1))
  else echo "FAIL: oversized staged context leaked into additionalContext"; fail=$((fail + 1)); fi

  # 9. Context emission does NOT stop handler fan-out (both jobs run).
  RAN2="$TMP/ran2"
  cat > "$HD/bbb-handler.sh" <<EOF
#!/bin/bash
touch "$RAN2"
EOF
  chmod +x "$HD/bbb-handler.sh"
  run >/dev/null
  wait_for "$RAN2"
  assert_file "handlers still fan out while context is emitted" "$RAN2"

  # 10. Empty staged file -> no stdout (no hollow JSON envelope).
  rm -f "$STAGE"/*.md
  printf '' > "$STAGE/empty.md"
  out=$(run)
  assert_empty "empty staged content -> no stdout" "$out"

  # 11. A staged *.msg becomes a TOP-LEVEL systemMessage (the VISIBLE channel),
  #     while *.md stays nested additionalContext (silent). This is the whole
  #     point — additionalContext alone renders nothing to the user.
  rm -f "$STAGE"/*.md "$STAGE"/*.msg
  printf '## Full queue\n- #106\n' > "$STAGE/ship-queue-nudge.md"
  printf 'ship-queue: 3 tickets assigned to you — run /queue:ship-queue.\n' > "$STAGE/ship-queue-nudge.msg"
  out=$(run)
  sysmsg=$(printf '%s' "$out" | jq -r '.systemMessage' 2>/dev/null)
  if printf '%s' "$sysmsg" | grep -q "run /queue:ship-queue"; then
    echo "PASS: staged .msg -> top-level systemMessage (visible)"; pass=$((pass + 1))
  else echo "FAIL: systemMessage missing/empty (got: $out)"; fail=$((fail + 1)); fi
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)
  if printf '%s' "$ctx" | grep -q "Full queue"; then
    echo "PASS: .md still nested as additionalContext alongside systemMessage"; pass=$((pass + 1))
  else echo "FAIL: additionalContext dropped when a .msg is present"; fail=$((fail + 1)); fi

  # 12. A .msg with NO .md -> systemMessage present, no additionalContext.
  rm -f "$STAGE"/*.md "$STAGE"/*.msg
  printf 'ship-queue: 1 ticket.\n' > "$STAGE/ship-queue-nudge.msg"
  out=$(run)
  if printf '%s' "$out" | jq -e '.systemMessage' >/dev/null 2>&1 \
     && ! printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
    echo "PASS: .msg-only -> systemMessage without additionalContext"; pass=$((pass + 1))
  else echo "FAIL: .msg-only shape wrong (got: $out)"; fail=$((fail + 1)); fi

  # 12a. A .msg that fits the configured ceiling is emitted in full; reserve
  # space for the omission marker only when an omission is actually required.
  rm -f "$STAGE"/*.msg
  printf 'A%.0s' $(seq 1 8000) > "$STAGE/fits-budget.msg"
  out=$(run)
  sysmsg=$(printf '%s' "$out" | jq -r '.systemMessage // empty' 2>/dev/null)
  if [ "$(printf '%s' "$sysmsg" | wc -c | tr -d '[:space:]')" -eq 8000 ]; then
    echo "PASS: .msg within the budget is not suppressed"; pass=$((pass + 1))
  else echo "FAIL: fitting .msg was truncated or omitted"; fail=$((fail + 1)); fi

  # 12b. The shared budget applies to visible systemMessage files too; an
  # oversized .msg must remain available on disk rather than enter the prompt.
  rm -f "$STAGE"/*.msg
  printf 'OVERSIZED-SYSTEM-MESSAGE\n%.0s' $(seq 1 1000) > "$STAGE/oversized.msg"
  out=$(run)
  sysmsg=$(printf '%s' "$out" | jq -r '.systemMessage // empty' 2>/dev/null)
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  if ! printf '%s' "$sysmsg" | grep -q "OVERSIZED-SYSTEM-MESSAGE" \
     && printf '%s' "$ctx" | grep -q "omitted to respect the 8192-byte session budget"; then
    echo "PASS: oversized .msg is replaced with a retrieval marker"; pass=$((pass + 1))
  else echo "FAIL: oversized .msg leaked into startup context"; fail=$((fail + 1)); fi

  # 12c. A byte budget that is not an integer falls back to the default 8192, so a
  # message that fits the default is still emitted in full, with no shell error.
  rm -f "$STAGE"/*.msg
  printf 'B%.0s' $(seq 1 8000) > "$STAGE/fits-default.msg"
  for bad_budget in abc 8k; do
    out=$(printf '{"hook_event_name":"SessionStart"}' | SESSION_CONTEXT_MAX_BYTES="$bad_budget" bash "$DISP" 2>"$TMP/disp-err")
    sysmsg=$(printf '%s' "$out" | jq -r '.systemMessage // empty' 2>/dev/null)
    if [ "$(printf '%s' "$sysmsg" | wc -c | tr -d '[:space:]')" -eq 8000 ] && [ ! -s "$TMP/disp-err" ]; then
      echo "PASS: budget=$bad_budget falls back to the default"; pass=$((pass + 1))
    else echo "FAIL: budget=$bad_budget (stderr: $(cat "$TMP/disp-err"))"; fail=$((fail + 1)); fi
  done
else
  echo "SKIP: jq not available -> staged-context asserts skipped"
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
