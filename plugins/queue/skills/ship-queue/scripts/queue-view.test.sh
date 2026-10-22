#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for queue-view.sh. Run: bash queue-view.test.sh
#
# Stubs `gh` on PATH to assert the shell plumbing (header row, 7-column order, the
# per-row number prepend, assignee/author/window arg construction, the empty-result
# path) and, through the stub's jq emulation below, the real --jq filter queue-view
# passes to `gh api graphql`.
# Deterministic - exits non-zero on any failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/queue-view.sh"
pass=0
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Stub gh on PATH. Logs its argv to $GH_ARGS_LOG (one invocation per line) so
# the test can assert how queue-view.sh called it. `gh issue list` prints the
# numbers in $GH_NUMS. `gh api graphql` is a FAITHFUL emulator: it extracts the
# `--jq` program queue-view passed on argv and applies the REAL jq to a canned
# GraphQL payload — so the load-bearing jq filter (Priority/Status extraction,
# OPEN-only PR filtering, title sanitization, 7-column order) is exercised for
# real, not bypassed. The canned title carries a pipe + literal tab, and the
# payload has one OPEN and one MERGED PR, so filtering + sanitization are tested. ---
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/bin/bash
echo "ARGV: $*" >> "$GH_ARGS_LOG"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  printf '%s\n' ${GH_NUMS:-}
  exit 0
fi
if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
  jqprog=""; num=""; prev=""
  for a in "$@"; do
    [ "$prev" = "--jq" ] && jqprog="$a"
    case "$a" in num=*) num="${a#num=}";; esac
    prev="$a"
  done
  [ "$num" = "9999" ] && exit 1   # simulate a per-issue GraphQL failure (rate-limit/timeout)
  title="Title for ${num}"
  [ "$num" = "7777" ] && title=$'Bad | title\twith tab'   # nasty title for sanitization
  # Canned payload exercises the REAL jq: project #5 gives P1/Todo, project #99
  # gives P0/Done (must be IGNORED by the project filter); connected has an OPEN
  # PR #122 and closedBy has a MERGED #123 (must be filtered — state!=OPEN).
  jq -n --arg t "$title" '{data:{repository:{issue:{
    title:$t, createdAt:"2026-01-08T10:00:00Z",
    assignees:{nodes:[{login:"octocat"}]},
    projectItems:{nodes:[
      {project:{number:5},  fieldValues:{nodes:[
        {name:"P1",field:{name:"Priority"}}, {name:"Todo",field:{name:"Status"}} ]}},
      {project:{number:99}, fieldValues:{nodes:[
        {name:"P0",field:{name:"Priority"}}, {name:"Done",field:{name:"Status"}} ]}}
    ]},
    connected:{nodes:[{subject:{number:122,state:"OPEN"}}]},
    closedBy:{nodes:[{number:123,state:"MERGED"}]}
  }}}}' | jq -r "$jqprog"
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/gh"

export GH_ARGS_LOG="$TMP/gh_args.log"

run() { REPO="${REPO:-acme/widgets}" PROJECT_NUMBER="${PROJECT_NUMBER:-5}" PATH="$BIN:$PATH" bash "$SCRIPT"; }

ok()   { if [ "$1" = "$2" ]; then echo "PASS: $3"; pass=$((pass+1)); else echo "FAIL: $3 (got [$1] want [$2])"; fail=$((fail+1)); fi; }
has()  { if grep -q -- "$2" "$1" 2>/dev/null; then echo "PASS: $3"; pass=$((pass+1)); else echo "FAIL: $3 (pattern [$2] not in $1)"; fail=$((fail+1)); fi; }
hasnt(){ if ! grep -q -- "$2" "$1" 2>/dev/null; then echo "PASS: $3"; pass=$((pass+1)); else echo "FAIL: $3 (pattern [$2] unexpectedly in $1)"; fail=$((fail+1)); fi; }

# ---- 1. Two issues: header + 2 rows, correct column order + number prepend. ----
: > "$GH_ARGS_LOG"
out="$(GH_NUMS='101 6002' run)"
hdr="$(printf '%s\n' "$out" | head -1)"
ok "$hdr" "number	created	priority	status	assignees	open_prs	title" "header row is the 7 columns in order"

row1="$(printf '%s\n' "$out" | sed -n '2p')"
ok "$(printf '%s' "$row1" | cut -f1)" "101" "row1 first column is the issue number (prepend works)"
ok "$(printf '%s' "$row1" | awk -F'\t' '{print NF}')" "7" "row1 has 7 tab-separated columns"
ok "$(printf '%s' "$row1" | cut -f3)" "P1" "row1 priority column"
ok "$(printf '%s' "$row1" | cut -f6)" "#122" "row1 open_prs column"
ok "$(printf '%s\n' "$out" | grep -c 'Title for')" "2" "two data rows rendered"

