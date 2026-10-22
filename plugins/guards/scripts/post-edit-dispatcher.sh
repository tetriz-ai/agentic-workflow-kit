#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# PostToolUse Edit|Write|MultiEdit dispatcher: one hook entry that routes an
# edited file to the checks that apply to it, each a lib/check-*.sh sourced only
# when its route matches:
#   lib/check-generated.sh  the file's header says it is generated
#   lib/check-docs-md.sh    CLAUDE.md and SKILL.md health (size, frontmatter,
#                           skill references)
#
# Performance: one shell startup, one jq parse, dispatch by file pattern. A new
# check is a new lib plus a route here, not another hook entry.
#
# Behaviour: emits hookSpecificOutput.additionalContext when any check finds a
# violation; always exits 0 (advisory, non-blocking).

set -euo pipefail

INPUT=$(cat)

# file_path is top-level for Edit, Write and MultiEdit. The `|| true` absorbs jq
# failures (malformed JSON, version skew) so set -e doesn't abort; the
# empty-FILE_PATH guard below handles those uniformly. Every check reads the file
# as it is on disk after the edit, so the edit payload itself is not needed.
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)
[ -n "$FILE_PATH" ] || exit 0

# Resolve the repo root from the edited file's OWN worktree, not from
# CLAUDE_PROJECT_DIR. Under git worktrees, CLAUDE_PROJECT_DIR is the session
# launch dir (often the main checkout, or unset), which is not necessarily the
# worktree the file lives in; trusting it makes the strip below fail, REL stays
# absolute, and the traversal guard silently skips the check. Deriving the root
# from the file follows the artifact and is worktree-correct. This git fork is on the WARM path only (a candidate extension
# already matched the pre-filter and jq has run); the cold path exited above.
FILE_DIR=$(dirname "$FILE_PATH")
# A Write that creates a file in a brand-new directory has no $FILE_DIR yet at
# PostToolUse time; walk up to the nearest existing ancestor so git can still
# resolve the root, rather than silently skipping the edit that introduces the
# new tree.
probe="$FILE_DIR"
while [ -n "$probe" ] && [ "$probe" != "/" ] && [ ! -d "$probe" ]; do
  probe=$(dirname "$probe")
done
PROJECT_DIR=$(cd "$probe" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$PROJECT_DIR" ]; then
  # REL = (existing ancestor's repo-relative prefix, from git --show-prefix)
  # + (the literal remainder of the path below that ancestor). --show-prefix
  # avoids a string strip of PROJECT_DIR, which breaks when git resolves a
  # symlinked root (macOS /tmp -> /private/tmp); stripping the literal $probe is
  # always safe because $probe was derived from $FILE_PATH via dirname, so it is
  # a literal prefix of it. Handles both an existing file (probe == FILE_DIR,
  # remainder == basename) and a new file in a new dir (probe is an ancestor).
  PREFIX=$(cd "$probe" 2>/dev/null && git rev-parse --show-prefix 2>/dev/null || true)
  REMAINDER="${FILE_PATH#"$probe"/}"
  REL="${PREFIX}${REMAINDER}"
else
  # File is not inside a git repo — fall back to the session's project dir.
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  REL="$FILE_PATH"
  case "$REL" in "$PROJECT_DIR"/*) REL="${REL#"$PROJECT_DIR"/}" ;; esac
fi

# Defense in depth: if REL still starts with `/` (an absolute path that didn't
# match the PROJECT_DIR strip) or contains a `..` traversal segment, the edit
# is operating outside our project tree. Hooks have no business there - exit 0
# silently. Without this, a crafted file_path could steer a check's file read
# outside the project.
case "$REL" in
  /*|*/../*|../*|*/..) exit 0 ;;
esac

WARNINGS=()
# The checks live beside this script, inside the plugin.
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

# ── Dispatch ──────────────────────────────────────────────────────────────────
# Each arm guards the lib file's presence and absorbs any failure: this hook's
# contract is "always exits 0 (advisory)", so a corrupted or renamed lib, or a
# check-internal error, must not abort under `set -e`.
FULL_PATH="$PROJECT_DIR/$REL"
[ -f "$FULL_PATH" ] || FULL_PATH="$FILE_PATH"

# shellcheck source=lib/check-generated.sh
[ -f "$LIB/check-generated.sh" ] && . "$LIB/check-generated.sh" \
  && _lib_check_generated "$REL" "$FULL_PATH" || true

case "$REL" in
  */CLAUDE.md|CLAUDE.md|*/SKILL.md|SKILL.md)
    # shellcheck source=lib/check-docs-md.sh
    [ -f "$LIB/check-docs-md.sh" ] && . "$LIB/check-docs-md.sh" \
      && _lib_check_docs_md "$REL" || true
    ;;
esac

# ── Emit ──────────────────────────────────────────────────────────────────────
if [ "${#WARNINGS[@]}" -gt 0 ]; then
  MSG=""
  for w in "${WARNINGS[@]}"; do
    if [ -z "$MSG" ]; then MSG="$w"; else MSG="$MSG"$'\n\n'"$w"; fi
  done
  # Feed MSG via stdin (jq -Rs slurps raw stdin into one string) rather than
  # --arg: a very large message (many violations in one huge edit) can exceed
  # ARG_MAX, making jq fail — which under set -e would abort before the exit 0
  # below and break the always-exit-0 contract. `|| true` is the final guard.
  printf '%s' "$MSG" | jq -Rsc '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:.}}' || true
fi

exit 0
