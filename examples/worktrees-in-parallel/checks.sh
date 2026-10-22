#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Creates two worktrees through git (so the post-checkout githook runs), then replays the
# subagent anchor hook from each checkout.
set -uo pipefail
DIR="$1"; KIT="$(cd "$(dirname "$0")/../.." && pwd)"; MAIN="$DIR/main"
ANCHOR="$KIT/plugins/worktrees/scripts/worktree-anchor-subagents.sh"
export AGENTIC_KIT_WORKTREES_DIR="$KIT/plugins/worktrees"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

for a in a b; do git -C "$MAIN" worktree add -q "$DIR/wt-$a" -b "agent-$a" >/dev/null 2>&1; done
for a in a b; do
  [ "$(cat "$DIR/wt-$a/.env" 2>/dev/null)" = "API_KEY=local-only" ] && [ -f "$DIR/wt-$a/config/local.yml" ] \
    && ok "worktree $a starts with the listed local files" || bad "worktree $a is missing local files"
done
echo "API_KEY=changed-in-a" > "$DIR/wt-a/.env"
[ "$(cat "$MAIN/.env")" = "API_KEY=local-only" ] && [ "$(cat "$DIR/wt-b/.env")" = "API_KEY=local-only" ] \
  && ok "an edit in one worktree touches neither the main checkout nor the other worktree" || bad "an edit leaked across checkouts"
dispatch() { jq -nc --arg cwd "$1" '{cwd:$cwd, tool_input:{prompt:"fix the failing test", subagent_type:"general-purpose", description:"fix"}}' | bash "$ANCHOR" 2>/dev/null; }
WT_A="$(cd "$DIR/wt-a" && pwd -P)"
out=$(dispatch "$DIR/wt-a" | jq -r '.hookSpecificOutput.updatedInput.prompt // empty')
case "$out" in *"$WT_A"*"fix the failing test") ok "a subagent dispatched from a worktree is anchored to it" ;; *) bad "no worktree anchor: [$(printf '%s' "$out" | head -c 200)]" ;; esac
out=$(dispatch "$MAIN")
[ -z "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput // empty' 2>/dev/null)" ] && ok "a subagent from the main checkout is left alone" || bad "main checkout dispatch was rewritten"
rm "$MAIN/config/local.yml"
out=$(git -C "$MAIN" worktree add "$DIR/wt-c" -b agent-c 2>&1)
case "$out" in *"required pattern matched nothing"*"config/local.yml"*) ok "a missing required file is reported" ;; *) bad "missing required file not reported: [$out]" ;; esac
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
