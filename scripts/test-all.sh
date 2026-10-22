#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Runs every *.test.sh in the kit, one after another, and prints one line per suite. Tests that
# use git need a repository, so run from a clone. Exit 1 when any suite fails.
# A suite that cannot run some or all of its rows (a missing jq, git, yq, codex...) prints a line
# starting `SKIP:` and exits 0. Such a suite is counted as skipped. With CI set, a skip fails the
# run, so a CI machine that lacks a tool never reports green.
# Usage: scripts/test-all.sh [test path...]   (default: every *.test.sh under plugins, bridge,
#        shared and scripts)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
if [ "$#" -eq 0 ]; then
  while IFS= read -r t; do set -- "$@" "$t"; done < <(find plugins bridge shared scripts -name '*.test.sh' -type f | sort)
fi
echo "bash under test: $(bash --version | head -1)"
failed=0; skipped=0
for t in "$@"; do
  out="$(bash "$t" 2>&1)"; rc=$?
  printf '%-72s exit=%s  %s\n' "$t" "$rc" "$(printf '%s\n' "$out" | tail -1)"
  if [ "$rc" -ne 0 ]; then failed=$((failed + 1)); printf '%s\n' "$out" | grep -E '(^|[[:space:]])(FAIL|not ok|ERROR)' | head -20 | sed 's/^/    /'; fi
  skips="$(printf '%s\n' "$out" | grep '^SKIP:')"
  if [ -n "$skips" ]; then skipped=$((skipped + 1)); printf '%s\n' "$skips" | head -20 | sed 's/^/    /'; fi
done
echo "$# suite(s), $failed failed, $skipped skipped"
if [ -n "${CI:-}" ] && [ "$skipped" -gt 0 ]; then
  echo "CI is set, so a skipped suite fails the run: install the tool each SKIP line names"
  exit 1
fi
[ "$failed" -eq 0 ]
