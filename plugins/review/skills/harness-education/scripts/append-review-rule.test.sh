#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for append-review-rule.sh: it appends one rule to the team rules file in the format the
# team-rules lens reads (`## <PREFIX>-<NNN>: <title>`, a statement, an `Apply to:` line), with
# the next free id for the prefix; it creates the file when missing; it refuses a duplicate
# title and malformed input without touching the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/append-review-rule.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
F="$TMP/rules/review-rules.md"

add() { bash "$SUT" --file "$F" "$@" 2>"$TMP/err"; }

# The appends below run in order against one file, since each id depends on the ones before.
out=$(add --prefix DB --title "New tables carry an owner column" --statement "Every new table names the team that owns its rows." --apply-to "migrations, schema files"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "DB-001" ] && ok "first rule creates the file and gets DB-001" || bad "first rule (exit $rc, out [$out]: $(cat "$TMP/err"))"
grep -qx '# Team review rules' "$F" && ok "a new file starts with its heading" || bad "new file heading"
grep -qx '## DB-001: New tables carry an owner column' "$F" && grep -qx 'Apply to: migrations, schema files' "$F" && ok "the rule is written in the lens format" || bad "rule format: $(cat "$F")"

out=$(add --prefix DB --title "Backfills are resumable" --statement "A backfill records progress so a rerun continues." --apply-to "operational jobs" --evidence "PR #112, PR #115"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "DB-002" ] && ok "the next rule in the prefix gets DB-002" || bad "second rule (exit $rc, out [$out])"
grep -qx 'Evidence: PR #112, PR #115' "$F" && ok "evidence is recorded under the rule" || bad "evidence line"

printf '\n## DB-007: A hand-numbered rule\n\nx\n\nApply to: y\n' >> "$F"
out=$(add --prefix DB --title "Indexes ship with their query" --statement "s" --apply-to "a"); rc=$?
[ "$out" = "DB-008" ] && ok "ids continue after the highest existing id, not the count" || bad "id after a gap (out [$out])"

out=$(add --prefix API --title "Errors carry a stable code" --statement "s" --apply-to "handlers"); rc=$?
[ "$out" = "API-001" ] && ok "a new prefix starts at 001" || bad "new prefix (out [$out])"

out=$(add --prefix API --title 'Paths use C:\new form' --statement "s" --apply-to "handlers"); rc=$?
[ "$out" = "API-002" ] && grep -qxF '## API-002: Paths use C:\new form' "$F" && ok "a title with a backslash is written as given" || bad "backslash title (out [$out])"

before=$(cat "$F")
# Rows: name | want exit | args...
while IFS='|' read -r name want args; do
  # shellcheck disable=SC2086
  eval "set -- $args"
  bash "$SUT" --file "$F" "$@" >/dev/null 2>"$TMP/err"; rc=$?
  if [ "$rc" = "$want" ] && [ "$(cat "$F")" = "$before" ]; then ok "$name (exit $rc, file unchanged)"
  else bad "$name (exit $rc, want $want; file changed: $([ "$(cat "$F")" = "$before" ] && echo no || echo yes))"; fi
done <<'ROWS'
a duplicate title is refused, any case|3|--prefix DB --title "new tables CARRY an owner column" --statement s --apply-to a
a duplicate title with a backslash is refused|3|--prefix API --title 'paths use C:\new form' --statement s --apply-to a
a lower-case prefix is a usage error|2|--prefix db --title t --statement s --apply-to a
a missing apply-to is a usage error|2|--prefix DB --title t --statement s
a title with a newline is a usage error|2|--prefix DB --title "$(printf 'a\nb')" --statement s --apply-to a
an unknown flag is a usage error|2|--prefix DB --title t --statement s --apply-to a --bogus x
ROWS

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
