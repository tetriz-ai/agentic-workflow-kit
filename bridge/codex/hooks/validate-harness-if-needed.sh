#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

VALIDATOR="${AGENTIC_KIT_CODEX_HARNESS_VALIDATOR:-$ROOT/.agent-harness/validate-codex-harness.sh}"
[ -x "$VALIDATOR" ] || {
  echo "Codex harness validator is missing or non-executable: $VALIDATOR" >&2
  exit 1
}

validate_prerequisites() {
  local required yq_probe
  for required in awk basename cat dirname find git grep id jq ln mkdir mktemp mv python3 readlink rm sed sort stat tr wc yq; do
    command -v "$required" >/dev/null 2>&1 || {
      echo "Codex harness validation requires '$required', but it is unavailable on PATH." >&2
      return 1
    }
  done
  [ "$(basename /probe-dir/harness-probe 2>/dev/null)" = "harness-probe" ] || {
    echo "Codex harness validation requires a working basename." >&2
    return 1
  }
  jq -n true >/dev/null 2>&1 || {
    echo "Codex harness validation requires a working jq." >&2
    return 1
  }
  yq_probe="$(printf 'description: harness-probe\n' | yq -r '.description // ""' - 2>/dev/null)" || {
    echo "Codex harness validation requires a working, compatible yq." >&2
    return 1
  }
  [ "$yq_probe" = "harness-probe" ] || {
    echo "Codex harness validation requires a working, compatible yq." >&2
    return 1
  }
  python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 9))' >/dev/null 2>&1 || {
    echo "Codex harness validation requires Python 3.9 or newer." >&2
    return 1
  }
}

# Tool installations and PATH can change independently of the source tree, so
# keep this cheap check outside the source fingerprint cache.
validate_prerequisites
CONTEXT_VALIDATOR="$ROOT/.agent-harness/validate-context-budgets.sh"
if [ -x "$CONTEXT_VALIDATOR" ]; then
  "$CONTEXT_VALIDATOR" --staged-only >/dev/null
fi

# Keep this list aligned with the surfaces read directly or indirectly by the
# quick validator. The committed tree identity is cheap to hash; only dirty or
# untracked files require content hashing on a cache hit.
HARNESS_PATHS=(
  .codex
  .claude/agents
  .claude/rules
  .claude/skills
  .claude/commands
  .claude/output-styles
  .claude/workflows
  .claude/CLAUDE.md
  .claude/launch.json
  .claude/loop.md
  .claude-plugin
  .agents/skills
  .lsp.json
  .mcp.json
  .worktreeinclude
  AGENTS.md
  CLAUDE.md
  .agent-harness
)

stat_uid() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"
}

stat_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

stat_follow_mode() {
  stat -Lc '%a' "$1" 2>/dev/null || stat -Lf '%Lp' "$1"
}

hash_worktree_path() {
  local relative_path="$1"
  local full_path="$ROOT/$relative_path"
  local mode
  local object_id

  if [ -L "$full_path" ]; then
    object_id="$(readlink "$full_path" | git hash-object --stdin)"
    printf 'symlink\0%s\0%s\0' "$relative_path" "$object_id"
    if [ -f "$full_path" ]; then
      mode="$(stat_follow_mode "$full_path")"
      printf 'symlink-target\0%s\0%s\0%s\0' "$relative_path" "$mode" "$(git hash-object --no-filters "$full_path")"
    elif [ -d "$full_path" ]; then
      printf 'symlink-target-directory\0%s\0' "$relative_path"
    else
      printf 'symlink-target-missing\0%s\0' "$relative_path"
    fi
  elif [ -f "$full_path" ]; then
    mode="$(stat_mode "$full_path")"
    object_id="$(git hash-object --no-filters "$full_path")"
    printf 'file\0%s\0%s\0%s\0' "$relative_path" "$mode" "$object_id"
  else
    printf 'missing\0%s\0' "$relative_path"
  fi
}

hash_tracked_executable_mode() {
  local relative_path="$1"
  local full_path="$ROOT/$relative_path"
  if [ -L "$full_path" ]; then
    printf 'tracked-executable-symlink\0%s\0' "$relative_path"
  elif [ -f "$full_path" ]; then
    printf 'tracked-executable-mode\0%s\0%s\0' "$relative_path" "$(stat_mode "$full_path")"
  else
    printf 'tracked-executable-missing\0%s\0' "$relative_path"
  fi
}

