#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -euo pipefail

skill_root="${1:-.claude/skills}"
[ -d "$skill_root" ] || exit 0

while IFS= read -r -d '' skill_symlink; do
  [ -d "$skill_symlink" ] || continue
  echo "nested skill directories must not be symlinks because Codex dereferences .agents/skills: $skill_symlink" >&2
  exit 1
done < <(find "$skill_root" -mindepth 1 -type l -print0)
