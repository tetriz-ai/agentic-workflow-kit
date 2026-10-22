#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Replays the statusline capture with recorded statusline payloads from inside a worktree, then
# asks the usage guard, as /queue:ship-queue does between issues, whether to pause.
set -uo pipefail
DIR="$1"; KIT="$(cd "$(dirname "$0")/../.." && pwd)"; S="$KIT/plugins/queue/scripts"
MAIN="$DIR/main"; WT="$DIR/wt-issue-12"; SIGNAL="$MAIN/.claude/triage/usage.json"
unset CLAUDE_PROJECT_DIR
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
resets=$(( $(date +%s) + 3600 ))
statusline() { # statusline <used_percentage>: feeds a recorded payload to the wrapper from the worktree
  jq -nc --argjson p "$1" --argjson r "$resets" --arg wt "$WT" \
    '{model:{display_name:"Opus"},cwd:$wt,workspace:{current_dir:$wt},rate_limits:{five_hour:{used_percentage:$p,resets_at:$r}}}' \
    | (cd "$WT" && HOME="$DIR/home" bash "$S/statusline-capture.sh")
}
guard() { (cd "$WT" && bash "$S/usage-guard.sh" "$@"); }

out=$(guard should-pause)
case "$out" in "ok no-signal"*) ok "with no capture wired, the queue keeps going" ;; *) bad "no signal: [$out]" ;; esac

out=$(statusline 42)
if [ "$out" = "my-line Opus" ]; then ok "the wrapper still renders the user's own statusline"; else bad "personal line lost: [$out]"; fi
if [ -f "$SIGNAL" ] && [ ! -e "$WT/.claude/triage/usage.json" ] && [ "$(jq -r .pct "$SIGNAL")" = 42 ]; then
  ok "a capture from a worktree lands in the main checkout"
else bad "signal not in the main checkout"; fi
out=$(guard should-pause)
case "$out" in "ok pct=42%"*) ok "42% used: the queue starts the next issue" ;; *) bad "below threshold: [$out]" ;; esac

statusline 91 >/dev/null
out=$(guard should-pause)
if [ "$out" = "pause pct=91% >= 85% resets_at=$resets" ]; then ok "91% used: the queue pauses and names the reset"; else bad "over threshold: [$out]"; fi
if [ "$(guard resets-at)" = "$resets" ]; then ok "resets-at gives the epoch the resume cron is set for"; else bad "resets-at: [$(guard resets-at)]"; fi
case "$(guard should-pause 95)" in "ok pct=91%"*) ok "a higher threshold argument lets the run go on" ;; *) bad "threshold argument ignored" ;; esac

jq '.captured_at = 1' "$SIGNAL" > "$SIGNAL.tmp" && mv "$SIGNAL.tmp" "$SIGNAL"
case "$(guard should-pause)" in "ok stale"*) ok "a stale signal is not a pause" ;; *) bad "stale signal: [$(guard should-pause)]" ;; esac

# The personal statusLine re-enters the wrapper through a shim that counts its calls and stops at
# three, so a broken recursion guard fails this check instead of hanging the run.
cat > "$DIR/self-wrap.sh" <<EOF
n=\$((\$(cat "$DIR/depth" 2>/dev/null || echo 0) + 1)); echo "\$n" > "$DIR/depth"
[ "\$n" -le 3 ] || exit 0
exec bash "$S/statusline-capture.sh"
EOF
jq -n --arg c "bash $DIR/self-wrap.sh" '{statusLine:{type:"command",command:$c}}' > "$DIR/home/.claude/settings.json"
out=$(statusline 91)
if [ "$out" = "issue-12 · 5h:91%" ] && [ "$(cat "$DIR/depth")" = 1 ]; then
  ok "a personal statusLine that wraps the wrapper renders the worktree's own line once, no loop"
else bad "self-wrap: [$out], re-entered $(cat "$DIR/depth" 2>/dev/null) times"; fi
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
