#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for gh-issue.sh — runs with a STUBBED `gh` on PATH (no network). Covers
# the one-shot create+triage flow: live field/option resolution, the field-metadata
# cache running ONCE per call (not once per subshell), current-version
# auto-resolution with recency tie-break, the version fallback setting, the P1
# default, explicit overrides, version validation before create, partial-failure
# WARN + non-zero exit, input guards, the no-board mode, and help. Deterministic.

set -uo pipefail
# Every temp path this test creates goes under one directory, removed on exit (a local
# mktemp, since some mktemp builds ignore TMPDIR).
TEST_TMP="$(command mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mktemp() {
  case "${1:-}" in
    -d) command mktemp -d "$TEST_TMP/t.XXXXXX" ;;
    -u) command mktemp -u "$TEST_TMP/t.XXXXXX" ;;
    *)  command mktemp "$TEST_TMP/t.XXXXXX" ;;
  esac
}
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/gh-issue.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   — %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL — %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; }

STUB=$(mktemp -d)
export EDIT_LOG="$STUB/edits.log"; : > "$EDIT_LOG"
export FIELDS_CALLS="$STUB/fields_calls"; : > "$FIELDS_CALLS"
export GH_ISSUE_REPO=acme/widgets GH_ISSUE_PROJECT=acme/5

# Stub `gh`. Env toggles let one stub drive every case:
#   EDIT_FAIL=1     -> item-edit exits non-zero (partial-failure path)
#   VER_MODE=none   -> recent issues carry no version (the fallback path)
#   VER_MODE=fallback -> recent issues carry only the fallback option (Unversioned)
#   VER_MODE=tie    -> equal-count tie, most-recent carries the lexically-SMALLER version
#   VER_MODE=fail   -> the current-version query fails
#   FIELDS_MODE=bare -> the board has only a Status field
#   ADD_FAIL=1      -> project item-add fails with a message on stderr
#   ITEM_MISSING=1  -> the issue has no item on the project
cat > "$STUB/gh" <<'STUB_EOF'
#!/bin/bash
case "$1 $2" in
  "issue create")     echo "https://${STUB_HOST:-github.com}/acme/widgets/issues/130"; exit 0 ;;
  "project item-add") [ -n "${ADD_FAIL:-}" ] && { echo "boom: project not writable" >&2; exit 1; }; exit 0 ;;
  "project item-edit") echo "ITEM-EDIT: $*" >> "$EDIT_LOG"; [ -n "${EDIT_FAIL:-}" ] && exit 1; exit 0 ;;
esac
q=""
for a in "$@"; do [[ "$a" == query=* ]] && q="${a#query=}"; done
if [[ "$q" == *"fields(first:50)"* ]]; then
  echo x >> "$FIELDS_CALLS"    # count how many times the field-metadata query runs
  # FIELDS_MODE=bare: a board with only a Status field (no Priority, Version or Estimate).
  if [ "${FIELDS_MODE:-}" = bare ]; then
    echo '{"data":{"repositoryOwner":{"projectV2":{"id":"PVT_TEST","fields":{"nodes":[{"__typename":"ProjectV2SingleSelectField","id":"F_STATUS","name":"Status","options":[{"id":"opt_todo","name":"Todo"}]}]}}}}}'
    exit 0
  fi
  cat <<'JSON'
{"data":{"repositoryOwner":{"projectV2":{"id":"PVT_TEST","fields":{"nodes":[
  {"__typename":"ProjectV2SingleSelectField","id":"F_STATUS","name":"Status","options":[{"id":"opt_todo","name":"Todo"},{"id":"opt_inreview","name":"In Review"}]},
  {"__typename":"ProjectV2SingleSelectField","id":"F_PRIO","name":"Priority","options":[{"id":"opt_p0","name":"P0"},{"id":"opt_p1","name":"P1"},{"id":"opt_p2","name":"P2"},{"id":"opt_parked","name":"Parked"}]},
  {"__typename":"ProjectV2SingleSelectField","id":"F_VER","name":"Version","options":[{"id":"opt_v22","name":"v2.2"},{"id":"opt_v23","name":"v2.3"},{"id":"opt_unv","name":"Unversioned"}]},
  {"__typename":"ProjectV2Field","id":"F_EST","name":"Estimate"}
]}}}}}
JSON
  exit 0
