#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Replays the PR-description drift hook after pushes, with the fixture's stub gh first on PATH.
set -uo pipefail
DIR="$1"; KIT="$(cd "$(dirname "$0")/../.." && pwd)"; HOOK="$KIT/plugins/ship/scripts/check-pr-description-drift.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
push() { jq -nc --arg c "$1" '{tool_input:{command:$c}}' | (cd "$DIR/repo" && env PATH="$DIR/bin:$PATH" PR_DRIFT_GRACE_SECONDS=0 "${@:2}" bash "$HOOK"); }

out=$(push "git push --dry-run")
[ -z "$out" ] && ok "a dry-run push is quiet" || bad "dry-run reminded: [$out]"
out=$(push "git push")
case "$out" in *"PR #127"*) ok "a push that leaves the description behind reminds once, naming the PR" ;; *) bad "no reminder: [$out]" ;; esac
out=$(push "git push")
[ -z "$out" ] && ok "a second push with the same description is quiet" || bad "repeated reminder: [$out]"
out=$(push "git push" BODY_EDITED=2026-03-03T00:00:00Z)
[ -z "$out" ] && ok "a description edited after the newest commit is not stale" || bad "reminded on a fresh description: [$out]"
(GIT_AUTHOR_DATE="1772668800 +0000" GIT_COMMITTER_DATE="1772668800 +0000" git -C "$DIR/repo" -c user.email=example@example.com -c user.name=example commit -q --allow-empty -m "later fix")
out=$(push "git push" BODY_EDITED=2026-03-03T00:00:00Z)
case "$out" in *"PR #127"*) ok "after the description is edited, the next push that leaves it behind reminds again" ;; *) bad "no re-arm: [$out]" ;; esac
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
