#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
cd "$ROOT"

if [ "$#" -gt 0 ]; then
  echo "ERROR: this helper only publishes the current branch to origin" >&2
  exit 2
fi

remote="origin"
branch="$(git symbolic-ref --quiet --short HEAD)" || {
  echo "ERROR: cannot publish from detached HEAD" >&2
  exit 2
}

case "$branch" in
  master|main)
    echo "ERROR: refusing to push protected branch $branch" >&2
    exit 2
    ;;
  -*|*..*|*@\{*|*:*|*\\*|*' '*)
    echo "ERROR: refusing suspicious branch name $branch" >&2
    exit 2
    ;;
esac

if [ "${AGENTIC_KIT_CODEX_PUSH_DRY_RUN:-}" = "1" ]; then
  printf 'git push --set-upstream %s HEAD:%s\n' "$remote" "$branch"
  exit 0
fi

git push --set-upstream "$remote" "HEAD:$branch"
