#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for ship-queue-nudge.sh. Run: bash ship-queue-nudge.test.sh
#
# Builds a temp repo root with a STUB queue-view.sh (emits canned SQ / bug-hunt
# TSVs by LABEL) and a stub `gh` (for `gh api user`), then asserts the rendered
# nudge cache: the ship-queue table, the "Finish first" (in-flight) section, the
# "Needs your call" set difference (bug-hunt minus ship-queue), opt-out, and the
# silent-when-empty path. Deterministic - exits non-zero on any failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HANDLER="$HERE/ship-queue-nudge.sh"
pass=0
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ROOT="$TMP/root"
QV_DIR="$TMP/queue-view"
STAGE="$ROOT/.claude/triage/session-context"
CURRENT="$STAGE/ship-queue-nudge-current"
CACHE="$CURRENT/context.md"
DETAIL="$CURRENT/detail.md"
MSG="$CURRENT/message.msg"
mkdir -p "$QV_DIR"
export SHIP_QUEUE_NUDGE_QUEUE_VIEW="$QV_DIR/queue-view.sh" SHIP_QUEUE_NUDGE_REPO=acme/widgets

# --- stub queue-view.sh: emits a canned TSV chosen by $LABEL ---
cat > "$QV_DIR/queue-view.sh" <<'QV'
#!/bin/bash
printf 'number\tcreated\tpriority\tstatus\tassignees\topen_prs\ttitle\n'
if [ "${LABEL:-}" = "ship-queue" ]; then
  printf '101\t2026-01-16\tP1\tTodo\tme\t-\tFix A\n'
  printf '102\t2026-01-11\tP1\tIn Review\tme\t#120\tReconcile records\n'
  printf '103\t2026-01-11\tP1\tIn Progress\tme\t#121\tPaginate users\n'
  printf '104\t2026-01-10\tP2\tIn Progress\tme\t-\tStarted, no PR yet\n'
elif [ "${LABEL:-}" = "bug-hunt" ]; then
  printf '101\t2026-01-16\tP1\tTodo\tme\t-\tFix A\n'
  printf '105\t2026-01-05\tP1\tTodo\tme\t-\tDrop redundant fetch\n'
fi
QV
chmod +x "$QV_DIR/queue-view.sh"

# --- stub gh on PATH: `gh api user` -> $GH_LOGIN; `gh pr view <n>` -> a canned
#     readiness JSON per PR so pr_status() is exercised deterministically. ---
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GH'
#!/bin/bash
if [ "${1:-}" = "api" ] && [ "${2:-}" = "user" ]; then
  printf '%s\n' "${GH_LOGIN-me}"   # unset: me; set but empty: no login
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$3" in
    120) printf '{"isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN"}\n' ;;
    121) printf '{"isDraft":false,"reviewDecision":"CHANGES_REQUESTED","mergeStateStatus":"BLOCKED"}\n' ;;
    *)    printf '{"isDraft":false,"reviewDecision":null,"mergeStateStatus":"UNKNOWN"}\n' ;;
  esac
  exit 0
fi
exit 0
GH
chmod +x "$BIN/gh"

run() { CLAUDE_PROJECT_DIR="$ROOT" PATH="$BIN:$PATH" bash "$HANDLER" >/dev/null 2>&1; }

