#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Builds the fixture: a repo whose commit_gate (in .agentic-workflow-kit.json) runs a test script
# that currently fails, an npm package with a lockfile, and a stub npm that rewrites the lockfile
# the way `npm install --package-lock-only` would.
set -euo pipefail
DIR="$1"
export GIT_AUTHOR_NAME=example GIT_AUTHOR_EMAIL=example@example.com GIT_COMMITTER_NAME=example GIT_COMMITTER_EMAIL=example@example.com
git init -q -b main "$DIR/repo"; cd "$DIR/repo"
printf '#!/bin/sh\necho "1 test failed: last_page(10, 3) == 3, want 4"\nexit 1\n' > test.sh; chmod +x test.sh
printf '{"commit_gate": "./test.sh"}\n' > .agentic-workflow-kit.json
printf '{"name":"app","dependencies":{}}\n' > package.json
printf '{"lockfileVersion":3,"packages":{}}\n' > package-lock.json
git add -A; git commit -qm base
mkdir -p "$DIR/bin"
printf '#!/bin/sh\nprintf %s "{\\"lockfileVersion\\":3,\\"packages\\":{\\"node_modules/left-pad\\":{}}}" > package-lock.json\n' "'%s\\n'" > "$DIR/bin/npm"
chmod +x "$DIR/bin/npm"
