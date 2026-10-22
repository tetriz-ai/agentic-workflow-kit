#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for check-rule-index.sh against fixture repos. Three contracts: every `## <ID>:` rule in
# the rules document has an index row starting with that ID; every test named in an "Enforced by"
# cell is declared under the enforcer roots; every ci-hard row names a test or a command. Rows in
# fenced code blocks and prose mentions do not count.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/check-rule-index.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# fixture <dir>: a repo with two numbered rules, tests in Go and Python, and a good index.
fixture() {
  local d="$1"; mkdir -p "$d/docs" "$d/internal/arch" "$d/tests" "$d/.claude/rules"
  printf '# Rules\n\n## API-001: Every endpoint declares auth\n\ntext\n\n## DB-002: Tables carry an owner\n\ntext\n' > "$d/docs/rules.md"
  printf 'package arch\n\nfunc TestEndpointsDeclareAuth(t *testing.T) {}\n' > "$d/internal/arch/auth_test.go"
  printf 'def test_tables_have_owner():\n    pass\n' > "$d/tests/test_schema.py"
  cat > "$d/.claude/rules/rule-index.md" <<'EOF'
# Index

| Rule | Requires | Enforced by | Hardness |
|---|---|---|---|
| API-001 auth | declare auth | `TestEndpointsDeclareAuth` | ci-hard |
| DB-002 owner | owner column | `test_tables_have_owner` | ci-hard |
| style | tidy | `make lint` | ci-hard |
| docs | tidy prose | review panel | soft |

Prose may name TestSomethingGone or API-009 without counting.

```markdown
| API-999 example | x | `TestNotReal` | ci-hard |
```
EOF
}
run() { (cd "$1" && bash "$SUT" --rules docs/rules.md --index .claude/rules/rule-index.md --enforcers . >"$TMP/out" 2>&1); echo $?; }

# Edits applied to a fresh fixture, one per case (run inside the fixture).
e_none()        { :; }
e_no_row()      { printf '\n## OPS-003: Jobs are resumable\n' >> docs/rules.md; }
e_prose_only()  { printf '\n## API-009: Pagination is keyset\n' >> docs/rules.md; }
e_renamed()     { sed -i.bak 's/TestEndpointsDeclareAuth/TestEndpointsAuth/' internal/arch/auth_test.go && rm internal/arch/auth_test.go.bak; }
e_deleted()     { rm tests/test_schema.py; }
# add_row <row>: insert a row into the index's table, after its last row.
add_row()       { awk -v r="$1" '{ print } /^\| docs \| tidy prose/ { print r }' .claude/rules/rule-index.md > idx.tmp && mv idx.tmp .claude/rules/rule-index.md; }
e_bare_hard()   { add_row '| bare | x | a person checks | ci-hard |'; }
e_wrong_col()   { add_row '| ci-hard trap | ci-hard | nobody | ci-hard |'; }
e_requires()    { add_row '| req | see TestMissingOne | review panel | soft |'; }

# Rows: name | edit function | want exit | output must contain (blank: none)
CASES=(
  "a complete index passes|e_none|0|rule index: ok"
  "a rule with no row fails coverage|e_no_row|1|OPS-003"
  "a rule named only in prose does not count as a row|e_prose_only|1|API-009"
  "a renamed test fails integrity|e_renamed|1|TestEndpointsDeclareAuth"
  "a deleted python test fails integrity|e_deleted|1|test_tables_have_owner"
  "a ci-hard row with no enforcer fails|e_bare_hard|1|bare"
  "ci-hard named in another column still needs an enforcer in Enforced by|e_wrong_col|1|ci-hard trap"
  "a fenced example row is ignored|e_none|0|"
  "a test name in the Requires column is not an enforcer reference|e_requires|0|"
)
n=0
for row in "${CASES[@]}"; do
  n=$((n + 1))
  IFS='|' read -r name edit want must <<<"$row"
  d="$TMP/r$n"; fixture "$d"
  (cd "$d" && "$edit")
  rc=$(run "$d")
  if [ "$rc" = "$want" ] && { [ -z "$must" ] || grep -qF -- "$must" "$TMP/out"; }; then ok "$name"
  else bad "$name (exit $rc, want $want; out: $(tr '\n' ' ' < "$TMP/out"))"; fi
done

# No rules document: coverage is skipped with a note; the other checks still run.
d="$TMP/norules"; fixture "$d"; rm "$d/docs/rules.md"
rc=$(run "$d"); [ "$rc" = 0 ] && grep -q 'no rules document' "$TMP/out" && ok "a missing rules document skips coverage with a note" || bad "missing rules document (exit $rc)"

# The starter's own index passes on a fresh repo (its example row is fenced).
d="$TMP/starter"; mkdir -p "$d/.claude/rules"; cp "$HERE/../rules/rule-index.md" "$d/.claude/rules/rule-index.md"
(cd "$d" && bash "$SUT" --rules docs/architecture-rules.md --index .claude/rules/rule-index.md --enforcers . >"$TMP/out" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "the starter rule index passes in a fresh repo" || bad "starter index (exit $rc: $(tr '\n' ' ' < "$TMP/out"))"

# Usage.
bash "$SUT" >/dev/null 2>&1; rc=$?; [ "$rc" = 2 ] && ok "no arguments is a usage error" || bad "usage (exit $rc)"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
