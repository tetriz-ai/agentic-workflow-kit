#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Select Claude only for a Codex author; every other authoring runtime uses Codex.
# The selected engine owns its status token and outcome classification; this wrapper
# treats REVIEW_AUTHOR_RUNTIME as an open-ended runtime name, not a closed enum.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_ENGINE="$SCRIPT_DIR/../../codex-lens/scripts/codex-lens.sh"
CLAUDE_ENGINE="$SCRIPT_DIR/../../claude-lens/scripts/claude-lens.sh"

# Runtime names compare case-insensitively and without surrounding blanks ("Codex" is codex).
author=$(printf '%s' "${REVIEW_AUTHOR_RUNTIME:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
if [ -z "$author" ]; then
  if [ -n "${CODEX_SESSION_ID:-}" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    echo "COUNTERPART-LENS: FAILED conflicting authoring runtime markers; set REVIEW_AUTHOR_RUNTIME=<runtime-name>"
    exit 0
  elif [ -n "${CODEX_SESSION_ID:-}" ]; then
    author=codex
    source=codex-marker
  elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    author=claude
    source=claude-marker
  else
    author=non-codex
    source=default
  fi
else
  source=explicit
fi

if [ "$author" = codex ]; then
  ENGINE="$CLAUDE_ENGINE"
  engine_name=claude
else
  ENGINE="$CODEX_ENGINE"
  engine_name=codex
fi
if [ ! -r "$ENGINE" ]; then
  echo "COUNTERPART-LENS: FAILED selected engine is missing or unreadable: $ENGINE"
  exit 0
fi
printf 'COUNTERPART-LENS: routing author=%s source=%s engine=%s\n' "$author" "$source" "$engine_name" >&2
exec bash "$ENGINE" "$@"
