#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
kit_export_compat_env

INPUT="$(kit_read_stdin)"
kit_debug_hook_payload "session-start" "$INPUT"

ADVISORY_OUTPUT="$(
if [ -x "$(kit_script queue session-start-dispatcher.sh)" ] \
   && printf '%s' "$INPUT" | kit_claim queue session-start-dispatcher.sh; then
  printf '%s' "$INPUT" | "$(kit_script queue session-start-dispatcher.sh)" || true
fi
)"

if [ -n "$ADVISORY_OUTPUT" ]; then
  printf '%s' "$ADVISORY_OUTPUT" | kit_merge_hook_outputs "SessionStart"
fi

SESSION_SOURCE="$(printf '%s' "$INPUT" | jq -r '.source // .session_start_source // empty' 2>/dev/null || true)"
if [ "$SESSION_SOURCE" != "clear" ] && [ "$SESSION_SOURCE" != "compact" ]; then
  validation_command=()
  if [ -x "$ROOT/.codex/hooks/validate-harness-if-needed.sh" ]; then
    validation_command=("$ROOT/.codex/hooks/validate-harness-if-needed.sh")
  elif [ -x "$ROOT/.agent-harness/validate-codex-harness.sh" ]; then
    validation_command=("$ROOT/.agent-harness/validate-codex-harness.sh" --quick)
  else
    echo "Codex harness validation unavailable: both the cache helper and direct validator are missing or non-executable." >&2
  fi

  if [ "${#validation_command[@]}" -eq 0 ]; then
    exit 0
  fi
  validation_output="$(mktemp "${TMPDIR:-/tmp}/agentic-kit-codex-harness-validate.out.XXXXXX")"
  validation_error="$(mktemp "${TMPDIR:-/tmp}/agentic-kit-codex-harness-validate.err.XXXXXX")"
  if ! "${validation_command[@]}" >"$validation_output" 2>"$validation_error"; then
    {
      echo "Codex harness drift detected. Run:"
      echo "  .agent-harness/sync-codex-harness.sh"
      cat "$validation_error"
      cat "$validation_output"
    } >&2
  fi
  rm -f "$validation_output" "$validation_error"
fi

exit 0
