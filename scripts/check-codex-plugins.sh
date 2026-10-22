#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Loads the Codex packaging non-interactively, in a temporary CODEX_HOME so the user's Codex
# setup is never touched: adds this repo as a Codex marketplace, checks that `codex plugin list`
# shows exactly the plugins .agents/plugins/marketplace.json lists, installs each one, and checks
# that each reads as installed and enabled at its manifest version. Needs the codex CLI and jq.
# Exit 1 on any mismatch, 2 when codex or jq is missing.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for t in codex jq; do command -v "$t" >/dev/null 2>&1 || { echo "check-codex-plugins: $t is required" >&2; exit 2; }; done
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export CODEX_HOME="$TMP/codex" HOME="$TMP/home"; mkdir -p "$CODEX_HOME" "$HOME"
problems=0
bad() { echo "  FAIL $1"; problems=$((problems + 1)); }

echo "codex $(codex --version 2>/dev/null | head -1)"
codex plugin marketplace add "$ROOT" >/dev/null 2>"$TMP/err" || { bad "marketplace add: $(cat "$TMP/err")"; exit 1; }
want="$(jq -r '.plugins[].name' "$ROOT/.agents/plugins/marketplace.json" | sort)"
listed="$(codex plugin list 2>/dev/null | awk 'NR > 1 && $1 ~ /@agentic-workflow-kit$/ { sub(/@.*/, "", $1); print $1 }' | sort)"
[ "$listed" = "$want" ] || bad "codex plugin list shows [$(printf '%s' "$listed" | tr '\n' ' ')], the marketplace lists [$(printf '%s' "$want" | tr '\n' ' ')]"
for p in $want; do
  codex plugin add "$p@agentic-workflow-kit" >/dev/null 2>"$TMP/err" || { bad "plugin add $p: $(cat "$TMP/err")"; continue; }
  version="$(jq -r '.version' "$ROOT/plugins/$p/.codex-plugin/plugin.json")"
  codex plugin list 2>/dev/null | grep -qE "^$p@agentic-workflow-kit +installed, enabled +$version " \
    && echo "  ok   $p $version installed and enabled" || bad "$p is not listed as installed, enabled, $version"
done
[ "$problems" -eq 0 ] && { echo "check-codex-plugins: every plugin loads"; exit 0; }
echo "check-codex-plugins: $problems problem(s)"; exit 1
