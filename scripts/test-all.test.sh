#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for test-all.sh with planted suites. A suite that prints a line starting `SKIP:` did not
# run all of its rows, so the runner counts it, and with CI set the run fails: a CI machine that
# lacks a tool must not report green.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${TESTALL_SUT:-$HERE/test-all.sh}"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'echo "passed=1 failed=0"\n' > "$TMP/pass.test.sh"
printf 'echo "SKIP: jq not installed"\n' > "$TMP/skip.test.sh"
printf 'echo "PASS: a"\necho "SKIP: codex not installed; the execpolicy rows did not run"\necho "passed=1 failed=0"\n' > "$TMP/partial.test.sh"
printf 'echo "PASS: CODEX-LENS: SKIPPED when codex is missing"\necho "  a SKIP: inside a line"\necho "passed=1 failed=0"\n' > "$TMP/mention.test.sh"
printf 'echo "FAIL: a"\nexit 1\n' > "$TMP/fail.test.sh"

# Rows: name | CI value (- = unset) | planted suites | want exit | output must contain
CASES=(
  "a passing suite passes locally|-|pass|0|1 suite(s), 0 failed, 0 skipped"
  "a passing suite passes under CI|true|pass|0|1 suite(s), 0 failed, 0 skipped"
  "a skipped suite passes locally and is counted|-|skip|0|1 suite(s), 0 failed, 1 skipped"
  "a skipped suite names its reason|-|skip|0|    SKIP: jq not installed"
  "a skipped suite fails under CI|true|skip|1|CI is set"
  "a partly skipped suite fails under CI|true|partial pass|1|2 suite(s), 0 failed, 1 skipped"
  "a line that only mentions SKIP is not a skip|true|mention|0|1 suite(s), 0 failed, 0 skipped"
  "a failing suite fails locally|-|fail|1|1 suite(s), 1 failed, 0 skipped"
  "a failing and a skipped suite count apart|-|fail skip|1|2 suite(s), 1 failed, 1 skipped"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name ci suites want must <<<"$row"
  set --; for s in $suites; do set -- "$@" "$TMP/$s.test.sh"; done
  if [ "$ci" = - ]; then out="$(env -u CI bash "$SUT" "$@" 2>&1)"; rc=$?
  else out="$(CI="$ci" bash "$SUT" "$@" 2>&1)"; rc=$?; fi
  if [ "$rc" = "$want" ] && printf '%s\n' "$out" | grep -qF -- "$must"; then ok "$name"
  else bad "$name (exit $rc, want $want; missing [$must])"; printf '%s\n' "$out" | tail -4 | sed 's/^/    /'; fi
done

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
