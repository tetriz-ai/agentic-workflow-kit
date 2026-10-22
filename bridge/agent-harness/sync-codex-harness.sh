#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# sync-codex-harness.sh [--force]: install or refresh the Codex bridge in the repo you
# run it from, then validate it. Run it from a clone of the kit
# (bridge/agent-harness/sync-codex-harness.sh) to add or refresh the adapters, or from
# the installed copy (.agent-harness/sync-codex-harness.sh) to re-check.
#   .codex/          hook adapters, hooks.json, execpolicy rules, config.toml
#   .agent-harness/  the router, validators and helpers (this folder)
#   AGENTS.md        a symlink to CLAUDE.md, when CLAUDE.md exists
#   .agents/skills   a symlink to .claude/skills, when that folder exists
# Local edits to installed files are kept unless --force is given.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "sync-codex-harness: run inside a git repo" >&2; exit 2; }
FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  "") ;;
  *) echo "usage: $0 [--force]" >&2; exit 2 ;;
esac
cd "$ROOT"
# shellcheck source=bridge-install.sh
. "$HERE/bridge-install.sh"

echo "Codex bridge -> $ROOT"
# Every destination first: a symlink that leads out of the repo stops the sync before any write.
[ -d "$HERE/../codex" ] && bridge_check_tree "$HERE/../codex" "$ROOT/.codex"
bridge_check_tree "$HERE" "$ROOT/.agent-harness"
bridge_check_path AGENTS.md
bridge_check_path .agents/skills
if [ -d "$HERE/../codex" ]; then
  bridge_install_tree "$HERE/../codex" "$ROOT/.codex" "$FORCE"
else
  echo "  (adapters not refreshed: run the kit's bridge/agent-harness/sync-codex-harness.sh for that)"
fi
bridge_install_tree "$HERE" "$ROOT/.agent-harness" "$FORCE"
if [ -f CLAUDE.md ]; then bridge_link AGENTS.md CLAUDE.md || [ $? -ne 2 ] || exit 2
else echo "  AGENTS.md not linked: there is no CLAUDE.md (add one and re-run to give Codex the same guidance)"; fi
if [ -d .claude/skills ]; then .agent-harness/sync-codex-skills.sh
else echo "  .agents/skills not linked: there is no .claude/skills"; fi
.agent-harness/validate-codex-harness.sh --full

echo "Codex harness sync complete."
