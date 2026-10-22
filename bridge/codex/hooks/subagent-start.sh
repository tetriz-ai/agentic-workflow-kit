#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"
CWD=""
if command -v jq >/dev/null 2>&1; then
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[ -n "$CWD" ] || CWD="${PWD:-.}"

GIT_DIR="$(git -C "$CWD" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
COMMON_DIR="$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
[ "$GIT_DIR" != "$COMMON_DIR" ] || exit 0

WT_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$WT_ROOT" ] || exit 0

printf '%s\n' \
  "<<WORKTREE ANCHOR — injected by the Codex SubagentStart hook>>" \
  "Operate on the linked worktree at: $WT_ROOT" \
  "Resolve every repository-relative path under that root and cd there before repository commands. Do not read or edit the stale main checkout. An explicit task path outside this repository still takes precedence."
