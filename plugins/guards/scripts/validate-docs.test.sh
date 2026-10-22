#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for validate-docs.sh, the batch docs-health scan: its exit contract (0 pass, 1 a
# violation, 2 usage or a missing file or --all outside a git repository) and the DOC checks it
# shares with the edit-time dispatcher.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/validate-docs.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; git init -q "$REPO"
mkdir -p "$REPO/.claude/skills/good" "$REPO/.claude/skills/bad"
printf -- '---\nname: good\ndescription: A good skill.\n---\n# good\n' > "$REPO/.claude/skills/good/SKILL.md"
printf '# bad\nno frontmatter\n' > "$REPO/.claude/skills/bad/SKILL.md"
printf '# Project\nUse /good for that.\n' > "$REPO/CLAUDE.md"
mkdir -p "$REPO/kit" "$REPO/missing"
printf '# Kit\nAsk `/guide` or `/review-panel` which skill fits.\n' > "$REPO/kit/CLAUDE.md"
printf '# Missing\nRun `/nosuchskill` first.\n' > "$REPO/missing/CLAUDE.md"
mkdir -p "$TMP/plain"   # not a git repository

# Rows: name | run dir | env (space separated) | args | want exit | output must contain
CASES=(
  "no arguments is a usage error|$REPO|||2|usage: validate-docs.sh"
  "an empty argument is a usage error|$REPO||\"\"|2|usage: validate-docs.sh"
  "a missing file is an error, not a pass|$REPO||nosuch.md|2|no such file: nosuch.md"
  "a passing file passes|$REPO||.claude/skills/good/SKILL.md|0|all CLAUDE.md and SKILL.md files pass"
  "a SKILL.md without frontmatter is a violation|$REPO||.claude/skills/bad/SKILL.md|1|DOC-004"
  "a reference to a kit skill (/guide) is not broken|$REPO||kit/CLAUDE.md|0|all CLAUDE.md and SKILL.md files pass"
  "a reference to a missing skill is a violation|$REPO||missing/CLAUDE.md|1|DOC-002"
  "--all scans the repo and finds the violation|$REPO||--all|1|DOC-004"
  "--all outside a git repository is refused|$TMP/plain|CLAUDE_PROJECT_DIR=|--all|2|needs a git repository"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name dir envs args want must <<<"$row"
  # shellcheck disable=SC2086
  out=$(cd "$dir" && eval "env $envs bash \"$SUT\" $args" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && printf '%s\n' "$out" | grep -qF -- "$must"; then ok "$name"
  else bad "$name (exit $rc, want $want; missing [$must]): $(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi
done

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
