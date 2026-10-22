#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -euo pipefail

# The hook and the context validator are the bridge's own sources; the fixture stands in
# for a repo with the Codex bridge installed, and a stub kit for the queue dispatcher.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/session-start.sh"
# The kit (bridge/codex/hooks beside bridge/agent-harness) or an installed repo (.codex/hooks
# beside .agent-harness).
CONTEXT_VALIDATOR="$(cd "$HERE/../../agent-harness" 2>/dev/null || cd "$HERE/../../.agent-harness" && pwd)/validate-context-budgets.sh"
fixture="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$fixture"' EXIT
git -C "$fixture" init -q

mkdir -p "$fixture/kit/plugins/queue/scripts" "$fixture/.codex/hooks"
printf '#!/bin/bash\nexit 0\n' >"$fixture/kit/plugins/queue/scripts/session-start-dispatcher.sh"
printf '#!/bin/bash\nset -euo pipefail\n"$REAL_CONTEXT_VALIDATOR" --staged-only >/dev/null\nprintf "run\\n" >>"$VALIDATION_COUNT"\n' >"$fixture/.codex/hooks/validate-harness-if-needed.sh"
chmod +x "$fixture/kit/plugins/queue/scripts/session-start-dispatcher.sh" "$fixture/.codex/hooks/validate-harness-if-needed.sh"
count_file="$fixture/count"

run_source() {
  jq -nc --arg source "$1" '{hook_event_name:"SessionStart",source:$source}' \
    | (cd "$fixture" && CLAUDE_PROJECT_DIR="$fixture" SESSION_CONTEXT_DIR="$fixture/.claude/triage/session-context" \
      AGENTIC_KIT_HOME="$fixture/kit" REAL_CONTEXT_VALIDATOR="$CONTEXT_VALIDATOR" \
      VALIDATION_COUNT="$count_file" bash "$HOOK" >/dev/null)
}

run_source startup
run_source resume
run_source clear
run_source compact

[ "$(wc -l <"$count_file" | tr -d '[:space:]')" = 2 ] || {
  echo "expected validation only for startup and resume" >&2
  exit 1
}

fallback_count="$fixture/fallback-count"
mkdir -p "$fixture/.agent-harness"
printf '#!/bin/bash\nprintf "run %%s\\n" "$1" >>"$FALLBACK_COUNT"\n' >"$fixture/.agent-harness/validate-codex-harness.sh"
chmod +x "$fixture/.agent-harness/validate-codex-harness.sh"
chmod -x "$fixture/.codex/hooks/validate-harness-if-needed.sh"
FALLBACK_COUNT="$fallback_count" run_source startup
chmod +x "$fixture/.codex/hooks/validate-harness-if-needed.sh"
[ "$(cat "$fallback_count")" = "run --quick" ] || {
  echo "expected missing cache helper to fall back to direct quick validation" >&2
  exit 1
}

mkdir -p "$fixture/.claude/triage/session-context"
dd if=/dev/zero of="$fixture/.claude/triage/session-context/oversized.md" bs=8193 count=1 2>/dev/null
staged_error="$(run_source startup 2>&1 >/dev/null || true)"
printf '%s' "$staged_error" | grep -F 'Codex harness drift detected' >/dev/null || {
  echo "expected oversized staged context to surface validation failure" >&2
  exit 1
}
[ "$(wc -l <"$count_file" | tr -d '[:space:]')" = 2 ] || {
  echo "failed staged-only validation should stop before the cached source validator" >&2
  exit 1
}

echo "session-start event-gate tests passed."
