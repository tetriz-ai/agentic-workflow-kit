#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Builds the fixture: a main checkout with untracked local files, the starter's .worktreeinclude
# rules and post-checkout githook installed through /starter:setup's script.
set -euo pipefail
DIR="$1"; KIT="$(cd "$(dirname "$0")/../.." && pwd)"
export GIT_AUTHOR_NAME=example GIT_AUTHOR_EMAIL=example@example.com GIT_COMMITTER_NAME=example GIT_COMMITTER_EMAIL=example@example.com
git init -q -b main "$DIR/main"; cd "$DIR/main"
printf '.env\nconfig/local.yml\n' > .gitignore
printf 'optional .env\nrequired config/local.yml\n' > .worktreeinclude
echo "# app" > README.md
git add .gitignore .worktreeinclude README.md; git commit -qm base
bash "$KIT/plugins/starter/scripts/setup.sh" apply githooks >/dev/null
echo "API_KEY=local-only" > .env
mkdir -p config; echo "port: 8080" > config/local.yml
