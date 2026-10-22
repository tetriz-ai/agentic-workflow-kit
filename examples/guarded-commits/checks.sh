#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Replays the commit gate, the lockfile gate and the npx guard with recorded Bash payloads.
set -uo pipefail
DIR="$1"; KIT="$(cd "$(dirname "$0")/../.." && pwd)"; G="$KIT/plugins/guards/scripts"; REPO="$DIR/repo"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
hook() { # hook <script> <command> <cwd>: runs the hook; stderr in $DIR/err; prints the exit status
  jq -nc --arg c "$2" --arg cwd "$3" '{tool_input:{command:$c},cwd:$cwd}' \
    | (cd "$3" && PATH="$DIR/bin:$PATH" bash "$G/$1" >/dev/null 2>"$DIR/err"); echo $?
}

rc=$(hook commit-gate.sh "git commit -m 'paginate'" "$REPO")
[ "$rc" = 2 ] && grep -q '1 test failed' "$DIR/err" && ok "a failing commit_gate blocks the commit and shows why" || bad "commit gate (exit $rc: $(cat "$DIR/err"))"
rc=$(hook commit-gate.sh "git -C $REPO commit -m 'paginate'" "$DIR")
[ "$rc" = 2 ] && ok "git -C <repo> commit from elsewhere is gated in that repo" || bad "git -C commit (exit $rc)"
rc=$(hook commit-gate.sh "echo git commit next" "$REPO")
[ "$rc" = 0 ] && ok "an echo that mentions git commit runs no gate" || bad "echo gated (exit $rc)"
printf '#!/bin/sh\necho "all tests passed"\n' > "$REPO/test.sh"
rc=$(hook commit-gate.sh "git commit -m 'paginate'" "$REPO")
[ "$rc" = 0 ] && ok "once the tests pass, the commit goes through" || bad "passing gate (exit $rc)"

printf '{"name":"app","dependencies":{"left-pad":"1.3.0"}}\n' > "$REPO/package.json"; git -C "$REPO" add package.json
rc=$(hook lockfile-gate.sh "git commit -m 'add left-pad'" "$REPO")
[ "$rc" = 2 ] && grep -q 'Lockfile out of sync' "$DIR/err" && grep -q 'left-pad' "$REPO/package-lock.json" \
  && ok "a package.json change with a stale lockfile is blocked, and the refreshed lockfile is left to stage" || bad "lockfile gate (exit $rc: $(cat "$DIR/err"))"

rc=$(hook block-unpinned-npx.sh "npx -y create-widget" "$REPO")
[ "$rc" = 2 ] && ok "npx -y without a version is blocked" || bad "unpinned npx (exit $rc)"
rc=$(hook block-unpinned-npx.sh "FOO=1 npx -y create-widget" "$REPO")
[ "$rc" = 2 ] && ok "an environment prefix does not hide it" || bad "env-prefixed npx (exit $rc)"
rc=$(hook block-unpinned-npx.sh "npx -y create-widget@2.4.1" "$REPO")
[ "$rc" = 0 ] && ok "a pinned version is allowed" || bad "pinned npx (exit $rc)"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
