#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Builds the fixture: a branch that adds a migration and changes a billing handler, and a team
# lens for billing code in .claude/review-lenses.
set -euo pipefail
DIR="$1"
export GIT_AUTHOR_NAME=example GIT_AUTHOR_EMAIL=example@example.com GIT_COMMITTER_NAME=example GIT_COMMITTER_EMAIL=example@example.com
git init -q -b main "$DIR/repo"; cd "$DIR/repo"
mkdir -p .claude/review-lenses services/billing db/migrations
cat > .claude/review-lenses/billing.md <<'LENS'
---
lens: billing
applies-to:
  - "services/billing/**"
summary: "Money is integer cents, every charge is idempotent."
---
## Focus
Amounts are integer cents end to end; a retried charge cannot charge twice.
## Grounding
Read the charge path from the handler to the payment client.
LENS
echo "package billing" > services/billing/charge.go
echo "# app" > README.md
git add -A; git commit -qm base
git checkout -qb feature/refunds
echo "ALTER TABLE charges ADD COLUMN refunded_cents bigint;" > db/migrations/0002_refunds.up.sql
echo "func Refund() {}" >> services/billing/charge.go
git add -A; git commit -qm "refunds"
