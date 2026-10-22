#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Builds the fixture: a feature branch whose newest commit is a day newer than PR #127's last
# description edit, and a stub gh that reports that PR (no network).
set -euo pipefail
DIR="$1"
git init -q -b feature/retries "$DIR/repo"
commit_at() { GIT_AUTHOR_DATE="$1 +0000" GIT_COMMITTER_DATE="$1 +0000" git -C "$DIR/repo" -c user.email=example@example.com -c user.name=example commit -q --allow-empty -m "$2"; }
commit_at 1772323200 "retry three times"            # 2026-03-01T00:00:00Z, when the PR opened
commit_at 1772409600 "retry five times, per review" # a day later
mkdir -p "$DIR/bin"
cat > "$DIR/bin/gh" <<'SH'
#!/bin/bash
case "$1" in
  auth) exit 0 ;;
  pr)   echo 127 ;;
  repo) echo acme/widgets ;;
  api)  echo "${BODY_EDITED:-2026-03-01T00:00:00Z}" ;;
esac
exit 0
SH
chmod +x "$DIR/bin/gh"
