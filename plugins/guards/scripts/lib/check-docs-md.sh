# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# shellcheck shell=bash
# Library: DOC-001..004 health checks for CLAUDE.md and SKILL.md.
#   DOC-001  CLAUDE.md over 200 lines
#   DOC-002  a `/skill-name` reference with no matching .claude/skills/<name>/,
#            no built-in command and no agentic-workflow-kit skill of that name
#   DOC-003  SKILL.md over 500 lines
#   DOC-004  SKILL.md without YAML frontmatter or without `description:`
#
# Sourced by post-edit-dispatcher.sh and validate-docs.sh (--all mode).
# Appends violations to the global WARNINGS array. Returns 0 always.
#
# Inputs:
#   $1 = FILE_PATH    path to check; absolute, or relative to $PROJECT_DIR
# Globals read:   PROJECT_DIR
# Globals written: WARNINGS (array)

# Built-in slash commands that are not project skills — skip DOC-002 ref checks.
_LIB_BUILTIN_COMMANDS=(
  init help clear compact memory context hooks permissions settings version
  review status debug batch simplify loop claude-api plugin agents mcp model
)
# Skills the agentic-workflow-kit plugins provide; a reference to one is not broken
# just because the repo has no .claude/skills/<name>/. Kept equal to the kit's skill
# folders by the repo's skill-list check.
_LIB_KIT_SKILLS=(
  review-panel claude-lens codex-lens ocr-lens harness-education review-lenses
  pr pr-communication pr-feedback codex-sweep github-issues
  tech-design-doc-writing tech-design-doc-review task-breakdown adr
  ship-task ship-queue bug-hunt extract-taste setup guide
)

_lib_is_builtin() {
  local name="$1" cmd
  for cmd in "${_LIB_BUILTIN_COMMANDS[@]}" "${_LIB_KIT_SKILLS[@]}"; do
    [[ "$cmd" == "$name" ]] && return 0
  done
  return 1
}

_lib_check_claude_md() {
  local file_path="$1" full_path="$2"
  local line_count
  line_count=$(wc -l < "$full_path")
  if [[ "$line_count" -gt 200 ]]; then
    WARNINGS+=("DOC-001 $file_path: $line_count lines (limit 200) — split into .claude/rules/ files or extract how-to content to skills")
  fi
  local skill_name
  while IFS= read -r skill_name; do
    [[ -z "$skill_name" ]] && continue
    _lib_is_builtin "$skill_name" && continue
    if [[ ! -d "$PROJECT_DIR/.claude/skills/$skill_name" ]]; then
      WARNINGS+=("DOC-002 $file_path: references skill '/$skill_name' but .claude/skills/$skill_name/ does not exist")
    fi
  # POSIX ERE (-E): `grep -P` is missing on macOS and BSD grep, and its error would be
  # swallowed below, silently turning this check off.
  done < <(grep -oE '`/[a-z][a-z0-9-]+`' "$full_path" 2>/dev/null \
             | tr -d '`' | sed 's|^/||' | sort -u || true)
}

_lib_check_skill_md() {
  local file_path="$1" full_path="$2"
  local line_count
  line_count=$(wc -l < "$full_path")
  if [[ "$line_count" -gt 500 ]]; then
    WARNINGS+=("DOC-003 $file_path: $line_count lines (limit 500) — move reference material to supporting files in the skill directory")
  fi
  local first_line
  first_line=$(head -1 "$full_path")
  if [[ "$first_line" != "---" ]]; then
    WARNINGS+=("DOC-004 $file_path: missing YAML frontmatter — add --- block with 'name:' and 'description:' at the top")
  else
    local frontmatter
    frontmatter=$(awk '/^---/{n++; if(n==2) exit} n==1' "$full_path")
    if ! echo "$frontmatter" | grep -q '^description:'; then
      WARNINGS+=("DOC-004 $file_path: frontmatter missing 'description:' — Claude uses this to decide when to auto-invoke the skill")
    fi
  fi
}

_lib_check_docs_md() {
  local file_path="$1" full_path basename
  if [[ "$file_path" = /* ]]; then full_path="$file_path"; else full_path="$PROJECT_DIR/$file_path"; fi
  [[ -f "$full_path" ]] || return 0
  basename=$(basename "$full_path")
  case "$basename" in
    CLAUDE.md) _lib_check_claude_md "$file_path" "$full_path" ;;
    SKILL.md)  _lib_check_skill_md  "$file_path" "$full_path" ;;
  esac
}
