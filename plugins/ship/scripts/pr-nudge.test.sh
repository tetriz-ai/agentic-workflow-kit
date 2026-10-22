#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for pr-nudge.sh — the PR-lifecycle advisory-nudge dispatcher
# (feedback + sync + codex): the feedback-arm, sync-arm and codex-arm cases.
# Run: bash pr-nudge.test.sh   (exits non-zero on first failure)
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-nudge.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

pass=0; fail=0
payload() { jq -nc --arg c "$1" '{tool_input:{command:$c}}'; }
run()     { printf '%s' "$(payload "$1")" | bash "$HOOK" 2>/dev/null; }

# emits <tag> <desc> <command> : output is valid JSON and contains <tag>.
emits() {
  local out; out=$(run "$3")
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1 && printf '%s' "$out" | grep -qF "$1"; then
    echo "PASS: $2"; pass=$((pass + 1))
  else echo "FAIL: $2 (got: $out)"; fail=$((fail + 1)); fi
}
# absent <tag> <desc> <command> : output does NOT contain <tag> (other nudges ok).
absent() {
  local out; out=$(run "$3")
  if printf '%s' "$out" | grep -qF "$1"; then
    echo "FAIL: $2 (unexpected $1: $out)"; fail=$((fail + 1))
  else echo "PASS: $2"; pass=$((pass + 1)); fi
}
# silent <desc> <command> : no output at all.
silent() {
  local out; out=$(run "$2")
  if [ -z "$out" ]; then echo "PASS: $1"; pass=$((pass + 1))
  else echo "FAIL: $1 (expected empty, got: $out)"; fail=$((fail + 1)); fi
}

echo "pr-nudge.sh tests:"

# ── feedback ─────────────────────────────────────────────────────────────────
emits PR-FEEDBACK "view --comments fires"              "gh pr view 123 --comments"
emits PR-FEEDBACK "view -c short flag fires"           "gh pr view 123 -c"
emits PR-FEEDBACK "api pulls/N/comments fires"         "gh api repos/acme/widgets/pulls/123/comments"
emits PR-FEEDBACK "api issues/N/comments fires"        "gh api repos/acme/widgets/issues/123/comments"
emits PR-FEEDBACK "api per_page query fires"           "gh api 'repos/o/r/pulls/12/comments?per_page=100'"
emits PR-FEEDBACK "list + by-id same line fires"       "gh api repos/o/r/pulls/12/comments && gh api repos/o/r/pulls/comments/99"
emits PR-FEEDBACK "2nd view clause --comments fires"   "gh pr view 5 ; gh pr view 6 --comments"
emits PR-FEEDBACK "2nd view clause -c fires"           "gh pr view 5 && gh pr view 6 -c"
emits PR-FEEDBACK "glued --comments=true fires"        "gh pr view 5 --comments=true"
# content: names the missed surface
out=$(run "gh pr view 5 --comments")
printf '%s' "$out" | grep -qiF "review bodies" && { echo "PASS: feedback names review bodies"; pass=$((pass+1)); } || { echo "FAIL: feedback missing 'review bodies'"; fail=$((fail+1)); }
silent  "graphql fetch not nudged"                     "gh api graphql -f query='{ pullRequest { reviewThreads { comments { body } } } }'"
silent  "pr-feedback.sh itself not nudged"             "plugins/ship/skills/pr-feedback/pr-feedback.sh 123"
absent PR-FEEDBACK "reply via in_reply_to"             "gh api repos/o/r/pulls/12/comments -F in_reply_to=999 -f body=fixed"
absent PR-FEEDBACK "explicit POST"                     "gh api -X POST repos/o/r/pulls/12/comments -f body=hi"
absent PR-FEEDBACK "new comment -F body="             "gh api repos/o/r/pulls/12/comments -F body=nit -F path=x.go -F line=10"
absent PR-FEEDBACK "write via --field body="          "gh api repos/o/r/pulls/12/comments --field body=fixed"
absent PR-FEEDBACK "glued -fbody= write"               "gh api repos/o/r/pulls/12/comments -fbody=ok"
absent PR-FEEDBACK "by-id comment GET no PR num"       "gh api repos/acme/widgets/pulls/comments/1234567890"
absent PR-FEEDBACK "by-id comment GET under PR"        "gh api repos/o/r/pulls/12/comments/456"
absent PR-FEEDBACK "by-id issue comment GET"           "gh api repos/o/r/issues/comments/789"
absent PR-FEEDBACK "view piped to grep -c"             "gh pr view 127 --json body --jq .body | grep -c foo"
absent PR-FEEDBACK "view then sort -c"                 "gh pr view 5 --json title && echo x | sort -c"
silent  "plain gh pr view"                             "gh pr view 123"
silent  "gh pr view --json"                            "gh pr view 123 --json number,title"

# ── sync ─────────────────────────────────────────────────────────────────────
emits PR-SYNC "bare git push fires"                    "git push"
emits PR-SYNC "git push origin branch fires"           "git push origin feature-y"
emits PR-SYNC "git push -u origin fires"               "git push -u origin feature-x"
emits PR-SYNC "git push --force fires"                 "git push --force"
emits PR-SYNC "git -C path push fires"                 "git -C /tmp/wt push origin x"
# content: names the reconcile action
out=$(run "git push")
printf '%s' "$out" | grep -qiF "title" && printf '%s' "$out" | grep -qiF "gh pr edit" \
  && { echo "PASS: sync names title + gh pr edit"; pass=$((pass+1)); } \
  || { echo "FAIL: sync missing title/gh pr edit"; fail=$((fail+1)); }
