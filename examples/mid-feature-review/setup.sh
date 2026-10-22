#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Builds the fixture: a repo on a feature branch whose cadence baseline is the base commit, then
# five commits of a pagination helper (the last one carries the off-by-one).
set -euo pipefail
DIR="$1"; KIT="$(cd "$(dirname "$0")/../.." && pwd)"
export GIT_AUTHOR_NAME=example GIT_AUTHOR_EMAIL=example@example.com GIT_COMMITTER_NAME=example GIT_COMMITTER_EMAIL=example@example.com
git init -q -b main "$DIR/repo"; cd "$DIR/repo"
echo "# app" > README.md; git add README.md; git commit -qm "base"
git checkout -qb feature/pagination
bash "$KIT/plugins/review/scripts/review-cadence.sh" reset
for i in 1 2 3 4; do printf 'def page_%s(): pass\n' "$i" >> paginate.py; git add paginate.py; git commit -qm "pagination step $i"; done
printf 'def last_page(total, size):\n    return total // size  # off by one when total %% size != 0\n' >> paginate.py
git add paginate.py; git commit -qm "last page"
