#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests validate-context-budgets.sh --all against a fixture repo laid out the way the bridge
# installs it (.agent-harness/ holds the validator, rules-for-paths.sh and yq-resolve.sh).
#   - yq is found by parsing with it (resolve_yq), so kislyuk's python-yq on PATH is never
#     used: the run either uses a working yq from a known location or stops with the
#     "no working yq" hint, and never misreads every skill.
#   - a SKILL.md without frontmatter adds 0 bytes to the description total (a guard: yq
#     prints one newline for empty input, which the count already subtracts).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
for t in jq python3 git; do command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 0; }; done

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/repo"
git init -q "$FIX"
mkdir -p "$FIX/.agent-harness" "$FIX/.claude/rules" "$FIX/.claude/skills/with-fm" "$FIX/.claude/skills/no-fm"
cp "$HERE/validate-context-budgets.sh" "$HERE/rules-for-paths.sh" "$HERE/yq-resolve.sh" "$FIX/.agent-harness/"
printf '# Always rule\n' > "$FIX/.claude/rules/always.md"
printf -- '---\nname: with-fm\ndescription: abc\n---\n# Skill\n' > "$FIX/.claude/skills/with-fm/SKILL.md"
printf '# A skill file with no frontmatter\n' > "$FIX/.claude/skills/no-fm/SKILL.md"

run() { # run <PATH value>: runs the validator in the fixture; output in $TMP/out
  (cd "$FIX" && env PATH="$1" AGENTIC_KIT_CONTEXT_BUDGET_SKIP_STAGED=1 bash .agent-harness/validate-context-budgets.sh --all >"$TMP/out" 2>&1)
}

# A python-yq stand-in: answers to `yq`, but rejects `-o json` and prints its own usage.
PYYQ="$TMP/pyyq"; mkdir -p "$PYYQ"
printf '#!/bin/sh\necho "usage: yq [options] <jq filter> [input file...]" >&2\nexit 2\n' > "$PYYQ/yq"; chmod +x "$PYYQ/yq"
run "$PYYQ:$PATH"; rc=$?
if { [ "$rc" = 0 ] && grep -q 'skill-descriptions=3 ' "$TMP/out"; } || { [ "$rc" != 0 ] && grep -q 'no working yq' "$TMP/out"; }; then
  ok "python-yq on PATH is never used (a working yq from a known path, or the no-yq hint)"
else bad "python-yq on PATH (exit $rc: $(tail -2 "$TMP/out" | tr '\n' ' '))"; fi

# With a working yq: the frontmatter-less SKILL.md adds nothing.
. "$HERE/yq-resolve.sh"
if YQ="$(resolve_yq)"; then
  YQDIR="$TMP/realyq"; mkdir -p "$YQDIR"; ln -s "$(command -v "$YQ" || printf '%s' "$YQ")" "$YQDIR/yq"
  run "$YQDIR:$PATH"; rc=$?
  if [ "$rc" = 0 ] && grep -q 'skill-descriptions=3 ' "$TMP/out"; then ok "a SKILL.md without frontmatter adds 0 bytes"
  else bad "description total with a frontmatter-less SKILL.md (exit $rc: $(tail -2 "$TMP/out" | tr '\n' ' '))"; fi
else
  echo "SKIP: no working yq on this machine; the byte-count row needs one"
fi

# The always-loaded rules /starter:setup writes stay under 70% of the budget: no headroom warning.
if [ -n "${YQDIR:-}" ]; then
  cp "$HERE/../../plugins/starter/files/rules/"*.md "$FIX/.claude/rules/"
  run "$YQDIR:$PATH"; rc=$?
  if [ "$rc" = 0 ] && ! grep -q 'always-loaded rules is at' "$TMP/out"; then ok "the rules setup writes raise no always-loaded headroom warning"
  else bad "the rules setup writes (exit $rc: $(grep -i 'always' "$TMP/out" | tr '\n' ' '))"; fi
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
