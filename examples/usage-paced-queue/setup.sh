#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Builds the fixture: a main checkout, a per-issue worktree the queue works in, and a HOME whose
# personal statusLine the capture wrapper must keep rendering.
set -euo pipefail
DIR="$1"
export GIT_AUTHOR_NAME=example GIT_AUTHOR_EMAIL=example@example.com GIT_COMMITTER_NAME=example GIT_COMMITTER_EMAIL=example@example.com
git init -q -b main "$DIR/main"; cd "$DIR/main"
printf '.claude/triage/\n' > .gitignore
echo "# app" > README.md
git add .gitignore README.md; git commit -qm base
git worktree add -q "$DIR/wt-issue-12" -b issue-12 >/dev/null 2>&1
mkdir -p "$DIR/home/.claude"
cat > "$DIR/home/.claude/settings.json" <<'JSON'
{"statusLine":{"type":"command","command":"printf \"my-line %s\" \"$(jq -r .model.display_name)\""}}
JSON
