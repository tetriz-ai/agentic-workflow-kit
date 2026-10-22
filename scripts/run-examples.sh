#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Runs every example: examples/<name>/setup.sh <dir> builds a fixture repo in a fresh temp dir,
# then examples/<name>/checks.sh <dir> replays the scenario's hook part (no model) and asserts on
# it. Exit 1 when any example's checks fail.
# Usage: scripts/run-examples.sh [example name...]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
if [ "$#" -eq 0 ]; then
  for d in examples/*/; do [ -f "$d/checks.sh" ] && set -- "$@" "$(basename "$d")"; done
fi
failed=0
for ex in "$@"; do
  dir="$(cd "$(mktemp -d)" && pwd -P)"
  if ! out="$(bash "examples/$ex/setup.sh" "$dir" 2>&1)"; then
    echo "FAIL $ex: setup.sh failed"; printf '%s\n' "$out" | tail -5 | sed 's/^/    /'; failed=$((failed + 1)); rm -rf "$dir"; continue
  fi
  if out="$(bash "examples/$ex/checks.sh" "$dir" 2>&1)"; then
    echo "ok   $ex: $(printf '%s\n' "$out" | tail -1)"
  else
    echo "FAIL $ex"; printf '%s\n' "$out" | grep -E 'FAIL' | sed 's/^/    /'; failed=$((failed + 1))
  fi
  rm -rf "$dir"
done
echo "$# example(s), $failed failed"
[ "$failed" -eq 0 ]
