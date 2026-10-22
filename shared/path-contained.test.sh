#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for path-contained.sh: a path inside the root is contained, through in-root links too,
# and a leaf, parent or dangling link that leads outside is not.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=path-contained.sh
. "$HERE/path-contained.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"; O="$TMP/outside"; mkdir -p "$R/real/sub" "$O"; : > "$O/file"
ln -s real "$R/inlink"
ln -s "$O" "$R/outdir"
ln -s "$O/file" "$R/outfile"
ln -s "$O/missing" "$R/dangling"
ln -s ../outside "$R/relout"
ln -s loop "$R/loop"

# Rows: name | path under the repo | want (0 contained, 1 not)
CASES=(
  "a plain file|real/sub/a.json|0"
  "a file that does not exist yet, in folders that do not either|new/deeper/a.json|0"
  "through a link that stays inside|inlink/sub/a.json|0"
  "a parent link to an outside folder|outdir/a.json|1"
  "a leaf link to an outside file|outfile|1"
  "a dangling link to an outside path|dangling|1"
  "a relative link that climbs out|relout/file|1"
  "a link loop|loop|1"
  "the parent of the root|../x|1"
  "a .. through folders that do not exist yet|new/../../outside/x|1"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name rel want <<< "$row"
  path_contained "$R" "$R/$rel" >/dev/null; rc=$?
  [ "$rc" = "$want" ] && ok "$name" || bad "$name (got $rc, want $want)"
done
real="$(path_contained "$R" "$R/outfile")"
[ "$real" = "$O/file" ] && ok "the resolved path is printed" || bad "resolved path [$real]"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
