#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for worktree-anchor-subagents.sh. Run: bash worktree-anchor-subagents.test.sh
#
# Builds a throwaway main repo + a linked worktree in a tmpdir so the assertions
# are deterministic regardless of where the runner sits. Asserts the hook
# AUTO-INJECTS a worktree anchor (stdout JSON permissionDecision=allow with
# updatedInput.prompt carrying the worktree root, and the original tool_input
# fields — subagent_type/description — preserved) for ANY subagent spawn in a
# linked worktree that is NOT already anchored (inject-always — no source-detect),
# and PASSES THROUGH (no stdout, no rewrite) already-anchored prompts and the
# main checkout. The hook always exits 0.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/worktree-anchor-subagents.sh"
pass=0; fail=0
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

# --- temp repo + linked worktree -------------------------------------------
TMP=$(mktemp -d)
MAIN="$TMP/main"
WT="$TMP/wt"
# Assign MAIN/WT before the trap so an early-exit doesn't deref them unbound.
trap 'rm -rf "$TMP"; git -C "${MAIN:-/nonexistent}" worktree prune 2>/dev/null || true' EXIT
git init -q "$MAIN"
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q "$WT" -b wt-branch >/dev/null 2>&1
# Canonicalise to git's own toplevel — on macOS mktemp yields /var/... while
# show-toplevel resolves the /private/var symlink; a real caller anchors with
# the canonical worktree path (what pwd/show-toplevel return in the session).
WT=$(git -C "$WT" rev-parse --show-toplevel)
MAIN=$(git -C "$MAIN" rev-parse --show-toplevel)

# tool_input carries subagent_type + description so the merge-preservation can be asserted.
payload() { jq -nc --arg cwd "$1" --arg p "$2" '{cwd:$cwd, tool_input:{prompt:$p, subagent_type:"general-purpose", description:"dsc"}}'; }
run()     { printf '%s' "$(payload "$1" "$2")" | bash "$HOOK" 2>/dev/null; }

injects() {  # desc, cwd, prompt : allow + updatedInput anchored + original preserved + fields preserved
  # All assertions in jq (string ops, not grep): the long-prompt case is ~75KB
  # and `grep -F` with a pattern that large OOMs; jq contains/endswith do not.
  local ok
  ok=$(run "$2" "$3" | jq -r --arg wt "$WT" --arg orig "$3" '
    (.hookSpecificOutput.permissionDecision == "allow")
    and (.hookSpecificOutput.updatedInput.prompt | contains($wt))
    and (.hookSpecificOutput.updatedInput.prompt | endswith($orig))
    and (.hookSpecificOutput.updatedInput.description == "dsc")
    and (.hookSpecificOutput.updatedInput.subagent_type == "general-purpose")
  ' 2>/dev/null)
  if [ "$ok" = "true" ]; then echo "PASS: $1"; pass=$((pass+1));
  else echo "FAIL: $1 (assertion=$ok)"; fail=$((fail+1)); fi
}
passthrough() {  # desc, cwd, prompt : expect rc 0 and NO updatedInput (untouched)
  local o rc
  o=$(printf '%s' "$(payload "$2" "$3")" | bash "$HOOK" 2>/dev/null); rc=$?
  local inj; inj=$(jq -r '.hookSpecificOutput.updatedInput // "none"' <<<"$o" 2>/dev/null || echo none)
  if [ "$rc" -eq 0 ] && { [ -z "$o" ] || [ "$inj" = "none" ]; }; then
    echo "PASS: $1"; pass=$((pass+1));
  else echo "FAIL: $1 (rc=$rc, updatedInput=$inj — expected passthrough)"; fail=$((fail+1)); fi
}

# --- INJECTS: any NOT-already-anchored spawn in a linked worktree (inject-always) ---
injects "source dir"            "$WT" "Review web/app/src/foo.tsx for bugs"
injects "ext-less file (Makefile)" "$WT" "Read the Makefile and the Dockerfile"
injects "go.mod" "$WT" "Bump the dep in go.mod"
injects "uppercase .GO" "$WT" "Review SCHEDULER.GO"
injects "bare dir word, no slash" "$WT" "Look in the server folder"
injects "non-repo research prompt — injected, but preamble defers to off-repo paths" "$WT" "Research Redis vs Valkey tradeoffs and summarize"
injects "prefix-bypass is not a real anchor — still injects" "$WT" "Review ${WT}-stale/server/x.go"
# pipefail+grep-q SIGPIPE guard: a ~75KB prompt — anchor check (here-string) must not choke.
injects "long prompt" "$WT" "$(printf 'server/foo.go %.0s' $(seq 1 5000))report"

# --- PASSTHROUGH: already anchored, main checkout ---
passthrough "already anchored (root at boundary)" "$WT" "Working dir: $WT — review src/foo.tsx"
passthrough "already anchored (cd into root)"     "$WT" "cd \"$WT\" && go test ./..."
passthrough "main checkout (not a linked worktree)" "$MAIN" "Review web/app/src/foo.tsx"

# --- robustness: empty / malformed stdin never crash, never rewrite ---
printf '' | bash "$HOOK" >/dev/null 2>&1; [ "$?" -eq 0 ] && { echo "PASS: empty stdin rc=0"; pass=$((pass+1)); } || { echo "FAIL: empty stdin rc!=0"; fail=$((fail+1)); }
printf 'not json {{' | bash "$HOOK" >/dev/null 2>&1; [ "$?" -eq 0 ] && { echo "PASS: malformed stdin rc=0"; pass=$((pass+1)); } || { echo "FAIL: malformed stdin rc!=0"; fail=$((fail+1)); }

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
