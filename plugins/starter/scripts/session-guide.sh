#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# SessionStart hook: put the kit's short guide (skills/guide/SKILL.md, without its frontmatter)
# into the session as additionalContext, so the agent knows which kit skill fits a situation.
# It costs that many tokens in every session, which is why the guide stays one short table.
# Advisory: prints nothing and exits 0 when jq or the guide is missing.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
GUIDE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/guide/SKILL.md"
[ -r "$GUIDE" ] || exit 0
body="$(awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm' "$GUIDE")"
[ -n "$body" ] || exit 0
jq -nc --arg ctx "$body" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
