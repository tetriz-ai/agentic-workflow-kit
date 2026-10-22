#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests default.rules against the layout sync-codex-harness.sh installs: every script path a rule
# names exists in that layout (`.agent-harness/<x>` is bridge/agent-harness/<x>), and, when the
# codex CLI is present, `codex execpolicy check` matches the installed paths with the rule's
# decision.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RULES="$HERE/default.rules"
# The kit (bridge/codex/rules) or an installed repo (.codex/rules beside .agent-harness/).
ROOT="$(cd "$HERE/../.." && pwd)"
HARNESS="$ROOT/agent-harness"; [ -d "$HARNESS" ] || HARNESS="$ROOT/.agent-harness"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# Every quoted script path in a rule pattern resolves in the installed layout.
paths=$(grep -oE '"(\./)?[A-Za-z0-9._/-]+\.sh"' "$RULES" | tr -d '"' | sort -u)
[ -n "$paths" ] || bad "no script path found in default.rules"
for p in $paths; do
  rel="${p#./}"
  case "$rel" in
    .agent-harness/*) if [ -f "$HARNESS/${rel#.agent-harness/}" ]; then ok "$p is an installed bridge script"; else bad "$p is not in $HARNESS"; fi ;;
    *) bad "$p is outside the installed .agent-harness/ layout" ;;
  esac
done

if command -v codex >/dev/null 2>&1; then
  # Rows: command | want decision
  CASES=(
    ".agent-harness/codex-push-current-branch.sh|prompt"
    "./.agent-harness/codex-push-current-branch.sh|prompt"
    "gh pr merge 7|forbidden"
  )
  for row in "${CASES[@]}"; do
    cmd=${row%|*}; want=${row##*|}
    # shellcheck disable=SC2086
    got=$(codex execpolicy check --rules "$RULES" -- $cmd 2>/dev/null | jq -r '.decision // "none"' 2>/dev/null)
    if [ "$got" = "$want" ]; then ok "execpolicy: $cmd -> $got"; else bad "execpolicy: $cmd -> $got, want $want"; fi
  done
else
  echo "SKIP: codex not installed; the execpolicy rows did not run"
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
