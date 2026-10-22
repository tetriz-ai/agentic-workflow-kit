#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# validate-docs.sh — docs health scanner for CLAUDE.md and SKILL.md files.
#
# Edit-time enforcement is post-edit-dispatcher.sh, which sources the same check
# library. This script is the batch form, for CI or a manual sweep, run from the
# repo to check.
#
# Usage:
#   validate-docs.sh --all     # scan every CLAUDE.md / SKILL.md in the git repo (refused outside one)
#   validate-docs.sh PATH ...  # scan specific files
# Exit: 0 all pass | 1 a violation | 2 usage (no arguments), a missing file, or --all outside a
# git repository.
#
# Checks enforced (shared with the dispatcher via lib/check-docs-md.sh):
#   DOC-001  CLAUDE.md > 200 lines
#   DOC-002  Broken skill reference (/skill-name in CLAUDE.md but skill missing)
#   DOC-003  SKILL.md > 500 lines
#   DOC-004  SKILL.md missing YAML frontmatter 'description:' field

set -euo pipefail

usage() { echo "usage: validate-docs.sh --all | validate-docs.sh PATH..." >&2; exit 2; }
[ "$#" -gt 0 ] || usage
WARNINGS=()

# shellcheck source=lib/check-docs-md.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/check-docs-md.sh"

scan_one() {
  _lib_check_docs_md "$1"
}

if [[ "${1:-}" == "--all" ]]; then
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
  if [ -z "$PROJECT_DIR" ] || ! git -C "$PROJECT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "validate-docs: --all needs a git repository (run it inside one, or set CLAUDE_PROJECT_DIR to one)" >&2
    exit 2
  fi
  cd "$PROJECT_DIR"
  while IFS= read -r f; do
    scan_one "${f#./}"
  done < <(find . \
    \( -name "CLAUDE.md" -o -name "SKILL.md" \) \
    -not -path "*/.git/*" \
    -not -path "*/node_modules/*" \
    -not -path "*/.claude/worktrees/*" \
    | sort)
else
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  for arg in "$@"; do
    [ -n "$arg" ] || usage
    [ -f "$arg" ] || { echo "validate-docs: no such file: $arg" >&2; exit 2; }
    scan_one "$arg"
  done
fi

if [[ "${#WARNINGS[@]}" -eq 0 ]]; then
  echo "✓ Docs health: all CLAUDE.md and SKILL.md files pass."
  exit 0
fi

echo "Docs health violations found:"
for v in "${WARNINGS[@]}"; do
  echo "  • $v"
done
echo ""
echo "Reference: https://code.claude.com/docs/en/memory (CLAUDE.md) and https://code.claude.com/docs/en/skills (SKILL.md)"
exit 1
