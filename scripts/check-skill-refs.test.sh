#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for check-skill-refs.sh on a planted tree: a bare reference to a shipped skill fails,
# and paths, file names, qualified names and unknown commands pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/check-skill-refs.sh"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
plant() {  # plant <file content>: a fresh tree with two skills and one doc
  rm -rf "$TMP/kit"; mkdir -p "$TMP/kit/plugins/ship/skills/pr" "$TMP/kit/plugins/ship/skills/codex-sweep" "$TMP/kit/docs"
  : > "$TMP/kit/plugins/ship/skills/pr/SKILL.md"; : > "$TMP/kit/plugins/ship/skills/codex-sweep/SKILL.md"
  printf '%b' "$1" > "$TMP/kit/docs/doc.md"
}

# Rows: name | want exit | doc content (printf %b) | output must contain (- = nothing)
CASES=(
  "a bare skill name fails|1|Run \`/codex-sweep 42\` next.\n|docs/doc.md:1: bare /codex-sweep, write /ship:codex-sweep"
  "a bare short skill name fails|1|See /pr for the steps.\n|bare /pr, write /ship:pr"
  "a qualified name passes|0|Run \`/ship:codex-sweep 42\` and /ship:pr.\n|-"
  "a skill folder path passes|0|plugins/ship/skills/pr/SKILL.md and skills/codex-sweep/\n|-"
  "a script file name passes|0|run ./codex-sweep.sh or <dir>/pr.md\n|-"
  "a longer command sharing a prefix passes|0|use /pr-review and /prune\n|-"
  "an unknown command passes|0|run /deploy-staging\n|-"
  "a hit on a later line names that line|1|ok\nfine\nthen /pr\n|docs/doc.md:3:"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name want content expect <<< "$row"
  plant "$content"
  out="$(bash "$SUT" "$TMP/kit" 2>&1)"; rc=$?
  if [ "$rc" != "$want" ]; then bad "$name (exit $rc, want $want): $out"; continue; fi
  if [ "$expect" != "-" ] && ! printf '%s' "$out" | grep -qF "$expect"; then bad "$name: output lacks [$expect]: $out"; continue; fi
  ok "$name"
done

# The kit itself is clean.
out="$(bash "$SUT" "$HERE/.." 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "the kit has no bare skill reference" || bad "the kit has bare skill references: $out"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