fi
# The version query orders by CREATED_AT DESC, so nodes are most-recent-first.
if [[ "$q" == *"issues(first:20"* ]]; then
  [ "${VER_MODE:-}" = "fail" ] && exit 1    # simulate a transient GraphQL failure
  if [ "${VER_MODE:-}" = "none" ]; then
    echo '{"data":{"repository":{"issues":{"nodes":[{"projectItems":{"nodes":[{"project":{"number":5},"fieldValueByName":null}]}},{"projectItems":{"nodes":[]}}]}}}}'
    exit 0
  fi
  if [ "${VER_MODE:-}" = "fallback" ]; then
    echo '{"data":{"repository":{"issues":{"nodes":[{"projectItems":{"nodes":[{"project":{"number":5},"fieldValueByName":{"name":"Unversioned"}}]}},{"projectItems":{"nodes":[{"project":{"number":5},"fieldValueByName":{"name":"Unversioned"}}]}}]}}}}'
    exit 0
  fi
  if [ "${VER_MODE:-}" = "tie" ]; then
    # 2 x v2.2 (most recent) vs 2 x v2.3 (older) — recency must pick v2.2, lexical would pick v2.3.
    echo '{"data":{"repository":{"issues":{"nodes":[{"projectItems":{"nodes":[{"project":{"number":5},"fieldValueByName":{"name":"v2.2"}}]}},{"projectItems":{"nodes":[{"project":{"number":5},"fieldValueByName":{"name":"v2.2"}}]}},{"projectItems":{"nodes":[{"project":{"number":5},"fieldValueByName":{"name":"v2.3"}}]}},{"projectItems":{"nodes":[{"project":{"number":5},"fieldValueByName":{"name":"v2.3"}}]}}]}}}}'
    exit 0
  fi
  # default: clear mode v2.3 (2) over v2.2 (1), plus an issue with no item + an Unversioned one
  echo '{"data":{"repository":{"issues":{"nodes":[{"projectItems":{"nodes":[{"project":{"number":5},"fieldValueByName":{"name":"v2.3"}}]}},{"projectItems":{"nodes":[{"project":{"number":5},"fieldValueByName":{"name":"v2.3"}}]}},{"projectItems":{"nodes":[{"project":{"number":5},"fieldValueByName":{"name":"v2.2"}}]}},{"projectItems":{"nodes":[]}},{"projectItems":{"nodes":[{"project":{"number":5},"fieldValueByName":{"name":"Unversioned"}}]}}]}}}}'
  exit 0
fi
if [[ "$q" == *"issue(number"* ]]; then
  [ -n "${ITEM_MISSING:-}" ] && { echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}'; exit 0; }
  echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"ITEM_123","project":{"number":5}}]}}}}}'
  exit 0
fi
exit 0
STUB_EOF
chmod +x "$STUB/gh"
export PATH="$STUB:$PATH"

# --- version resolution ---------------------------------------------------
OUT=$("$SUT" version 2>&1)
grep -q 'current version: v2.3' <<<"$OUT" && ok "version -> mode of recent issues (v2.3)" || bad "version resolution" "$OUT"

OUT=$(VER_MODE=tie "$SUT" version 2>&1)
grep -q 'current version: v2.2' <<<"$OUT" && ok "version tie -> recency wins (v2.2), not lexical (v2.3)" || bad "recency tie-break" "$OUT"

OUT=$(VER_MODE=none "$SUT" version 2>&1)
grep -q 'unresolved' <<<"$OUT" && ok "version none -> unresolved message" || bad "version none" "$OUT"

# --- create with defaults + cache runs ONCE -------------------------------
: > "$EDIT_LOG"; : > "$FIELDS_CALLS"
OUT=$("$SUT" create --title "fix: thing" --label "area:tooling" 2>&1); RC=$?
grep -q 'ISSUE: #130' <<<"$OUT" && ok "create -> parses issue number" || bad "create issue number" "$OUT"
[ "$RC" -eq 0 ] && ok "create default -> exit 0" || bad "create exit 0" "rc=$RC"
grep -q 'priority=P1' <<<"$OUT" && ok "create -> Priority defaults to P1" || bad "P1 default" "$OUT"
grep -q 'version=v2.3' <<<"$OUT" && ok "create -> Version auto-resolved" || bad "version push" "$OUT"
grep -q 'status=Todo' <<<"$OUT" && ok "create -> Status defaults to Todo" || bad "status default" "$OUT"
grep -q 'estimate=0.1' <<<"$OUT" && ok "create -> Estimate defaults to 0.1" || bad "estimate default" "$OUT"
grep -q 'WARN' <<<"$OUT" && bad "create default -> no field-set warnings" "$OUT" || ok "create -> all fields set (no WARN)"
[ "$(wc -l < "$FIELDS_CALLS")" -eq 1 ] && ok "field metadata fetched exactly ONCE (cache alive)" || bad "cache: fields query ran $(wc -l < "$FIELDS_CALLS")x" "$OUT"
grep -q 'opt_p1' "$EDIT_LOG"  && ok "edit -> Priority set to P1 option id" || bad "priority option" "$(cat "$EDIT_LOG")"
grep -q 'opt_v23' "$EDIT_LOG" && ok "edit -> Version set to v2.3 option id" || bad "version option" "$(cat "$EDIT_LOG")"
grep -q 'opt_todo' "$EDIT_LOG" && ok "edit -> Status set to Todo option id" || bad "status option" "$(cat "$EDIT_LOG")"
grep -qE 'number 0.1' "$EDIT_LOG" && ok "edit -> Estimate set as number" || bad "estimate number" "$(cat "$EDIT_LOG")"

