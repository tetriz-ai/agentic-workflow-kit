#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CLAUDE_SKILLS="$ROOT/.claude/skills"
AGENTS_DIR="$ROOT/.agents"
CODEX_SKILLS="$AGENTS_DIR/skills"

if [ ! -d "$CLAUDE_SKILLS" ]; then
  echo "missing $CLAUDE_SKILLS" >&2
  exit 1
fi

# shellcheck source=path-contained.sh
. "$(dirname "${BASH_SOURCE[0]}")/path-contained.sh"
if ! real="$(path_contained "$ROOT" "$CODEX_SKILLS")"; then
  echo "$CODEX_SKILLS leads to ${real:-a path that cannot be resolved}, outside the repo, through a symlink; refusing to write it" >&2
  exit 2
fi
mkdir -p "$AGENTS_DIR"

if [ -L "$CODEX_SKILLS" ]; then
  target="$(readlink "$CODEX_SKILLS")"
  if [ "$target" != "../.claude/skills" ]; then
    echo "$CODEX_SKILLS points at $target, expected ../.claude/skills" >&2
    exit 1
  fi
elif [ -e "$CODEX_SKILLS" ]; then
  echo "$CODEX_SKILLS exists and is not the expected symlink" >&2
  exit 1
else
  ln -s ../.claude/skills "$CODEX_SKILLS"
fi

missing=0
while IFS= read -r skill_md; do
  if ! grep -q '^name:' "$skill_md"; then
    echo "missing name: $skill_md" >&2
    missing=1
  fi
  if ! grep -q '^description:' "$skill_md"; then
    echo "missing description: $skill_md" >&2
    missing=1
  fi
done < <(find "$CLAUDE_SKILLS" -mindepth 2 -maxdepth 2 -name SKILL.md | sort)

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "Codex skills symlink is current: $CODEX_SKILLS -> ../.claude/skills"
