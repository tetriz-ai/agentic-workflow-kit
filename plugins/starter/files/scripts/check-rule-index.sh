#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# check-rule-index.sh: keep the rule-enforcement index honest. Run it in CI.
#
# Usage: check-rule-index.sh --rules <rules document> --index <rule-index.md> --enforcers <dir>...
#
# Three contracts, read from the index's Markdown tables (a table whose header row has
# "Enforced by" and "Hardness" columns; rows inside fenced code blocks are examples and ignored):
#   1. Rule coverage: every `## <ID>:` heading in the rules document (ID like API-001) has an index
#      row whose first cell starts with that ID. A mention in prose does not count. A missing rules
#      document skips this check, with a note.
#   2. Referential integrity: every backticked test name in an "Enforced by" cell (an identifier
#      starting with Test or test_) is declared under the enforcer folders: `func Test...(` (Go),
#      `def test_...(` (Python), `fn test_...(` (Rust), `function test_...(` or `test_... = ` (JS).
#   3. Hard rows name an enforcer: every row whose Hardness cell is ci-hard has a backticked test
#      or command in its "Enforced by" cell.
# It does not judge whether a row's hardness is right, or whether the index covers areas that have
# no numbered rules: those are review calls.
# Exit: 0 consistent | 1 drift (each problem listed) | 2 usage or an unreadable index.
set -uo pipefail

usage() { echo "usage: check-rule-index.sh --rules <rules doc> --index <rule-index.md> --enforcers <dir>..." >&2; exit 2; }
rules="" index=""; enforcers=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rules) [ $# -ge 2 ] || usage; rules="$2"; shift 2 ;;
    --index) [ $# -ge 2 ] || usage; index="$2"; shift 2 ;;
    --enforcers) shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do enforcers+=("$1"); shift; done ;;
    *) usage ;;
  esac
done
[ -n "$rules" ] && [ -n "$index" ] && [ "${#enforcers[@]}" -gt 0 ] || usage
[ -r "$index" ] || { echo "check-rule-index: cannot read the index: $index" >&2; exit 2; }

# rows: "<first cell>\t<enforced-by cell>\t<hardness cell>" for every row of a table that has both
# columns, outside fenced code blocks.
rows="$(awk -F'|' '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  /^[ \t]*```/ { fence = !fence; next }
  fence { next }
  /^[ \t]*\|/ {
    if (!intable) {
      e = h = 0
      for (i = 2; i < NF; i++) { c = trim($i); if (c == "Enforced by") e = i; if (c == "Hardness") h = i }
      intable = 1; header = 1; next
    }
    if (header) { header = 0; next }            # the |---|---| separator row
    if (e && h) print trim($2) "\t" trim($e) "\t" trim($h)
    next
  }
  { intable = 0 }' "$index")"

problems=0
say() { echo "rule index: $*" >&2; problems=$((problems + 1)); }

# 1. Rule coverage.
if [ -r "$rules" ]; then
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s\n' "$rows" | cut -f1 | grep -Eq "^${id}([^0-9A-Za-z_-]|$)" || say "rule $id in $rules has no row in $index (start a row with \"| $id ...\")"
  done < <(grep -oE '^##[[:space:]]+[A-Z][A-Z0-9]*-[0-9]+:' "$rules" | sed -E 's/^##[[:space:]]+//; s/:$//' | sort -u)
else
  echo "rule index: no rules document at $rules; rule coverage not checked" >&2
fi

# 2. Referential integrity.
declared="$(grep -rhoE 'func (Test[A-Za-z0-9_]+)\(|def (test_[A-Za-z0-9_]+)\(|fn (test_[A-Za-z0-9_]+)\(|function (test_[A-Za-z0-9_]+)\(|(test_[A-Za-z0-9_]+) = ' \
  --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv --exclude-dir=vendor "${enforcers[@]}" 2>/dev/null \
  | sed -E 's/^(func |def |fn |function )//; s/[( =].*$//' | sort -u)"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf '%s\n' "$declared" | grep -qx "$name" || say "test $name named in $index is not declared under ${enforcers[*]}"
done < <(printf '%s\n' "$rows" | cut -f2 | grep -oE '`(Test[A-Za-z0-9_]+|test_[A-Za-z0-9_]+)`' | tr -d '`' | sort -u)

# 3. Hard rows name an enforcer.
while IFS=$'\t' read -r first enforced hard; do
  [ "$hard" = "ci-hard" ] || continue
  printf '%s' "$enforced" | grep -q '`[^`][^`]*`' || say "the ci-hard row \"$first\" names no test or command in its Enforced by cell"
done <<<"$rows"

if [ "$problems" -gt 0 ]; then echo "rule index: $problems problem(s)" >&2; exit 1; fi
echo "rule index: ok"
