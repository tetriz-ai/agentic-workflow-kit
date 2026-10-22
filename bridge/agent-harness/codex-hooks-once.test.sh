#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# With both the kit's Codex plugins and the bridge's .codex/hooks.json installed, Codex fires both
# for the same event. This test installs both into a temp repo and a temp kit, plays Codex's part
# (every hooks.json entry whose event and matcher fit is run with the same payload, plugin
# entries with PLUGIN_ROOT set as Codex sets it), and counts how often each kit script ran. The
# kit scripts are counting stubs; hook-once.sh, the hooks.json files and the bridge are the real
# ones from this tree. Each script must run once per event, in either order and when both sides
# start together, and a block from the side that ran must still block the call.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
for t in jq git python3; do command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 0; }; done

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" TMPDIR="$TMP/tmp"; mkdir -p "$HOME" "$TMPDIR"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
LOG="$TMP/count.log"; export COUNT_LOG="$LOG"

# The kit: the four plugins the bridge delegates to, with each hook script swapped for a stub.
KIT="$TMP/kit"; mkdir -p "$KIT/plugins"
for p in guards queue review ship; do cp -R "$SRC/plugins/$p" "$KIT/plugins/$p"; done
for s in guards/block-unpinned-npx guards/commit-gate guards/lockfile-gate guards/post-edit-dispatcher \
         guards/format-on-edit queue/session-start-dispatcher review/review-cadence review/self-check \
         ship/pr-nudge ship/check-pr-description-drift; do
  f="$KIT/plugins/${s%%/*}/scripts/${s#*/}.sh"
  printf '#!/bin/bash\ncat >/dev/null\necho %s >> "$COUNT_LOG"\n[ "${STUB_BLOCK:-}" = %s ] && { echo blocked >&2; exit 2; }\nexit 0\n' "${s#*/}" "${s#*/}" > "$f"
  chmod +x "$f"
done
# The repo: the bridge's Codex adapters, as sync-codex-harness.sh installs them.
REPO="$TMP/repo"; git init -q -b main "$REPO"; cp -R "$SRC/bridge/codex" "$REPO/.codex"

# hooks_for <hooks.json> <event> <tool>: the commands Codex would run, one per line.
hooks_for() {
  jq -r --arg e "$2" --arg t "$3" '.hooks[$e] // [] | .[]
    | select((.matcher // "") as $m | $m == "" or ($t | test("^(" + $m + ")$")))
    | .hooks[] | .command' "$1"
}
# fire <mode> <event> <tool> <payload> [env...]: run both installs' hooks for one event.
# mode: plugin-first | bridge-first | together | plugin-only | bridge-only. Prints
# "<count of each stub that ran, sorted> exit=<2 if any hook blocked, else 0>".
fire() {
  local mode="$1" ev="$2" tool="$3" payload="$4"; shift 4
  : > "$LOG"; rm -f "$TMP"/rc.*
  local side
  run_side() { # run_side plugin|bridge [env...]
    local which="$1" cmd p i=0; shift
    if [ "$which" = plugin ]; then
      for p in guards queue review ship; do
        while IFS= read -r cmd; do
          [ -n "$cmd" ] || continue; i=$((i + 1))
          (cd "$REPO" && printf '%s' "$payload" | env "$@" PLUGIN_ROOT="$KIT/plugins/$p" CLAUDE_PLUGIN_ROOT="$KIT/plugins/$p" bash -c "$cmd" >/dev/null 2>&1; echo $? > "$TMP/rc.plugin.$p.$i")
        done < <(hooks_for "$KIT/plugins/$p/hooks/hooks.json" "$ev" "$tool")
      done
    else
      while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue; i=$((i + 1))
        (cd "$REPO" && printf '%s' "$payload" | env "$@" AGENTIC_KIT_HOME="$KIT" bash -c "$cmd" >/dev/null 2>&1; echo $? > "$TMP/rc.bridge.$i")
      done < <(hooks_for "$REPO/.codex/hooks.json" "$ev" "$tool")
    fi
  }
  case "$mode" in
    plugin-first) run_side plugin "$@"; run_side bridge "$@" ;;
    bridge-first) run_side bridge "$@"; run_side plugin "$@" ;;
    together)     run_side plugin "$@" & run_side bridge "$@" & wait ;;
    plugin-only)  run_side plugin "$@" ;;
    bridge-only)  run_side bridge "$@" ;;
  esac
  local rc=0; for side in "$TMP"/rc.*; do [ -f "$side" ] && [ "$(cat "$side")" = 2 ] && rc=2; done
  printf '%s exit=%s' "$(sort "$LOG" | uniq -c | awk '{printf "%s=%s ", $2, $1}' | sed 's/ $//')" "$rc"
}