has()   { if grep -qF -- "$2" "$1" 2>/dev/null; then echo "PASS: $3"; pass=$((pass+1)); else echo "FAIL: $3 (missing [$2])"; fail=$((fail+1)); fi; }
hasnt() { if ! grep -qF -- "$2" "$1" 2>/dev/null; then echo "PASS: $3"; pass=$((pass+1)); else echo "FAIL: $3 (unexpected [$2])"; fail=$((fail+1)); fi; }
nofile(){ if [ ! -e "$1" ]; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: $2 (file exists)"; fail=$((fail+1)); fi; }
isfile(){ if [ -e "$1" ]; then echo "PASS: $2"; pass=$((pass+1)); else echo "FAIL: $2 (file missing)"; fail=$((fail+1)); fi; }

# ---- 1. Happy path writes compact ambient context and detailed on-demand data. ----
run
isfile "$CURRENT" "publishes one current snapshot"
first_snapshot="$(readlink "$CURRENT")"
isfile "$CACHE" "writes the nudge cache"
has "$CACHE" "4 ticket(s) assigned" "compact cache carries the queue count"
has "$CACHE" "Issue IDs: #101 #102 #103 #104" "compact cache carries only issue identifiers"
has "$CACHE" "ship-queue-nudge-current/detail.md" "compact cache points to its snapshot detail"
hasnt "$CACHE" "Fix A" "compact cache does not inject GitHub issue titles"
isfile "$DETAIL" "writes detailed on-demand queue data"
has "$DETAIL" "Your ship-queue (4)" "ship-queue count header"
has "$DETAIL" "oldest 2026-01-10, newest 2026-01-16" "freshness span (oldest/newest) in header"
has "$DETAIL" "[#101](https://github.com/acme/widgets/issues/101)" "issue link rendered"
has "$DETAIL" "| P1 | Todo |" "priority + status columns"
# Finish first: In Progress and open-PR rows, each with its PR's readiness.
has "$DETAIL" "Finish first" "finish-first section present"
has "$DETAIL" "pull/120" "open-PR row links the unmerged PR (#102 -> #120)"
# Two groups: 'Ready to merge' (you merge, leads with PR#) vs 'Advance toward
# merge' (/queue:ship-queue --continue, leads with ISSUE#). Number shown matches command.
has "$DETAIL" "gh pr merge <n> --squash --delete-branch" "ready group: human merge command (PR number)"
has "$DETAIL" "PR #120 (issue #102)" "ready entry leads with PR# (gh pr merge takes the PR)"
has "$DETAIL" "/queue:ship-queue --continue 103 104" "advance command PRE-FILLED with the real issue numbers"
has "$DETAIL" "1. issue #103 (PR #121)" "advance entry numbered + leads with ISSUE# (--continue takes the issue)"
has "$DETAIL" "issue #104" "in-progress-no-PR (#104) in the advance group"
hasnt "$DETAIL" "/queue:ship-queue --continue <pr" "never tells them to pass a PR number to --continue"
hasnt "$DETAIL" "[#101](https://github.com/acme/widgets/pull" "Todo row (#101) not in finish-first as a PR"
# Not-yet-queued: bug-hunt MINUS ship-queue == #105 only (NOT #101).
has "$DETAIL" "Not yet queued" "not-yet-queued section present (softened wording, not 'decide')"
has "$DETAIL" "[#105](https://github.com/acme/widgets/issues/105)" "#105 flagged (bug-hunt without ship-queue)"
# #101 has ship-queue, so it must NOT appear as a not-yet-queued 'review it' line.
if grep -q "review it:" "$DETAIL" && grep "review it:" "$DETAIL" | grep -q "#101"; then
  echo "FAIL: #101 wrongly in not-yet-queued (it has ship-queue)"; fail=$((fail+1))
else echo "PASS: #101 excluded from not-yet-queued (has ship-queue)"; pass=$((pass+1)); fi
has "$DETAIL" "/queue:ship-queue" "copy-paste command present"
# The VISIBLE line: a .msg the dispatcher emits as top-level systemMessage.
isfile "$MSG" "writes the visible .msg banner"
has "$MSG" "SHIP-QUEUE" "banner header present"
has "$MSG" "/queue:ship-queue" "banner carries the copy-paste command"
has "$MSG" "assigned to you" "banner names the assigned count"
has "$MSG" "in flight" "banner flags in-flight work to finish"

# ---- 1b. Large queues keep the ambient identifier list bounded. ----
cat > "$QV_DIR/queue-view.sh" <<'QV'
#!/bin/bash
printf 'number\tcreated\tpriority\tstatus\tassignees\topen_prs\ttitle\n'
if [ "${LABEL:-}" = "ship-queue" ]; then
  for n in $(seq 1 80); do printf '%s\t2026-01-16\tP2\tTodo\tme\t-\tDetailed item %s\n' "$n" "$n"; done
fi
QV
chmod +x "$QV_DIR/queue-view.sh"
run
if [ "$(readlink "$CURRENT")" != "$first_snapshot" ]; then echo "PASS: refresh switches to a new complete snapshot"; pass=$((pass+1)); else echo "FAIL: refresh rewrote the published snapshot in place"; fail=$((fail+1)); fi
latest_snapshot="$(readlink "$CURRENT")"
has "$CACHE" "#1 #2 #3" "large queue retains the first identifiers"
has "$CACHE" "... and 60 more" "large queue summarizes omitted identifiers"
has "$DETAIL" "Detailed item 80" "large queue retains complete detail on request"
if [ "$(wc -c < "$CACHE" | tr -d '[:space:]')" -le 8192 ]; then echo "PASS: large queue cache stays within ambient budget"; pass=$((pass+1)); else echo "FAIL: large queue cache exceeds ambient budget"; fail=$((fail+1)); fi

# ---- 1c. Old immutable snapshots are pruned after their safe retention window. ----
old_snapshot="$STAGE/.ship-queue-nudge.old"
mkdir -p "$old_snapshot"
touch -t 202001010000 "$old_snapshot"
run
nofile "$old_snapshot" "prunes expired immutable snapshots"

# ---- 2. Opt-out writes nothing AND clears a pre-existing stale cache. ----
rm -f "$CURRENT"
CLAUDE_PROJECT_DIR="$ROOT" PATH="$BIN:$PATH" SHIP_QUEUE_NUDGE_OPTOUT=1 bash "$HANDLER" >/dev/null 2>&1
nofile "$CACHE" "opt-out env writes no cache"
nofile "$DETAIL" "opt-out writes no detailed cache"
nofile "$MSG" "opt-out writes no .msg"
# A prior session's cache must be REMOVED on opt-out, else the dispatcher keeps
# surfacing it despite the opt-out. Republish the last snapshot as that stale cache.
ln -s "$latest_snapshot" "$CURRENT"
isfile "$CACHE" "a stale cache is published before the opt-out"
CLAUDE_PROJECT_DIR="$ROOT" PATH="$BIN:$PATH" SHIP_QUEUE_NUDGE_OPTOUT=1 bash "$HANDLER" >/dev/null 2>&1
nofile "$CACHE" "opt-out CLEARS a pre-existing stale cache"
nofile "$DETAIL" "opt-out CLEARS a pre-existing detailed cache"
nofile "$MSG" "opt-out CLEARS a pre-existing stale .msg"
isfile "$STAGE/$latest_snapshot/context.md" "opt-out retains a pinned snapshot for an in-flight dispatcher"

# ---- 3. Silent when empty + removes stale cache. ----
ln -s "$latest_snapshot" "$CURRENT"
cat > "$QV_DIR/queue-view.sh" <<'QV'
#!/bin/bash
printf 'number\tcreated\tpriority\tstatus\tassignees\topen_prs\ttitle\n'
QV
chmod +x "$QV_DIR/queue-view.sh"
run
nofile "$CACHE" "no tickets -> stale cache removed, stays silent"
nofile "$DETAIL" "no tickets -> stale detailed cache removed, stays silent"
nofile "$MSG" "no tickets -> stale .msg removed"

# ---- 4. Not authenticated (empty login) -> exit 0, no cache. The control run first shows the
#      same queue IS written when logged in, so a silent result is the login's doing. ----
cat > "$QV_DIR/queue-view.sh" <<'QV'
#!/bin/bash
printf 'number\tcreated\tpriority\tstatus\tassignees\topen_prs\ttitle\n'
[ "${LABEL:-}" = "ship-queue" ] && printf '101\t2026-01-16\tP1\tTodo\tme\t-\tFix A\n'
exit 0
QV
chmod +x "$QV_DIR/queue-view.sh"
run
has "$CACHE" "Issue IDs: #101" "control: logged in, the same queue is written"
rm -f "$CURRENT"
GH_LOGIN="" run
nofile "$CACHE" "unauthenticated gh -> silent, no cache"

# ---- 5. Failed/partial fetch (queue-view exits 3) preserves the cache. The control run first
#      shows a complete fetch DOES replace a planted cache. ----
run   # a published snapshot to plant the known-good cache in
printf 'KNOWN GOOD NUDGE\n' > "$CACHE"; printf 'KNOWN GOOD DETAIL\n' > "$DETAIL"; printf 'KNOWN GOOD MESSAGE\n' > "$MSG"
run
hasnt "$CACHE" "KNOWN GOOD NUDGE" "control: a complete fetch replaces the planted cache"
printf 'KNOWN GOOD NUDGE\n' > "$CACHE"; printf 'KNOWN GOOD DETAIL\n' > "$DETAIL"; printf 'KNOWN GOOD MESSAGE\n' > "$MSG"
cat > "$QV_DIR/queue-view.sh" <<'QV'
#!/bin/bash
printf 'number\tcreated\tpriority\tstatus\tassignees\topen_prs\ttitle\n'
printf '101\t2026-01-16\tP1\tTodo\tme\t-\tpartial row\n'
exit 3
QV
chmod +x "$QV_DIR/queue-view.sh"
run
if grep -qF "KNOWN GOOD NUDGE" "$CACHE" 2>/dev/null; then echo "PASS: partial fetch preserves last-known-good cache (fail closed)"; pass=$((pass+1)); else echo "FAIL: cache overwritten/deleted on a partial fetch"; fail=$((fail+1)); fi
if grep -qF "KNOWN GOOD DETAIL" "$DETAIL" 2>/dev/null; then echo "PASS: partial fetch preserves last-known-good detail (fail closed)"; pass=$((pass+1)); else echo "FAIL: detail overwritten/deleted on a partial fetch"; fail=$((fail+1)); fi
if grep -qF "KNOWN GOOD MESSAGE" "$MSG" 2>/dev/null; then echo "PASS: partial fetch preserves last-known-good message (fail closed)"; pass=$((pass+1)); else echo "FAIL: message overwritten/deleted on a partial fetch"; fail=$((fail+1)); fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
