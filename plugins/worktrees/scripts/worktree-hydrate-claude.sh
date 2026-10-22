#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# PostToolUse hook (matcher: EnterWorktree). Hydrates the worktree Claude just
# created with the local gitignored files it needs to run, by delegating to the
# shared worktree-hydrate.sh.
#
# Why a separate entry point from the git post-checkout hook: EnterWorktree
# shells `git worktree add`, so post-checkout already covers it WHEN that hook is
# installed. This plugin hook runs regardless of the machine's git hooks setup,
# so the Claude path works on a checkout that never installed post-checkout. Both
# call the same idempotent script, so running both is a harmless no-op on the
# second pass.
#
# The hook's cwd is the main project dir, not the new worktree, so we resolve
# the worktree path from the tool's stdin JSON (schema-tolerant: scan the string values of
# tool_response, then tool_input, then the rest, so the session's own `cwd` is read last, for a
# directory that git reports as a linked worktree), with a fallback to the most-recently-created
# linked worktree.
set -uo pipefail

HOOKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRATE="$HOOKDIR/worktree-hydrate.sh"
[ -f "$HYDRATE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"

is_linked_worktree() {
  local d="$1" g c
  [ -d "$d" ] || return 1
  g="$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  c="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ "$g" != "$c" ]
}

WT=""
# 1) Scan all string leaves of the JSON for a path that is a linked worktree.
if [ -n "$payload" ]; then
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if is_linked_worktree "$cand"; then WT="$cand"; break; fi
  done < <(printf '%s' "$payload" | jq -r '([.tool_response // empty | .. | strings] + [.tool_input // empty | .. | strings] + [.. | strings]) | .[]?' 2>/dev/null)
fi

# 2) Fallback: newest linked worktree by directory mtime.
if [ -z "$WT" ]; then
  newest=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    is_linked_worktree "$path" || continue
    m="$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || echo 0)"
    # Strictly newer wins, so on an mtime tie (or a stat failure → 0) the first
    # listed worktree is kept deterministically rather than the last.
    if [ "$m" -gt "$newest" ]; then newest="$m"; WT="$path"; fi
  done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')
fi

[ -n "$WT" ] || exit 0
bash "$HYDRATE" "$WT" || true
exit 0