PRE_ALL='block-unpinned-npx=1 commit-gate=1 lockfile-gate=1 pr-nudge=1 review-cadence=1'
bash_call() { jq -nc --arg id "$1" --arg c "${2:-ls}" '{session_id:"s1",tool_use_id:$id,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:"."}'; }
# Rows: name | mode | event | tool | payload | env (space separated) | want
CASES=(
  "a command, plugin hooks first|plugin-first|PreToolUse|Bash|$(bash_call c1)||$PRE_ALL exit=0"
  "a command, bridge hooks first|bridge-first|PreToolUse|Bash|$(bash_call c2)||$PRE_ALL exit=0"
  "a command, both started together|together|PreToolUse|Bash|$(bash_call c3)||$PRE_ALL exit=0"
  "the next command runs every script again|plugin-first|PreToolUse|Bash|$(bash_call c4)||$PRE_ALL exit=0"
  "a block still blocks, plugin first|plugin-first|PreToolUse|Bash|$(bash_call c5)|STUB_BLOCK=commit-gate|block-unpinned-npx=1 commit-gate=1 lockfile-gate=1 pr-nudge=1 review-cadence=1 exit=2"
  "a block still blocks, bridge first|bridge-first|PreToolUse|Bash|$(bash_call c6)|STUB_BLOCK=commit-gate|$PRE_ALL exit=2"
  "after a push, the drift check runs once|together|PostToolUse|Bash|$(jq -nc '{session_id:"s1",tool_use_id:"p1",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"git push -u origin feat"}}')||check-pr-description-drift=1 exit=0"
  "an edit runs each edit hook once|together|PostToolUse|Edit|$(jq -nc '{session_id:"s1",tool_use_id:"e1",hook_event_name:"PostToolUse",tool_name:"Edit",tool_input:{file_path:"a.go",new_string:"x"}}')||format-on-edit=1 post-edit-dispatcher=1 self-check=1 exit=0"
  "a session start runs the queue dispatcher once|together|SessionStart|clear|$(jq -nc '{session_id:"s1",hook_event_name:"SessionStart",source:"clear"}')||session-start-dispatcher=1 exit=0"
  "the plugins alone run each script once|plugin-only|PreToolUse|Bash|$(bash_call c7)||$PRE_ALL exit=0"
  "the bridge alone runs each script once|bridge-only|PreToolUse|Bash|$(bash_call c8)||$PRE_ALL exit=0"
  "inherent: a payload with no call id runs twice, never zero times|plugin-first|PreToolUse|Bash|$(jq -nc '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"ls"}}')||block-unpinned-npx=2 commit-gate=2 lockfile-gate=2 pr-nudge=2 review-cadence=2 exit=0"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name mode ev tool payload envs want <<<"$row"
  # shellcheck disable=SC2086
  got=$(fire "$mode" "$ev" "$tool" "$payload" $envs)
  [ "$got" = "$want" ] && ok "$name" || bad "$name: got [$got], want [$want]"
done

# A later session start in the same session (a `date` stub moves the clock a minute on) runs again.
STUBS="$TMP/stubs"; mkdir -p "$STUBS"
printf '#!/bin/bash\necho 209901010000\n' > "$STUBS/date"; chmod +x "$STUBS/date"
got=$(fire together SessionStart clear "$(jq -nc '{session_id:"s1",hook_event_name:"SessionStart",source:"clear"}')" PATH="$STUBS:$PATH")
[ "$got" = "session-start-dispatcher=1 exit=0" ] && ok "a later session start in the same session runs again" || bad "a later session start: got [$got]"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
