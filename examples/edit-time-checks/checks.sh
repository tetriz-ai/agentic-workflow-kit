#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Replays the guards plugin's PostToolUse edit hooks (the advisory dispatcher and format on edit)
# through hook-once.sh, the way hooks/hooks.json wires them, with recorded Edit payloads.
set -uo pipefail
DIR="$1"; KIT="$(cd "$(dirname "$0")/../.." && pwd)"; G="$KIT/plugins/guards/scripts"; REPO="$DIR/repo"
export TMPDIR="$DIR/tmp"   # hook-once.sh keeps its claims here, not in the machine's temp folder
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
edit() { # edit <script> <file> <tool_use_id> [env...]: delivers one Edit event; prints the hook's stdout
  local script="$1" file="$2" id="$3" from="${SESSION_DIR:-$REPO}"; shift 3
  jq -nc --arg f "$file" --arg id "$id" --arg cwd "$from" \
    '{session_id:"s1", tool_use_id:$id, hook_event_name:"PostToolUse", tool_name:"Edit", cwd:$cwd, tool_input:{file_path:$f}}' \
    | (cd "$from" && env "$@" "$G/hook-once.sh" "$script"); echo "rc=$?"
}
context() { printf '%s\n' "$1" | sed '$d' | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

out=$(edit post-edit-dispatcher.sh "$REPO/api/client.gen.go" t1)
case "$(context "$out")" in *"GENERATED FILE"*"api/client.gen.go"*"openapi-gen"*) ok "editing a generated file warns, naming the generator" ;; *) bad "no generated warning: [$out]" ;; esac
case "$out" in *rc=0) ok "the advisory hook still exits 0, so the edit stands" ;; *) bad "dispatcher exit: [$out]" ;; esac
ctx=$(context "$(edit post-edit-dispatcher.sh "$REPO/.claude/skills/release-notes/SKILL.md" t2)")
case "$ctx" in *DOC-004*"description:"*) ok "a SKILL.md without description: is flagged" ;; *) bad "no DOC-004: [$ctx]" ;; esac
ctx=$(context "$(edit post-edit-dispatcher.sh "$REPO/CLAUDE.md" t3)")
case "$ctx" in *"/deploy-staging"*) ok "a CLAUDE.md naming a missing skill is flagged" ;; *) bad "no DOC-002: [$ctx]" ;; esac
case "$ctx" in *release-notes*|*review-panel*) bad "a repo skill or kit skill was flagged: [$ctx]" ;; *) ok "a repo skill and a kit skill are not flagged" ;; esac

out=$(edit format-on-edit.sh "$REPO/src/pager.go" t4)
[ "$out" = "rc=0" ] && ! grep -q '[[:space:]]$' "$REPO/src/pager.go" \
  && ok "format_command from the settings file reformats the edited file, silently" || bad "pager.go not formatted: [$out]"
ctx=$(context "$(edit post-edit-dispatcher.sh "$REPO/src/pager.go" t4)")
[ -z "$ctx" ] && ok "an ordinary source file gets no advisory" || bad "pager.go advisory: [$ctx]"
edit format-on-edit.sh "$REPO/notes;touch pwned.txt" t5 >/dev/null
[ ! -e "$REPO/pwned.txt" ] && [ "$(cat "$REPO/notes;touch pwned.txt")" = todo ] \
  && ok "a file name holding shell syntax is passed as one argument, never run" || bad "file name was spliced into the command"
printf 'x   \n' > "$REPO/src/pager.go"
out=$(edit format-on-edit.sh "$REPO/src/pager.go" t6 AGENTIC_KIT_FORMAT_COMMAND='exit 3')
[ "$out" = "rc=0" ] && [ "$(cat "$REPO/src/pager.go")" = "x   " ] \
  && ok "an environment override wins over the settings file, and a failing formatter is absorbed" || bad "override or failure: [$out]"

printf 'x   \n' > "$REPO/src/pager.go"
out=$(SESSION_DIR="$DIR/elsewhere" edit format-on-edit.sh "$REPO/src/pager.go" t6b)
[ "$out" = "rc=0" ] && [ "$(cat "$REPO/src/pager.go")" = "x" ] \
  && ok "a session running outside the repo still uses the edited file's own format_command" || bad "format_command from another cwd: [$out] [$(cat "$REPO/src/pager.go")]"

before=$(wc -l < "$REPO/fmt.log")
for _ in 1 2; do edit format-on-edit.sh "$REPO/src/pager.go" t7 PLUGIN_ROOT="$KIT/plugins/guards" >/dev/null; done
[ $(( $(wc -l < "$REPO/fmt.log") - before )) -eq 1 ] && ok "one edit delivered twice on Codex formats once" || bad "double delivery formatted $(( $(wc -l < "$REPO/fmt.log") - before )) times"

out=$(edit format-on-edit.sh "$DIR/elsewhere/scratch.go" t8)$(context "$(edit post-edit-dispatcher.sh "$DIR/elsewhere/scratch.go" t8)")
[ "$out" = "rc=0" ] && [ "$(cat "$DIR/elsewhere/scratch.go")" = "scratch   " ] \
  && ok "an edit outside any repo is left alone" || bad "outside edit touched: [$out]"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
