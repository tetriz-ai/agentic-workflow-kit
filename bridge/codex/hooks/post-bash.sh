#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -uo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
kit_export_compat_env

INPUT="$(kit_read_stdin)"
kit_debug_hook_payload "post-bash" "$INPUT"
COMMAND="$(kit_command_from_payload "$INPUT")"

ADVISORY_OUTPUT=""
case "$COMMAND" in
  git\ push*)
    if [ -x "$(kit_script ship check-pr-description-drift.sh)" ] \
       && printf '%s' "$INPUT" | kit_claim ship check-pr-description-drift.sh; then
      ADVISORY_OUTPUT="$(printf '%s' "$INPUT" | "$(kit_script ship check-pr-description-drift.sh)" || true)"
    fi
    ;;
esac

if [ -n "$ADVISORY_OUTPUT" ]; then
  printf '%s' "$ADVISORY_OUTPUT" | kit_merge_hook_outputs "PostToolUse"
fi

exit 0
