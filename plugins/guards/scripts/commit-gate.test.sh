#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for commit-gate.sh. No dependencies beyond git and jq: the gate command is a
# stub script that records the directory it ran in and exits with a chosen status.
#
# The hook is a DENY gate: it resolves the repo where the commit actually runs, runs
# the commit_gate command there, and blocks (exit 2) when it fails. The worktree
# cases pin the attribution: an inline `cd <worktree> && git commit` is reported by
# the Bash tool with cwd = the MAIN checkout and must be gated in the worktree.
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/commit-gate.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1 (got [$2] want [$3])"; }

TMP=$(cd "$(mktemp -d)" && pwd -P)
MAIN="$TMP/main"; WT="$TMP/wt"
cleanup() { git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
git init -q "$MAIN"; git -C "$MAIN" config user.email test@example.com; git -C "$MAIN" config user.name t
git -C "$MAIN" commit -q --allow-empty -m base
git -C "$MAIN" worktree add -q "$WT" -b gate-wt-test >/dev/null 2>&1
git -C "$MAIN" config alias.ci commit; git -C "$MAIN" config alias.st status

RAN="$TMP/ran"
GATE_STUB="$TMP/gate.sh"
# The stub records its cwd; GATE_EXIT picks its status; it prints a line either way.
printf '#!/bin/sh\npwd -P > "%s"\necho "gate says: status ${GATE_EXIT:-0}"\nexit "${GATE_EXIT:-0}"\n' "$RAN" > "$GATE_STUB"
chmod +x "$GATE_STUB"

# fire <command> <cwd> <gate-exit> [gate-setting]: returns the hook's exit status.
fire() {
  local cmd="$1" cwd="$2" gexit="${3:-0}" gate="${4-$GATE_STUB}"
  : > "$RAN"
  jq -nc --arg c "$cmd" --arg d "$cwd" '{tool_input:{command:$c},cwd:$d}' \
    | GATE_EXIT="$gexit" CLAUDE_PLUGIN_OPTION_COMMIT_GATE="$gate" bash "$HOOK" >/dev/null 2>&1
}
ran_in() { [ -s "$RAN" ] && cat "$RAN" || echo none; }

echo "commit-gate.sh tests:"

# Rows: name | command | tool cwd | gate exit | want hook exit | want gate cwd
# ("none" = the gate never ran).
CASES=(
  "inline-cd worktree, passing gate|cd $WT && git commit -m x|$MAIN|0|0|$WT"
  "inline-cd worktree, failing gate blocks|cd $WT && git commit -m x|$MAIN|1|2|$WT"
  "plain commit resolves to tool cwd|git commit -m x|$WT|0|0|$WT"
  "multi-cd bails to the tool cwd|cd $WT && cd $TMP && git commit -m x|$MAIN|0|0|$MAIN"
  "cd -P form attributed to the worktree|cd -P $WT && git commit -m x|$MAIN|0|0|$WT"
  "cd -- form attributed to the worktree|cd -- $WT && git commit -m x|$MAIN|0|0|$WT"
  "non-commit command ignored|git status|$WT|1|0|none"
  "commit-graph is not a commit|git commit-graph write|$WT|1|0|none"
  "git -C worktree from the main cwd|git -C $WT commit -m x|$MAIN|1|2|$WT"
  "git -C relative to the tool cwd|git -C wt commit -m x|$TMP|1|2|$WT"
  "git -c option before commit|git -c user.name=x commit -m x|$WT|1|2|$WT"
  "env assignment before git|GIT_AUTHOR_NAME=x git commit -m x|$WT|1|2|$WT"
  "commit later in a chain|git add -A && git commit -m x|$WT|1|2|$WT"
  "commit through bash -c|bash -c 'git commit -m x'|$WT|1|2|$WT"
  "echo of git commit is not a commit|echo git commit is next|$WT|1|0|none"
  "quoted echo is not a commit|echo 'git commit -m x'|$WT|1|0|none"
  "git log naming commit is not a commit|git log --grep commit|$WT|1|0|none"
  "a subshell cd is followed|(cd $WT && git commit -m x)|$MAIN|1|2|$WT"
  "a group cd is followed|{ cd $WT; git commit -m x; }|$MAIN|1|2|$WT"
  "a backslash before git|\\git commit -m x|$WT|1|2|$WT"
  "timeout with a duration|timeout 60 git commit -m x|$WT|1|2|$WT"
  "timeout with a signal option|timeout -s KILL 5m git commit -m x|$WT|1|2|$WT"
  "xargs|xargs git commit -m x|$WT|1|2|$WT"
  "stdbuf|stdbuf -oL git commit -m x|$WT|1|2|$WT"
  "ionice|ionice -c 3 git commit -m x|$WT|1|2|$WT"
  "caffeinate|caffeinate -i git commit -m x|$WT|1|2|$WT"
  "doas|doas -u root git commit -m x|$WT|1|2|$WT"
  "nice with a level|nice -n 10 git commit -m x|$WT|1|2|$WT"
  "a git alias for commit|git ci -m x|$WT|1|2|$WT"
  "an alias for another command is not a commit|git st|$WT|1|0|none"
  "inherent: git named through a variable is not seen|G=git; \$G commit -m x|$WT|1|0|none"
  "inherent: a separator inside quotes reads as a commit|echo \"done; git commit next\"|$WT|1|2|$WT"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name cmd cwd gexit want_rc want_cwd <<<"$row"
  fire "$cmd" "$cwd" "$gexit"; rc=$?
  check "$name: exit" "$rc" "$want_rc"
  check "$name: gate ran in" "$(ran_in)" "$want_cwd"
done

# Codex carries the command's checkout as tool_input.workdir; it wins over the session cwd.
# Rows: name | workdir | session cwd | want hook exit | want gate cwd
WCASES=(
  "a Codex workdir is where the gate runs|$WT|$MAIN|2|$WT"
  "an empty workdir falls back to the cwd||$WT|2|$WT"
  "a relative workdir is joined onto the cwd|wt|$TMP|2|$WT"
)
for row in "${WCASES[@]}"; do
  IFS='|' read -r name wd cwd want_rc want_cwd <<<"$row"
  : > "$RAN"
  jq -nc --arg w "$wd" --arg d "$cwd" '{tool_input:{command:"git commit -m x",workdir:$w},cwd:$d}' \
    | GATE_EXIT=1 CLAUDE_PLUGIN_OPTION_COMMIT_GATE="$GATE_STUB" bash "$HOOK" >/dev/null 2>&1; rc=$?
  check "$name: exit" "$rc" "$want_rc"
  check "$name: gate ran in" "$(ran_in)" "$want_cwd"
done

# A repo settings file that does not parse blocks the commit with the reason (the gate setting
# could be in it), and kit-config says the file is invalid.
BROKEN="$TMP/broken"; git init -q "$BROKEN"; printf '{"commit_gate": "true",\n' > "$BROKEN/.agentic-workflow-kit.json"
err=$(jq -nc --arg d "$BROKEN" '{tool_input:{command:"git commit -m x"},cwd:$d}' | bash "$HOOK" 2>&1 >/dev/null); rc=$?
check "invalid settings file: blocked" "$rc" "2"
check "invalid settings file: reason" "$(printf '%s' "$err" | grep -c 'is not valid JSON')" "1"
check "kit-config reports the invalid file" "$( (cd "$BROKEN" && bash "$(dirname "$HOOK")/kit-config.sh" get commit_gate 2>&1 >/dev/null) | grep -c 'not valid JSON')" "1"

# A gate still running at commit_gate_timeout is stopped and the commit blocked, with the reason.
SECONDS=0
err=$(jq -nc --arg d "$WT" '{tool_input:{command:"git commit -m x"},cwd:$d}' \
  | CLAUDE_PLUGIN_OPTION_COMMIT_GATE="sleep 30" CLAUDE_PLUGIN_OPTION_COMMIT_GATE_TIMEOUT=1 bash "$HOOK" 2>&1 >/dev/null); rc=$?
check "slow gate: blocked" "$rc" "2"
check "slow gate: reason names the deadline" "$(printf '%s' "$err" | grep -c 'timed out after 1s; speed up the check, or raise commit_gate_timeout up to 570')" "1"

# A commit_gate_timeout that is not a whole number of seconds, or is above 570, is fixed up with
# a warning, and the gate still runs.
# Rows: name | commit_gate_timeout | want text in stderr
TCASES=(
  "a word: warned, the gate still runs|abc|not a whole number of seconds; using 570"
  "above 570: clamped with a warning|9999|is above 570"
)
for row in "${TCASES[@]}"; do
  IFS='|' read -r name value want <<<"$row"
  err=$(jq -nc --arg d "$WT" '{tool_input:{command:"git commit -m x"},cwd:$d}' \
    | CLAUDE_PLUGIN_OPTION_COMMIT_GATE="true" CLAUDE_PLUGIN_OPTION_COMMIT_GATE_TIMEOUT="$value" bash "$HOOK" 2>&1 >/dev/null); rc=$?
  check "$name: exit" "$rc" "0"
  check "$name: warning" "$(printf '%s' "$err" | grep -c "$want")" "1"
done
check "slow gate: stopped well before the hook timeout" "$([ "$SECONDS" -lt 10 ] && echo yes || echo no)" "yes"

# A blank setting turns the gate off: the commit passes and nothing runs.
fire "git commit -m x" "$WT" 1 ""; rc=$?
check "blank commit_gate: allowed" "$rc" "0"
check "blank commit_gate: nothing ran" "$(ran_in)" "none"

# A failing gate shows its output tail on stderr with the block.
err=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$WT" \
  | GATE_EXIT=3 CLAUDE_PLUGIN_OPTION_COMMIT_GATE="$GATE_STUB" bash "$HOOK" 2>&1 >/dev/null)
check "failing gate: output shown" "$(printf '%s' "$err" | grep -c 'gate says: status 3')" "1"

# Fail closed on a missing shared lib: a commit is BLOCKED (exit 2), not let through
# unresolved; the guard sits after the fast path, so a non-commit is still ignored.
HOOKDIR=$(mktemp -d); cp "$HOOK" "$HOOKDIR/h.sh"
printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$WT" | bash "$HOOKDIR/h.sh" >/dev/null 2>&1; rc=$?
check "missing lib: commit blocked (fail-closed)" "$rc" "2"
printf '{"tool_input":{"command":"git status"},"cwd":"%s"}' "$WT" | bash "$HOOKDIR/h.sh" >/dev/null 2>&1; rc=$?
check "missing lib: non-commit still ignored" "$rc" "0"
rm -rf "$HOOKDIR"

# No jq on PATH: a commit is BLOCKED with a reason (a DENY gate must not fail open
# with exit 127, which Claude Code treats as a non-blocking error); a command that
# is not a commit still passes.
NOJQ="$TMP/nojq-bin"; mkdir -p "$NOJQ"
for t in bash sh git cat sed tr grep dirname basename tail head mktemp rm env pwd; do
  p=$(command -v "$t" 2>/dev/null) && [ -n "$p" ] && ln -sf "$p" "$NOJQ/$t"
done
BASH_BIN=$(command -v bash)
for row in "git commit -m x|2" "git status|0"; do
  IFS='|' read -r cmd want <<<"$row"
  : > "$RAN"
  err=$(printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$cmd" "$WT" \
    | PATH="$NOJQ" CLAUDE_PLUGIN_OPTION_COMMIT_GATE="$GATE_STUB" "$BASH_BIN" "$HOOK" 2>&1 >/dev/null); rc=$?
  check "no jq: $cmd exit" "$rc" "$want"
  [ "$want" = 2 ] && check "no jq: reason names jq" "$(printf '%s' "$err" | grep -q 'jq' && echo yes)" "yes"
done

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
