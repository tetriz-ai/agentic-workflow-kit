#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for worktree-hydrate-claude.sh — the PostToolUse:EnterWorktree entry
# point that resolves the new worktree path from the tool's stdin JSON (schema-
# tolerant string-leaf scan, with a newest-linked-worktree fallback) and
# delegates to worktree-hydrate.sh.
#
# Builds a throwaway git repo + real linked worktree and asserts: the path is
# resolved from a JSON payload, the fallback fires on a path-less payload, the
# main checkout is never selected, and malformed/empty stdin is a safe no-op.
# Must pass on macOS stock bash 3.2.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/worktree-hydrate-claude.sh"
pass=0; fail=0
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not installed (wrapper hard-exits without jq)"; exit 0; }

ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3' got '$2')"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MAIN="$TMP/main"
git init -q "$MAIN"
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name t
printf 'required .env\n' > "$MAIN/.worktreeinclude"
git -C "$MAIN" add .worktreeinclude
git -C "$MAIN" commit -qm init
echo "ENVVAL" > "$MAIN/.env"   # local gitignored file to hydrate

WT="$TMP/wt"
git -C "$MAIN" worktree add -q "$WT" -b feat

# --- 1. Path resolved from a realistic EnterWorktree JSON payload ---
printf '{"tool_name":"EnterWorktree","tool_response":{"path":"%s","branch":"feat"}}' "$WT" \
  | bash "$SCRIPT" >/dev/null 2>&1
[ -f "$WT/.env" ] && ok "resolves worktree path from JSON .tool_response.path" \
                  || bad "resolves worktree path from JSON .tool_response.path"

# --- 2. Path found even when nested under a differently-named JSON key ---
rm -f "$WT/.env"
printf '{"result":{"deeply":{"created_at":"%s"}}}' "$WT" | bash "$SCRIPT" >/dev/null 2>&1
[ -f "$WT/.env" ] && ok "scans arbitrary string leaves for the worktree path" \
                  || bad "scans arbitrary string leaves for the worktree path"

# --- 3. Fallback: path-less payload → newest linked worktree ---
# The fallback enumerates `git worktree list` of its cwd's repo — in production
# the hook's cwd is the project dir that owns the new worktree, so run it there.
rm -f "$WT/.env"
( cd "$MAIN" && printf '{"tool_name":"EnterWorktree","tool_response":{}}' | bash "$SCRIPT" >/dev/null 2>&1 )
[ -f "$WT/.env" ] && ok "fallback hydrates newest linked worktree on path-less payload" \
                  || bad "fallback hydrates newest linked worktree on path-less payload"

# --- 4. The main checkout is never selected, even if its path appears in JSON ---
rm -f "$MAIN/.env"   # so we can detect an erroneous main hydration
printf '{"tool_response":{"path":"%s"}}' "$MAIN" | bash "$SCRIPT" >/dev/null 2>&1
[ ! -e "$MAIN/.env" ] && ok "main checkout path in JSON is rejected (not a linked worktree)" \
                      || bad "main checkout path in JSON is rejected"

# --- 4b. The new worktree in tool_response wins over the session's cwd in another worktree ---
AWT="$TMP/a-session-wt"; git -C "$MAIN" worktree add -q "$AWT" -b session
rm -f "$WT/.env" "$AWT/.env"; echo "ENVVAL" > "$MAIN/.env"
printf '{"cwd":"%s","tool_response":{"path":"%s"}}' "$AWT" "$WT" | bash "$SCRIPT" >/dev/null 2>&1
[ -f "$WT/.env" ] && [ ! -e "$AWT/.env" ] && ok "tool_response path wins over the session cwd" \
                  || bad "tool_response path wins over the session cwd"

# --- 5. Malformed / empty stdin is a safe no-op, always exit 0 ---
printf 'not json {{' | bash "$SCRIPT" >/dev/null 2>&1; chk "malformed stdin exit 0" "$?" "0"
printf ''            | bash "$SCRIPT" >/dev/null 2>&1; chk "empty stdin exit 0"     "$?" "0"
printf '{"tool_response":{"path":"/no/such/dir/xyz"}}' | bash "$SCRIPT" >/dev/null 2>&1
chk "nonexistent path exit 0" "$?" "0"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
