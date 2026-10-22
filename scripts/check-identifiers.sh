#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Fails when a file carries something that only makes sense on one machine or inside one
# organisation, so it would leak that context if published. Generic patterns only:
#   home-path      an absolute home folder: /Users/<name>/, /home/<name>/, ~/go/src/
#   private-host   a host on a private suffix: <name>.internal, <name>.corp, <name>.intranet,
#                  and after :// or @, <name>.local or <name>.lan
#   monorepo-path  a path the kit's own layout never has: dev/agent-harness/ (the bridge is
#                  bridge/agent-harness/), backend/pkg/, backend/platform/
#   chat-link      a link to a chat or agent session: claude.ai/code/, claude.ai/chat/,
#                  claude.ai/share/
# Secrets and tokens are gitleaks's job, so no token shape is repeated here.
# A line that carries `gitleaks:allow` is a deliberate test fixture and is skipped, as gitleaks
# skips it. This script, which names the patterns, and its test, which plants hits, are skipped.
#
# Usage: check-identifiers.sh [root]   (default: the repo this script is in)
# Prints `<file>:<line>:<text>: <rule>` per hit. Exit 0 clean, 1 on any hit.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 2

RULES=(
  'home-path|/(Users|home)/[A-Za-z0-9_][A-Za-z0-9._-]*/|~/go/src/'
  'private-host|[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.(internal|corp|intranet)([^A-Za-z0-9_-]|$)|(://|@)[A-Za-z0-9.-]+\.(local|lan)([^A-Za-z0-9_-]|$)'
  'monorepo-path|(^|[^A-Za-z0-9_-])(dev/agent-harness|backend/pkg|backend/platform)/'
  'chat-link|claude\.ai/(code|chat|share)/'
)
hits=0
while IFS= read -r -d '' f; do
  f="${f#./}"
  case "$f" in scripts/check-identifiers.sh|scripts/check-identifiers.test.sh) continue ;; esac
  grep -Iq . "$f" 2>/dev/null || continue   # binary or empty
  for rule in "${RULES[@]}"; do
    name="${rule%%|*}"; re="${rule#*|}"
    while IFS= read -r line; do
      case "$line" in *gitleaks:allow*) continue ;; esac
      echo "$f:$(printf '%s' "$line" | cut -c1-200): $name"
      hits=$((hits + 1))
    done < <(grep -nE "$re" "$f" 2>/dev/null)
  done
done < <(find . -type f -not -path './.git/*' -not -path '*/node_modules/*' -print0 | sort -z)
[ "$hits" -eq 0 ] && { echo "identifiers: no machine- or organisation-specific identifier found"; exit 0; }
echo "identifiers: $hits line(s) carry a machine- or organisation-specific identifier"; exit 1
