#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests SKILL.md Step 0 as written: the first bash block under "### Step 0" is extracted from
# SKILL.md and run against a fixture (origin is a bare repo in a temp dir; no network).
#
# Step 0 re-creates the throwaway worktree for a run. It must never destroy a prior run's
# work that was not pushed: an uncommitted artifact, or committed but unpushed commits on
# taste/<handle>, make the step stop with the work in place. A clean, pushed prior worktree
# is replaced.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$HERE/SKILL.md"
PLUGIN_ROOT="$(cd "$HERE/../.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export HOME="$TMP/home"; mkdir -p "$HOME"

# The Step 0 block, with the worktree root pointed into the fixture (the handle is set per row).
BLOCK=$(awk '/^### Step 0/{s=1} s&&/^  ```bash/{b=1; next} b&&/^  ```/{exit} b' "$SKILL" \
  | sed -e 's/^  //' -e "s#/tmp/extract-taste-#$TMP/extract-taste-#g")
[ -n "$BLOCK" ] || { echo "FAIL: no Step 0 bash block found in SKILL.md"; exit 1; }

ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN"; git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
SEED="$TMP/seed"; git clone -q "$ORIGIN" "$SEED" 2>/dev/null
git -C "$SEED" checkout -q -b main; echo base > "$SEED/README.md"; git -C "$SEED" add README.md
git -C "$SEED" commit -qm base; git -C "$SEED" push -q origin main 2>/dev/null

run_step0() { # run_step0 <repo> <handle>: prints the block's exit status
  (cd "$1" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PLUGIN_OPTION_BASE_BRANCH=main bash -c "${BLOCK//<handle>/$2}" >/dev/null 2>"$TMP/err")
  printf '%s' "$?"
}

# Rows: name | prior state (none|uncommitted|unpushed|pushed) | want exit (0 or nonzero) |
#       want the prior artifact afterwards (kept|gone|n/a)
CASES=(
  "no prior worktree: the worktree is created|none|0|n/a"
  "an uncommitted prior artifact stops the step and survives|uncommitted|nonzero|kept"
  "a committed but unpushed prior artifact stops the step and survives|unpushed|nonzero|kept"
  "a clean, pushed prior worktree is replaced|pushed|0|gone"
)
n=0
for row in "${CASES[@]}"; do
  n=$((n + 1))
  IFS='|' read -r name prior want_rc want_art <<<"$row"
  R="$TMP/repo$n"; git clone -q "$ORIGIN" "$R" 2>/dev/null
  h="h$n"; WT="$TMP/extract-taste-$h"; ART="$WT/docs/taste-collection/$h.md"
  if [ "$prior" != none ]; then
    git -C "$R" worktree add -q -B "taste/$h" "$WT" origin/main 2>/dev/null
    mkdir -p "$WT/docs/taste-collection"; echo "prior run $n" > "$ART"
    case "$prior" in
      unpushed) git -C "$WT" add -A; git -C "$WT" commit -qm prior ;;
      pushed)   git -C "$WT" add -A; git -C "$WT" commit -qm prior; git -C "$WT" push -q -u origin "taste/$h" 2>/dev/null ;;
    esac
  fi
  rc=$(run_step0 "$R" "$h")
  verdict=yes
  if [ "$want_rc" = 0 ]; then [ "$rc" = 0 ] || verdict="no (exit $rc: $(head -2 "$TMP/err" | tr '\n' ' '))"
  else [ "$rc" != 0 ] || verdict="no (exit 0, want a stop)"; fi
  case "$want_art" in
    kept) [ "$(cat "$ART" 2>/dev/null)" = "prior run $n" ] || verdict="no (prior artifact lost)" ;;
    gone) [ ! -e "$ART" ] || verdict="no (prior artifact still there)" ;;
  esac
  [ "$want_rc" = 0 ] && { [ -d "$WT" ] && [ "$(git -C "$WT" branch --show-current)" = "taste/$h" ] || verdict="no (no fresh worktree on taste/$h)"; }
  [ "$verdict" = yes ] && ok "$name" || bad "$name: $verdict"
done

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