# ---- 2. Default scope is assignee=@me, no created window. ----
listline="$(grep 'ARGV: issue list' "$GH_ARGS_LOG" | head -1)"
echo "$listline" > "$TMP/listline"
has "$TMP/listline" -- "--assignee @me" "defaults to --assignee @me (owner-scoped, not author)"
hasnt "$TMP/listline" "created:>=" "DAYS=0 default -> no created window"
has "$TMP/listline" -- "sort:created-desc" "sorts newest-first"

# ---- 3. DAYS=N adds a created window. ----
: > "$GH_ARGS_LOG"
GH_NUMS='101' DAYS=5 run >/dev/null
grep 'ARGV: issue list' "$GH_ARGS_LOG" | head -1 > "$TMP/listline2"
has "$TMP/listline2" "created:>=" "DAYS=5 -> created:>= window present"

# ---- 4. AUTHOR set adds --author. ----
: > "$GH_ARGS_LOG"
GH_NUMS='101' AUTHOR=janedoe run >/dev/null
grep 'ARGV: issue list' "$GH_ARGS_LOG" | head -1 > "$TMP/listline3"
has "$TMP/listline3" -- "--author janedoe" "AUTHOR env adds --author scope"

# ---- 4b. Empty ASSIGNEE -> all assignees (no --assignee flag), per the header. ----
: > "$GH_ARGS_LOG"
GH_NUMS='101' ASSIGNEE='' run >/dev/null
grep 'ARGV: issue list' "$GH_ARGS_LOG" | head -1 > "$TMP/listline_all"
hasnt "$TMP/listline_all" "--assignee" "empty ASSIGNEE -> no --assignee flag (all assignees)"

# ---- 5. LABEL override is threaded. ----
: > "$GH_ARGS_LOG"
GH_NUMS='101' LABEL=bug-hunt run >/dev/null
grep 'ARGV: issue list' "$GH_ARGS_LOG" | head -1 > "$TMP/listline4"
has "$TMP/listline4" -- "--label bug-hunt" "LABEL env is threaded to gh issue list"

# ---- 5b. Golden jq: the REAL --jq filter over a canned payload (contract guard). ----
: > "$GH_ARGS_LOG"
out="$(GH_NUMS='7777' run)"
grow="$(printf '%s\n' "$out" | sed -n '2p')"
ok "$(printf '%s' "$grow" | awk -F'\t' '{print NF}')" "7" "tab in title stripped -> row stays 7 columns"
ok "$(printf '%s' "$grow" | cut -f3)" "P1" "Priority extracted from projectItems.fieldValues"
ok "$(printf '%s' "$grow" | cut -f4)" "Todo" "Status extracted from projectItems.fieldValues"
if printf '%s' "$grow" | grep -qE 'P0|Done'; then echo "FAIL: a field from another project (#99) leaked in"; fail=$((fail+1)); else echo "PASS: only the PROJECT_NUMBER board's Priority/Status is used (#99 ignored)"; pass=$((pass+1)); fi
ok "$(printf '%s' "$grow" | cut -f6)" "#122" "open_prs keeps only the OPEN, genuinely-linked PR"
if printf '%s' "$grow" | grep -q '#123'; then echo "FAIL: MERGED PR #123 not filtered"; fail=$((fail+1)); else echo "PASS: MERGED PR filtered out of open_prs"; pass=$((pass+1)); fi
gtitle="$(printf '%s' "$grow" | cut -f7)"
case "$gtitle" in *'|'*) echo "FAIL: pipe not stripped from title"; fail=$((fail+1));; *) echo "PASS: pipe stripped from title"; pass=$((pass+1));; esac

# ---- 5c. A dropped per-issue fetch -> exit 3 (partial), not a clean empty. ----
out="$(GH_NUMS='101 9999' run)"; rc=$?
ok "$rc" "3" "a per-issue failure makes queue-view exit 3 (partial, not clean)"
ok "$(printf '%s\n' "$out" | grep -c 'Title for 101')" "1" "the surviving row is still emitted on a partial run"

# ---- 6. No issues -> header only, exit 0. ----
: > "$GH_ARGS_LOG"
out="$(GH_NUMS='' run)"; rc=$?
ok "$rc" "0" "empty result exits 0"
ok "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" "empty result prints header only"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