# --- create with overrides ------------------------------------------------
: > "$EDIT_LOG"
OUT=$("$SUT" create --title "fix: urgent" --label "bug" --label "area:reliability" --priority P0 --version v2.2 --estimate 0.5 2>&1)
grep -q 'priority=P0' <<<"$OUT" && ok "override -> Priority P0" || bad "priority override" "$OUT"
grep -q 'version=v2.2' <<<"$OUT" && ok "override -> Version v2.2" || bad "version override" "$OUT"
grep -q 'opt_p0'  "$EDIT_LOG" && ok "edit -> P0 option id" || bad "P0 option"
grep -q 'opt_v22' "$EDIT_LOG" && ok "edit -> v2.2 option id" || bad "v2.2 option"

# --- version fallback setting (successful-but-empty resolution) -----------
# Rows: name | VER_MODE | github_project_version_fallback | subcommand | want rc | want in output | want Version option id in the edit log (- = no Version edit)
FALLBACK_CASES=(
  "blank fallback -> Version left unset, with a note|none||create|0|version=none|-"
  "blank fallback -> the note names the setting|none||create|0|github_project_version_fallback|-"
  "fallback set -> Version is the fallback|none|Unversioned|create|0|version=Unversioned|opt_unv"
  "the fallback is never the resolved release|fallback|Unversioned|version|0|unresolved|-"
)
for row in "${FALLBACK_CASES[@]}"; do
  IFS='|' read -r name mode fb sub want_rc want_out want_opt <<<"$row"
  : > "$EDIT_LOG"
  if [ "$sub" = create ]; then
    OUT=$(VER_MODE=$mode AGENTIC_KIT_GITHUB_PROJECT_VERSION_FALLBACK="$fb" "$SUT" create --title "x" --label "area:tooling" 2>&1); RC=$?
  else
    OUT=$(VER_MODE=$mode AGENTIC_KIT_GITHUB_PROJECT_VERSION_FALLBACK="$fb" "$SUT" version 2>&1); RC=$?
  fi
  if [ "$want_opt" = - ]; then opt_ok=$(grep -q 'F_VER' "$EDIT_LOG" && echo no || echo yes)
  else opt_ok=$(grep -q "$want_opt" "$EDIT_LOG" && echo yes || echo no); fi
  if [ "$RC" -eq "$want_rc" ] && grep -qF "$want_out" <<<"$OUT" && [ "$opt_ok" = yes ]; then ok "$name"
  else bad "$name" "rc=$RC | $OUT | edits: $(cat "$EDIT_LOG")"; fi
done

