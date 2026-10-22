#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for statusline-capture.sh with no personal statusline (a temp HOME), so it prints its
# fallback line. The line names the session's own branch, read from the directory the
# statusline input gives (a worktree when the session runs in one), and the usage file is
# always written to the main checkout's .claude/triage/usage.json.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/statusline-capture.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
MAIN="$TMP/main"; git init -q -b main "$MAIN"; git -C "$MAIN" commit -q --allow-empty -m base
WT="$TMP/wt"; git -C "$MAIN" worktree add -q -b feature "$WT"
USAGE="$MAIN/.claude/triage/usage.json"

# input <dir or ""> <pct>: a statusline payload; a blank dir leaves the directory out.
input() { jq -nc --arg d "$1" --argjson p "$2" '{rate_limits:{five_hour:{used_percentage:$p,resets_at:9}}} + (if $d == "" then {} else {cwd:$d, workspace:{current_dir:$d}} end)'; }

# Rows: name | process cwd | session dir in the input | pct | want line
CASES=(
  "a session in the main checkout shows main|$MAIN|$MAIN|40|main · 5h:40%"
  "a session in a worktree shows the worktree's branch|$MAIN|$WT|41|feature · 5h:41%"
  "a worktree session run from the worktree shows its branch|$WT|$WT|42|feature · 5h:42%"
  "no directory in the input falls back to the process cwd|$WT||43|feature · 5h:43%"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name cwd dir pct want <<<"$row"
  rm -f "$USAGE"
  got=$(cd "$cwd" && input "$dir" "$pct" | bash "$SUT")
  saved=$(jq -r '.pct' "$USAGE" 2>/dev/null)
  if [ "$got" = "$want" ] && [ "$saved" = "$pct" ] && [ ! -e "$WT/.claude/triage/usage.json" ]; then ok "$name"
  else bad "$name (line [$got], want [$want]; main usage pct [$saved]; worktree usage file $([ -e "$WT/.claude/triage/usage.json" ] && echo present || echo absent))"; fi
done

# An input without rate_limits keeps the last real signal.
printf '{"pct":92,"resets_at":9,"captured_at":1}' > "$USAGE"
got=$(cd "$MAIN" && printf '{"cwd":"%s"}' "$MAIN" | bash "$SUT")
if [ "$(jq -r .pct "$USAGE")" = 92 ] && [ "$got" = "main" ]; then ok "an input without rate_limits keeps the last real signal"
else bad "an input without rate_limits replaced the signal (pct [$(jq -r .pct "$USAGE")], line [$got])"; fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
