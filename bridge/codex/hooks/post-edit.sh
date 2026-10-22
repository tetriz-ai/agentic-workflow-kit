#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -uo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
kit_export_compat_env

INPUT="$(kit_read_stdin)"
kit_debug_hook_payload "post-edit" "$INPUT"

# Each script is claimed once for the whole edit (kit_claim), then run for every edited file.
claimed() { [ -x "$(kit_script "$1" "$2")" ] && printf '%s' "$INPUT" | kit_claim "$1" "$2"; }
RUN_DISPATCHER=0; claimed guards post-edit-dispatcher.sh && RUN_DISPATCHER=1
RUN_SELF_CHECK=0; claimed review self-check.sh && RUN_SELF_CHECK=1
RUN_FORMAT=0; claimed guards format-on-edit.sh && RUN_FORMAT=1

ADVISORY_OUTPUT="$(
  kit_edit_payloads_from_payload "$INPUT" | while IFS= read -r PAYLOAD; do
    [ -n "$PAYLOAD" ] || continue

    if [ "$RUN_DISPATCHER" = 1 ]; then
      printf '%s' "$PAYLOAD" | "$(kit_script guards post-edit-dispatcher.sh)" || true
    fi

    if [ "$RUN_SELF_CHECK" = 1 ]; then
      printf '%s' "$PAYLOAD" | "$(kit_script review self-check.sh)" || true
    fi

    if [ "$RUN_FORMAT" = 1 ]; then
      printf '%s' "$PAYLOAD" | "$(kit_script guards format-on-edit.sh)" || true
    fi
  done
)"

if [ -n "$ADVISORY_OUTPUT" ]; then
  printf '%s' "$ADVISORY_OUTPUT" | kit_merge_hook_outputs "PostToolUse"
fi

exit 0