fingerprint_inputs() {
  git ls-tree -r HEAD -- "${HARNESS_PATHS[@]}" 2>/dev/null || true
  while IFS= read -r -d '' changed_path; do
    hash_worktree_path "$changed_path"
  done < <(git diff --name-only -z HEAD -- "${HARNESS_PATHS[@]}")
  while IFS= read -r -d '' untracked_path; do
    hash_worktree_path "$untracked_path"
  done < <(git ls-files --others --exclude-standard -z -- "${HARNESS_PATHS[@]}")
  while IFS= read -r -d '' ignored_path; do
    case "$ignored_path" in
      .codex/config.toml|.codex/hooks.json|.codex/rules/default.rules|AGENTS.md|CLAUDE.md|.worktreeinclude|.lsp.json|.mcp.json)
        hash_worktree_path "$ignored_path"
        ;;
      .codex/hooks/*.sh|.codex/agents/*.toml|.claude/agents/*.md|.claude/rules/*.md)
        [[ "${ignored_path#*/}" != */*/* ]] && hash_worktree_path "$ignored_path"
        ;;
      .claude/skills/*/SKILL.md)
        [[ "$ignored_path" =~ ^\.claude/skills/[^/]+/SKILL\.md$ ]] && hash_worktree_path "$ignored_path"
        ;;
      .claude/skills/*)
        if [ -L "$ROOT/$ignored_path" ] && [ -d "$ROOT/$ignored_path" ]; then
          hash_worktree_path "$ignored_path"
        fi
        ;;
    esac
  done < <(git ls-files --others --ignored --exclude-standard -z -- "${HARNESS_PATHS[@]}")
  while IFS= read -r -d '' index_entry; do
    case "$index_entry" in
      100755\ *) hash_tracked_executable_mode "${index_entry#*$'\t'}" ;;
      120000\ *) hash_worktree_path "${index_entry#*$'\t'}" ;;
    esac
  done < <(git ls-files -s -z -- "${HARNESS_PATHS[@]}")

  # Test callers may substitute a validator outside the checkout. Hash it
  # explicitly so changing validation logic can never reuse an older result.
  if [[ "$VALIDATOR" != "$ROOT/"* ]]; then
    printf 'external-validator\0%s\0' "$(git hash-object --no-filters "$VALIDATOR")"
  fi
}

fingerprint="$(fingerprint_inputs | git hash-object --stdin)"

cache_path_is_private() {
  local path="$1"
  local current_uid mode
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  current_uid="$(id -u)"
  [ "$(stat_uid "$path")" = "$current_uid" ] || return 1
  mode="$(stat_mode "$path")"
  (( (8#$mode & 0022) == 0 ))
}

cache_parent_chain_is_safe() {
  local path mode
  path="$(dirname "$1")"
  while :; do
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    mode="$(stat_mode "$path")"
    if (( (8#$mode & 0022) != 0 && (8#$mode & 01000) == 0 )); then
      return 1
    fi
    [ "$path" = "/" ] && return 0
    path="$(dirname "$path")"
  done
}

cache_stamp_is_private() {
  local path="$1"
  local mode
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(stat_uid "$path")" = "$(id -u)" ] || return 1
  mode="$(stat_mode "$path")"
  (( (8#$mode & 0022) == 0 ))
}

cache_base="${AGENTIC_KIT_CODEX_HARNESS_CACHE_DIR:-${TMPDIR:-/tmp}/agentic-kit-codex-harness-cache-${UID:-user}}"
umask 077
if ! mkdir -p "$cache_base" 2>/dev/null; then  # private: umask 077 above
  AGENTIC_KIT_CONTEXT_BUDGET_SKIP_STAGED=1 "$VALIDATOR" --quick
  exit $?
fi
cache_base="$(cd "$cache_base" 2>/dev/null && pwd -P)" || {
  AGENTIC_KIT_CONTEXT_BUDGET_SKIP_STAGED=1 "$VALIDATOR" --quick
  exit $?
}
if ! cache_path_is_private "$cache_base" || ! cache_parent_chain_is_safe "$cache_base"; then
  AGENTIC_KIT_CONTEXT_BUDGET_SKIP_STAGED=1 "$VALIDATOR" --quick
  exit $?
fi

checkout_key="$(printf '%s\0%s' "$ROOT" "$(git rev-parse --absolute-git-dir 2>/dev/null || printf '%s' "$ROOT")" | git hash-object --stdin)"
stamp="$cache_base/$checkout_key.quick"
if [ -e "$stamp" ] || [ -L "$stamp" ]; then
  if ! cache_stamp_is_private "$stamp"; then
    AGENTIC_KIT_CONTEXT_BUDGET_SKIP_STAGED=1 "$VALIDATOR" --quick
    exit $?
  fi
  if [ "$(sed -n '1p' "$stamp")" = "$fingerprint" ]; then
    exit 0
  fi
fi

if AGENTIC_KIT_CONTEXT_BUDGET_SKIP_STAGED=1 "$VALIDATOR" --quick; then
  stamp_tmp="$(mktemp "$cache_base/$checkout_key.quick.XXXXXX")"
  printf '%s\n' "$fingerprint" >"$stamp_tmp"
  mv -f "$stamp_tmp" "$stamp"
else
  exit $?
fi
