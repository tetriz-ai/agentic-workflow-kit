#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Replays the review cadence hook over the fixture and asserts on its replies.
set -uo pipefail
DIR="$1"; KIT="$(cd "$(dirname "$0")/../.." && pwd)"; HOOK="$KIT/plugins/review/scripts/review-cadence.sh"
REPO="$DIR/repo"; pass=0; fail=0
export GIT_AUTHOR_NAME=example GIT_AUTHOR_EMAIL=example@example.com GIT_COMMITTER_NAME=example GIT_COMMITTER_EMAIL=example@example.com
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
fire() { jq -nc --arg c "$1" --arg cwd "$REPO" '{tool_input:{command:$c},cwd:$cwd}' | bash "$HOOK"; }
ctx() { jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

out=$(fire "git commit -m 'more paging'" | ctx)
case "$out" in *"[review-cadence] 5 commit(s)"*"review-panel"*) ok "the fifth commit since the last panel run gets the cadence nudge" ;; *) bad "no cadence nudge: [$out]" ;; esac
out=$(fire "git commit -m 'again'" | ctx)
[ -z "$out" ] && ok "the nudge appears once per crossing" || bad "repeated nudge: [$out]"
(cd "$REPO" && bash "$HOOK" reset)
out=$(fire "git commit -m 'after the panel'" | ctx)
[ -z "$out" ] && ok "after the panel resets the cadence, the next commit is quiet" || bad "nudge after reset: [$out]"
(cd "$REPO" && echo "fix" >> paginate.py && git add paginate.py && git commit -qm "fix the last page")
out=$(fire "gh pr create --title 'Pagination' --body 'x'" | ctx)
case "$out" in *"About to open a PR"*) ok "gh pr create with unreviewed commits gets the pre-PR nudge" ;; *) bad "no pre-PR nudge: [$out]" ;; esac
out=$(fire "echo git commit is next" | ctx)
[ -z "$out" ] && ok "an echo that mentions git commit is not a commit" || bad "echo nudged: [$out]"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
