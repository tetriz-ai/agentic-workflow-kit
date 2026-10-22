#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Guards the prompt surfaces shared by Claude and Codex. These are explicit
# budgets, rather than a lower project_doc_max_bytes ceiling that could truncate guidance.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

MODE="${1:-all}"
case "$MODE" in
  all|--all) MODE="all" ;;
  staged-only|--staged-only) MODE="staged-only" ;;
  *) echo "usage: $0 [--all|--staged-only]" >&2; exit 2 ;;
esac

fail() { echo "ERROR: $*" >&2; exit 1; }
bytes() { wc -c < "$1" | tr -d '[:space:]'; }
warn() { echo "WARN: $*" >&2; }

ROOT_GUIDANCE_MAX_BYTES=16000
ALWAYS_RULES_MAX_BYTES=28000   # the rules /starter:setup writes use about 64% of it
SKILL_DESCRIPTIONS_MAX_BYTES=40000
STAGED_CONTEXT_MAX_BYTES=8192
BASELINE=".agent-harness/context-budget-baseline.json"

warn_headroom() {
  local name="$1" used="$2" maximum="$3" percent
  percent=$((used * 100 / maximum))
  if [ "$percent" -ge 90 ]; then
    warn "$name is at ${percent}% of its budget (${used}/${maximum} bytes); review its next change before the hard cap blocks it."
  elif [ "$percent" -ge 80 ]; then
    warn "$name is at ${percent}% of its budget (${used}/${maximum} bytes); move detail that only some tasks need into a path-scoped rule or a linked file before it reaches the cap."
  fi
}

warn_growth() {
  local name="$1" used="$2" baseline growth
  [ -f "$BASELINE" ] || return 0
  baseline="$(jq -r --arg name "$name" '.surfaces[$name] // empty' "$BASELINE")"
  [ -n "$baseline" ] && [ "$baseline" != "null" ] || return 0
  growth=$(((used - baseline) * 100 / baseline))
  if [ "$growth" -gt "$(jq -r '.max_growth_percent' "$BASELINE")" ]; then
    warn "$name grew ${growth}% from its reviewed baseline (${baseline} -> ${used} bytes); confirm that the new always-available context is necessary."
  fi
}

if [ "$MODE" = "all" ]; then
  command -v jq >/dev/null 2>&1 || fail "jq is required to compare context-budget baselines"
  # Resolve yq by parsing with it (yq-resolve.sh, beside this script): kislyuk's python-yq
  # answers to the same name and would misread every skill.
  # shellcheck source=yq-resolve.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/yq-resolve.sh" || fail "yq-resolve.sh is missing beside $0"
  YQ="$(resolve_yq)" || { yq_missing_hint; fail "no working yq found to read skill frontmatter"; }
  # The baseline is the repo's own reviewed sizes; without one, growth is not checked.
  if [ -f "$BASELINE" ]; then
    jq empty "$BASELINE" >/dev/null || fail "invalid context-budget baseline: $BASELINE"
  else
    echo "NOTE: no $BASELINE; growth against a reviewed baseline is not checked." >&2
  fi

  root_bytes=0
  [ -f CLAUDE.md ] && root_bytes="$(bytes CLAUDE.md)"
  [ "$root_bytes" -le "$ROOT_GUIDANCE_MAX_BYTES" ] \
    || fail "CLAUDE.md is ${root_bytes} bytes; budget is ${ROOT_GUIDANCE_MAX_BYTES}. Move conditional detail behind an existing pointer."
  warn_headroom "root guidance" "$root_bytes" "$ROOT_GUIDANCE_MAX_BYTES"
  warn_growth "root_guidance" "$root_bytes"

  always_bytes=0
  while IFS=$'\t' read -r rule scope; do
    [ "$scope" = "always" ] || continue
    always_bytes=$((always_bytes + $(bytes "$rule")))
  done < <(.agent-harness/rules-for-paths.sh --always)
  [ "$always_bytes" -le "$ALWAYS_RULES_MAX_BYTES" ] \
    || fail "always-loaded rules are ${always_bytes} bytes; budget is ${ALWAYS_RULES_MAX_BYTES}. Keep only universal invariants unscoped."
  warn_headroom "always-loaded rules" "$always_bytes" "$ALWAYS_RULES_MAX_BYTES"
  warn_growth "always_rules" "$always_bytes"

  description_bytes=0
  while IFS= read -r -d '' skill; do
    # yq resolves every valid YAML scalar form before byte-counting it. Its raw
    # output always adds one presentation newline, which is not part of the value.
    value_bytes=$(( $(awk '
    NR == 1 { in_frontmatter = ($0 == "---"); next }
    in_frontmatter && $0 == "---" { exit }
    in_frontmatter { print }
  ' "$skill" | "$YQ" -r '.description // ""' - | wc -c | tr -d '[:space:]') - 1 ))
    description_bytes=$((description_bytes + value_bytes))
  done < <(find .claude/skills -mindepth 2 -maxdepth 2 -name SKILL.md -print0 2>/dev/null)
  [ "$description_bytes" -le "$SKILL_DESCRIPTIONS_MAX_BYTES" ] \
    || fail "skill descriptions are ${description_bytes} bytes; budget is ${SKILL_DESCRIPTIONS_MAX_BYTES}. Keep discovery text to activation criteria, not workflow detail."
  warn_headroom "skill descriptions" "$description_bytes" "$SKILL_DESCRIPTIONS_MAX_BYTES"
  warn_growth "skill_descriptions" "$description_bytes"
fi

staged_bytes=0
stage_dir="${SESSION_CONTEXT_DIR:-.claude/triage/session-context}"
if [ "$MODE" = "staged-only" ] || [ "${AGENTIC_KIT_CONTEXT_BUDGET_SKIP_STAGED:-0}" != 1 ]; then
  if [ -d "$stage_dir" ]; then
    snapshot="$stage_dir/ship-queue-nudge-current"
    while IFS= read -r -d '' staged; do
      staged_bytes=$((staged_bytes + $(bytes "$staged")))
    done < <(find "$stage_dir" -maxdepth 1 -type f \( -name '*.md' -o -name '*.msg' \) -print0)
    for staged in "$snapshot/context.md" "$snapshot/message.msg"; do
      [ -f "$staged" ] || continue
      staged_bytes=$((staged_bytes + $(bytes "$staged")))
    done
  fi
fi
if [ "$MODE" = "staged-only" ] || [ "${AGENTIC_KIT_CONTEXT_BUDGET_SKIP_STAGED:-0}" != 1 ]; then
  [ "$staged_bytes" -le "$STAGED_CONTEXT_MAX_BYTES" ] \
    || fail "ambient staged session context is ${staged_bytes} bytes; budget is ${STAGED_CONTEXT_MAX_BYTES}. Keep detailed data under session-context/details/ and inject a summary plus reference."
  warn_headroom "ambient staged context" "$staged_bytes" "$STAGED_CONTEXT_MAX_BYTES"
fi

if [ "$MODE" = "staged-only" ]; then
  printf 'Staged context budget passed: staged=%s (~%s tokens) bytes\n' \
    "$staged_bytes" "$(((staged_bytes + 3) / 4))"
else
  printf 'Context budgets passed: root=%s (~%s tokens) always=%s (~%s) skill-descriptions=%s (~%s) staged=%s (~%s) bytes\n' \
    "$root_bytes" "$(((root_bytes + 3) / 4))" \
    "$always_bytes" "$(((always_bytes + 3) / 4))" \
    "$description_bytes" "$(((description_bytes + 3) / 4))" \
    "$staged_bytes" "$(((staged_bytes + 3) / 4))"
fi
