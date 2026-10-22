#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for check-test-leaks.sh with planted tests. The leaky one records the exact temp dir it
# leaves, so this suite can check what the checker did with it and then remove only that dir.
# Where mktemp ignores TMPDIR, the leak lands in the shared system temp folder, which other
# processes also write to: the checker must report it, must not remove it, and must not count
# another process's entry there as the test's.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${LEAKCHECK_SUT:-$HERE/check-test-leaks.sh}"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"; [ -s "$TMP.mark" ] && rm -rf -- "$(cat "$TMP.mark")"; rm -f "$TMP.mark"' EXIT
MARK="$TMP.mark"; export MARK
printf 'd="$(mktemp -d)"; printf "%%s" "$d" > "$MARK"\n' > "$TMP/leaky.test.sh"
printf 'd="$(mktemp -d)"; rm -rf "$d"\n' > "$TMP/clean.test.sh"
# A clean test while another process makes its own tmp.XXXXXXXXXX in the shared temp folder (a
# mktemp outside the test's PATH and TMPDIR stands in for that process).
printf 'd="$(mktemp -d)"; o="$(env -u TMPDIR PATH=/usr/bin:/bin mktemp -d)"; printf "%%s" "$o" > "$MARK"; rm -rf "$d"\n' > "$TMP/busy.test.sh"
# Apple's tools write a cache named xcrun_db into TMPDIR when a test runs one of them, which is
# not the test's leftover. Planted directly, so the case runs on any machine.
printf 'mkdir -p "$TMPDIR/xcrun_db"; d="$(mktemp -d)"; rm -rf "$d"\n' > "$TMP/xcrun.test.sh"
printf 'mkdir -p "$TMPDIR/xcrun_db"; d="$(mktemp -d)"; printf "%%s" "$d" > "$MARK"\n' > "$TMP/xcrun-leaky.test.sh"
printf ': > "$TMPDIR/xcrun_db.cache"\n' > "$TMP/xcrun-near.test.sh"
# Does mktemp honour TMPDIR here? If not, the checker runs in its shared-folder mode.
probe="$(mktemp -d "$TMP/probe.XXXXXX")"
shared=1; [ "$(TMPDIR="$probe" bash -c 'dirname "$(mktemp -u)"')" = "$probe" ] && shared=0

# Rows: name | planted test | want exit | output must contain | leaked dir afterwards (kept, gone, -)
CASES=(
  "a clean test passes|clean.test.sh|0|no test leaves temp files behind|-"
  "a leaky test is reported|leaky.test.sh|1|LEAK: $TMP/leaky.test.sh left 1 entr|-"
  "another process's temp dir is not the test's leak|busy.test.sh|0|no test leaves temp files behind|-"
  "the xcrun_db platform cache is not a leak|xcrun.test.sh|0|no test leaves temp files behind|-"
  "a real leftover next to xcrun_db is still a leak|xcrun-leaky.test.sh|1|1 test(s) leak temp files|-"
)
if [ "$shared" = 1 ]; then
  CASES+=("a leak in the shared temp folder is not removed|leaky.test.sh|1|1 test(s) leak temp files|kept")
else
  CASES+=("a leak under the checker's own TMPDIR goes with it|leaky.test.sh|1|1 test(s) leak temp files|gone")
  # Only the exact top-level name is ignored; a look-alike in TMPDIR is reported.
  CASES+=("a file named like xcrun_db is still a leak|xcrun-near.test.sh|1|xcrun_db.cache|-")
fi
for row in "${CASES[@]}"; do
  IFS='|' read -r name t want must after <<<"$row"
  rm -f "$MARK"
  out="$(bash "$SUT" "$TMP/$t" 2>&1)"; rc=$?
  leaked=""; [ -s "$MARK" ] && leaked="$(cat "$MARK")"
  state=-
  if [ "$after" != - ]; then state=gone; [ -n "$leaked" ] && [ -e "$leaked" ] && state=kept; fi
  if [ "$rc" = "$want" ] && printf '%s\n' "$out" | grep -qF -- "$must" && [ "$state" = "$after" ]; then ok "$name"
  else bad "$name (exit $rc, want $want; leaked dir $state, want $after; missing [$must])"; printf '%s\n' "$out" | head -3 | sed 's/^/    /'; fi
  case "${leaked##*/}" in tmp.*) rm -rf -- "$leaked" ;; esac   # only the dir the planted test made
done

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