absent PR-SYNC "git push --dry-run"                    "git push --dry-run origin x"
absent PR-SYNC "git commit w/ push in msg"             "git commit -m 'push fix to prod'"
absent PR-SYNC "echoed git push"                       "echo 'next: git push origin x'"
absent PR-SYNC "git push inside a heredoc-free note"    "printf '%s' 'run git push later'"
emits PR-SYNC "git push after a separator"              "git add -A && git push"
silent  "git status"                                   "git status"
silent  "git log"                                      "git log --oneline -5"

# ── codex (new) ──────────────────────────────────────────────────────────────
emits CODEX-SWEEP "pr create fires codex"              "gh pr create --title x --body y"
emits CODEX-SWEEP "bare pr create fires codex"         "gh pr create"
emits CODEX-SWEEP "pr create --draft fires codex"      "gh pr create --draft --title x"
emits CODEX-SWEEP "pr new alias fires codex"           "gh pr new --title x"
# content: names the arming mechanism — a background `codex-sweep.sh await`, not ScheduleWakeup
out=$(run "gh pr create --title x")
printf '%s' "$out" | grep -qiF "codex-sweep.sh await" && printf '%s' "$out" | grep -qiF "run_in_background" \
  && { echo "PASS: codex names the background await launch"; pass=$((pass+1)); } \
  || { echo "FAIL: codex missing 'codex-sweep.sh await' / run_in_background"; fail=$((fail+1)); }
printf '%s' "$out" | grep -qiF "ScheduleWakeup" \
  && { echo "FAIL: codex must NOT tell the agent to use ScheduleWakeup"; fail=$((fail+1)); } \
  || { echo "PASS: codex does not name ScheduleWakeup"; pass=$((pass+1)); }
# The awaiter LAUNCH must be cwd-independent: the script's absolute path inside this plugin.
# It must NOT use $CLAUDE_PROJECT_DIR or $CLAUDE_PLUGIN_ROOT (both empty in a Bash-tool command,
# so the launch 127s) nor a bare cwd-relative path (127s from a subdirectory). Both silently drop
# the sweep. Full why: /ship:pr's "Arm the Codex review sweep" step.
PLUGIN_ROOT_ABS="$(cd "$(dirname "$HOOK")/.." && pwd)"
printf '%s' "$out" | grep -qF "\\\"$PLUGIN_ROOT_ABS/skills/codex-sweep/codex-sweep.sh\\\" await" \
  && { echo "PASS: codex nudge launches the absolute plugin path"; pass=$((pass+1)); } \
  || { echo "FAIL: codex nudge missing the absolute $PLUGIN_ROOT_ABS/skills/codex-sweep/codex-sweep.sh await launch"; fail=$((fail+1)); }
printf '%s' "$out" | grep -qE '\$CLAUDE_(PROJECT_DIR|PLUGIN_ROOT)"?/' \
  && { echo "FAIL: codex nudge must NOT prefix the launch with an env var that is empty in a Bash-tool command"; fail=$((fail+1)); } \
  || { echo "PASS: codex nudge does not use an env-var-prefixed command"; pass=$((pass+1)); }
absent CODEX-SWEEP "pr create --help (no arm)"         "gh pr create --help"
absent CODEX-SWEEP "pr create -h (no arm)"             "gh pr create -h"
absent CODEX-SWEEP "pr create --dry-run (no arm)"      "gh pr create --dry-run --title x"
absent CODEX-SWEEP "pr create --web (no arm)"          "gh pr create --web"
absent CODEX-SWEEP "pr create -w (no arm)"             "gh pr create -w"
absent CODEX-SWEEP "pr new --web (no arm)"             "gh pr new --web"
absent CODEX-SWEEP "pr edit"                           "gh pr edit 5 --body z"
absent CODEX-SWEEP "pr view"                           "gh pr view 5"
absent CODEX-SWEEP "pr list"                           "gh pr list"
absent CODEX-SWEEP "echoed gh pr create"               "echo 'then gh pr create --fill'"
emits CODEX-SWEEP "gh -R repo pr create fires"          "gh -R acme/widgets pr create --fill"
emits CODEX-SWEEP "a -w after the create command fires" "gh pr create --fill && git diff -w"
emits CODEX-SWEEP "a -w inside the title fires"          "gh pr create --title 'support -w' --body x"
# create nudges codex ONLY (not the other two)
absent PR-FEEDBACK "create: not feedback"              "gh pr create --title x"
absent PR-SYNC     "create: not sync"                  "gh pr create --title x"
# A gh pr create from any cwd fires the codex nudge.
run_cwd() { printf '%s' "$(jq -nc --arg c "$2" --arg d "$1" '{tool_input:{command:$c},cwd:$d}')" | bash "$HOOK" 2>/dev/null; }
nc_out=$(run_cwd "/work/repo" "gh pr create --title x")
printf '%s' "$nc_out" | grep -qF CODEX-SWEEP \
  && { echo "PASS: gh pr create fires codex"; pass=$((pass+1)); } \
  || { echo "FAIL: gh pr create should fire codex (got: $nc_out)"; fail=$((fail+1)); }

# ── unrelated + robustness ───────────────────────────────────────────────────
silent "non-gh/git command"                            "echo push it"
silent "ls"                                            "ls -la"
silent "go test"                                       "go test ./..."
printf '' | bash "$HOOK" >/dev/null 2>&1; [ "$?" -eq 0 ] && { echo "PASS: empty stdin rc=0"; pass=$((pass+1)); } || { echo "FAIL: empty stdin rc!=0"; fail=$((fail+1)); }
silent "empty stdin no output"                         ""
out=$(printf 'not json {{' | bash "$HOOK" 2>/dev/null); [ -z "$out" ] && { echo "PASS: malformed stdin no output"; pass=$((pass+1)); } || { echo "FAIL: malformed stdin emitted"; fail=$((fail+1)); }

echo "  ---"
echo "  passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