# --- resolver ERROR (transient) must NOT silently mis-file to the fallback --
OUT=$(VER_MODE=fail "$SUT" create --title "x" --label "area:tooling" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "version-lookup failure -> exit 1 (not a silent fallback mis-file)" || bad "resolver-fail exit" "rc=$RC | $OUT"
grep -q 'ISSUE: #' <<<"$OUT" && bad "resolver-fail must NOT create an issue" "$OUT" || ok "resolver-fail -> no issue created"

# --- partial-failure: item-edit fails -> WARN + non-zero exit -------------
OUT=$(EDIT_FAIL=1 "$SUT" create --title "x" --label "area:tooling" 2>&1); RC=$?
grep -q 'ISSUE: #130' <<<"$OUT" && ok "partial-fail -> ISSUE URL still surfaced first" || bad "URL surfaced on partial fail" "$OUT"
grep -q 'WARN' <<<"$OUT" && ok "partial-fail -> WARN line printed" || bad "WARN printed" "$OUT"
[ "$RC" -ne 0 ] && ok "partial-fail -> exits non-zero" || bad "partial-fail non-zero exit" "rc=$RC"

# --- version validation BEFORE create (no orphan) -------------------------
: > "$EDIT_LOG"
OUT=$("$SUT" create --title "x" --label "area:tooling" --version v9.9 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "bad --version -> exit 2 (before create)" || bad "version validation exit" "rc=$RC $OUT"
grep -q 'ISSUE: #' <<<"$OUT" && bad "bad --version must NOT create an issue" "$OUT" || ok "bad --version -> no issue created (no orphan)"

# --- guards ---------------------------------------------------------------
# (--priority is validated against the board's live Priority options.)
"$SUT" create --label "area:tooling" >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing --title -> exit 2" || bad "title guard"
"$SUT" create --title "x" >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing --label -> exit 2" || bad "label guard"
"$SUT" create --title "x" --label "L" --priority PX >/dev/null 2>&1; [ $? -eq 2 ] && ok "bad --priority -> exit 2" || bad "priority guard"
"$SUT" create --title "x" --label "L" --estimate abc >/dev/null 2>&1; [ $? -eq 2 ] && ok "non-numeric --estimate -> exit 2" || bad "estimate guard"
"$SUT" create --title "x" --label "-inject" >/dev/null 2>&1; [ $? -eq 2 ] && ok "leading-dash --label -> exit 2 (no flag smuggling)" || bad "dash guard"

# --- no board: github_project blank -> plain issue create, no field edits ----
: > "$EDIT_LOG"; : > "$FIELDS_CALLS"
OUT=$(GH_ISSUE_PROJECT='' "$SUT" create --title "x" --label "area:tooling" 2>&1); RC=$?
grep -q 'ISSUE: #130' <<<"$OUT" && ok "no board -> issue created" || bad "no-board create" "$OUT"

# A GitHub Enterprise host keeps its URL.
OUT=$(STUB_HOST=ghe.example.com GH_ISSUE_PROJECT="" "$SUT" create --title "x" --label "bug" 2>&1); RC=$?
grep -q 'ISSUE: #130  https://ghe.example.com/acme/widgets/issues/130' <<<"$OUT" && ok "a GitHub Enterprise issue URL is kept" || bad "GHE URL" "rc=$RC $OUT"
grep -q 'board=none' <<<"$OUT" && ok "no board -> says board=none" || bad "no-board note" "$OUT"
[ "$RC" -eq 0 ] && ok "no board -> exit 0" || bad "no-board exit" "rc=$RC"
[ ! -s "$EDIT_LOG" ] && [ ! -s "$FIELDS_CALLS" ] && ok "no board -> no project queries or edits" || bad "no-board touched the project"
OUT=$(GH_ISSUE_PROJECT=acme/notanumber "$SUT" create --title "x" --label "l" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "malformed github_project -> exit 2" || bad "project format guard" "rc=$RC $OUT"

# --- input and failure handling: valueless flags, --status validated before create, a version
#     lookup failure, the --estimate shape, a board without some fields, an item-add failure ---
# Rows: name | env (space separated) | args | want exit | must match (blank: none) |
#       must NOT match (blank: none) | issue created (yes|no)
CASES=(
  "a valueless --title is a usage error||create --title|2|needs a value||no"
  "a valueless --label is a usage error||create --title x --label|2|needs a value||no"
  "a valueless --estimate is a usage error||create --title x --label l --estimate|2|needs a value||no"
  "an unknown --status is rejected before create||create --title x --label l --status Doing|2|--status 'Doing' is not a Status option||no"
  "a version lookup failure exits 1|VER_MODE=fail|version|1|lookup failed||-"
  "--estimate . is rejected||create --title x --label l --estimate .|2|--estimate must be||no"
  "--estimate 1. is rejected||create --title x --label l --estimate 1.|2|--estimate must be||no"
  "--estimate .5 is accepted||create --title x --label l --estimate .5|0|estimate=.5||yes"
  "fields the board lacks are skipped with a note|FIELDS_MODE=bare|create --title x --label l|0|not on the board: Priority Version Estimate|WARN|yes"
  "an explicit value for a missing field is rejected before create|FIELDS_MODE=bare|create --title x --label l --priority P0|2|has no Priority field||no"
  "an item-add failure is reported with its cause|ADD_FAIL=1 ITEM_MISSING=1|create --title x --label l|1|boom: project not writable||yes"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name envs args want_rc must mustnot created <<<"$row"
  # shellcheck disable=SC2086
  OUT=$(env $envs "$SUT" $args 2>&1); RC=$?
  verdict=yes
  [ "$RC" = "$want_rc" ] || verdict="exit $RC, want $want_rc"
  [ -z "$must" ] || grep -qF -- "$must" <<<"$OUT" || verdict="missing [$must]"
  [ -z "$mustnot" ] || ! grep -qF -- "$mustnot" <<<"$OUT" || verdict="has [$mustnot]"
  case "$created" in
    yes) grep -q 'ISSUE: #' <<<"$OUT" || verdict="no issue created" ;;
    no)  ! grep -q 'ISSUE: #' <<<"$OUT" || verdict="an issue was created" ;;
  esac
  [ "$verdict" = yes ] && ok "$name" || bad "$name" "$verdict | $OUT"
done

# --- help -----------------------------------------------------------------
"$SUT" --help >/dev/null 2>&1; [ $? -eq 0 ] && ok "--help -> exit 0" || bad "help exit 0"

printf '\ngh-issue.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
