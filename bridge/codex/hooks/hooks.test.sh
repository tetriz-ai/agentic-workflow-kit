#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests the Codex post-bash, post-edit and subagent-start hooks against a stub kit
# (AGENTIC_KIT_HOME) whose scripts record each call:
#   post-bash      runs the PR-description drift check after a `git push` only, and merges its
#                  advisory into one PostToolUse envelope;
#   post-edit      runs the edit checks once per edited file, for an Edit payload and for each
#                  file of an apply_patch;
#   subagent-start anchors a subagent to its linked worktree, and is silent in a main checkout.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
for t in jq git python3; do command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 0; }; done

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
LOG="$TMP/calls"; export CALL_LOG="$LOG"
KIT="$TMP/kit"
for s in ship/check-pr-description-drift guards/post-edit-dispatcher guards/format-on-edit review/self-check; do
  f="$KIT/plugins/${s%%/*}/scripts/${s#*/}.sh"; mkdir -p "$(dirname "$f")"
  printf '#!/bin/bash\nin=$(cat)\nprintf "%%s %%s\\n" %s "$(printf "%%s" "$in" | jq -r ".tool_input.file_path // .tool_input.command // empty")" >> "$CALL_LOG"\nprintf "{\\"hookSpecificOutput\\":{\\"additionalContext\\":\\"note from %s\\"}}"\n' "${s#*/}" "${s#*/}" > "$f"
  chmod +x "$f"
done
MAIN="$TMP/main"; git init -q -b main "$MAIN"; git -C "$MAIN" commit -q --allow-empty -m base
WT="$TMP/wt"; git -C "$MAIN" worktree add -q -b feature "$WT"

# hook <name> <payload> [cwd]: runs a hook, prints its stdout; the calls go to $LOG.
hook() { : > "$LOG"; (cd "${3:-$MAIN}" && printf '%s' "$2" | AGENTIC_KIT_HOME="$KIT" bash "$HERE/$1.sh" 2>/dev/null); }
calls() { sort "$LOG" | tr '\n' ';'; }

# Rows: name | hook | payload | cwd (blank: main) | want calls (sorted, ;-joined) | output must contain
PATCH='*** Begin Patch
*** Add File: a.txt
+one
*** Update File: b.txt
@@
+two
*** End Patch'
CASES=(
  "a push runs the drift check|post-bash|$(jq -nc '{tool_input:{command:"git push -u origin feature"}}')||check-pr-description-drift git push -u origin feature;|\"hookEventName\":\"PostToolUse\""
  "a push's advisory is merged into one envelope|post-bash|$(jq -nc '{tool_input:{command:"git push"}}')||check-pr-description-drift git push;|note from check-pr-description-drift"
  "a command that is not a push runs nothing|post-bash|$(jq -nc '{tool_input:{command:"git status"}}')|||"
  "an Edit runs each edit check once|post-edit|$(jq -nc '{tool_name:"Edit",tool_input:{file_path:"a.go",new_string:"x"}}')||format-on-edit a.go;post-edit-dispatcher a.go;self-check a.go;|note from self-check"
  "an apply_patch runs the checks for each file|post-edit|$(jq -nc --arg p "$PATCH" '{tool_name:"apply_patch",tool_input:{command:$p}}')||format-on-edit a.txt;format-on-edit b.txt;post-edit-dispatcher a.txt;post-edit-dispatcher b.txt;self-check a.txt;self-check b.txt;|\"hookEventName\":\"PostToolUse\""
  "a subagent in a linked worktree is anchored to it|subagent-start|$(jq -nc --arg c "$WT" '{cwd:$c}')|||Operate on the linked worktree at: $WT"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name h payload cwd want must <<<"$row"
  out=$(hook "$h" "$payload" "$cwd")
  got=$(calls)
  if [ "$got" = "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then ok "$name"
  else bad "$name (calls [$got], want [$want]; output [$(printf '%s' "$out" | head -c 160)])"; fi
done

out=$(hook subagent-start "$(jq -nc --arg c "$MAIN" '{cwd:$c}')")
[ -z "$out" ] && ok "a subagent in the main checkout gets no anchor" || bad "main checkout anchor: [$out]"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
