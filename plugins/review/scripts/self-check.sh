#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# PostToolUse hook: substantial-change self-correction.
#
# On a substantial code edit, nudge the AGENT to self-correct BEFORE it presents:
# verify its own assumptions, address risks, hunt its own likely bugs - and FIX
# what it finds. The product is corrected code, NOT a report for the human to
# read and act on.
#
# Two design rules keep it from being noise:
#   1. Gated on change SIZE, not occurrence (drift-free, no risk-surface list to
#      maintain): a rename or one-liner stays silent; a substantial change fires,
#      by EITHER line count (SELF_CHECK_MIN_LINES, default 30) OR byte size
#      (SELF_CHECK_MIN_BYTES, default 1500). The byte floor catches a substantial
#      SINGLE-LINE edit - a long literal, or minified/generated content - that a
#      line count alone would miss.
#   2. The output is ACTION, not narration: the agent fixes what it finds and
#      presents the corrected work, with at most a ONE-LINE breadcrumb when the
#      self-check actually changed something. A clean self-check is silent. The
#      human reviews the diff as usual and acts on nothing extra.
#
# Not an always-on report: firing on every edit and asking for a self-graded
# narration is noise on trivial edits and produces a report nobody acts on.
#
# Soft and advisory: injects hookSpecificOutput.additionalContext, never blocks,
# always exits 0. The blind review panel (review-cadence.sh) remains the external
# backstop - a self-check that phones it in is still caught by fresh eyes; this
# just makes the author fix its own stuff first, so the panel and the human see
# less.
#
# Two coverage limits by design: (a) work split across many sub-threshold edits
# never trips the per-edit gate; (b) it
# fires only on direct Edit/Write/MultiEdit, so Bash- or sub-agent-authored
# changes (no edit payload here) never reach it. The cadence panel is the catch
# for both.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null || true)
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
[ "$EVENT" = "PostToolUse" ] || exit 0

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[ -n "$FILE_PATH" ] || exit 0

# Prose and harness/config edits are not code changes to self-correct. Excluded
# by extension (prose) and by the .claude/ harness dir. A real code file under a
# docs/ dir still self-checks; only its prose (*.md etc.) is skipped, by extension.
case "$FILE_PATH" in
  *.md|*.mdx|*.txt|*CHANGELOG*|*LICENSE*|*/.claude/*) exit 0 ;;
esac

# Size gate (drift-free): measure the NEW content this edit introduced - the
# Write's content, the Edit's new_string, or the sum of a MultiEdit's edits.
# Fire on a substantial change by EITHER line count OR byte size; below both
# the change is trivial (rename, one-liner) - stay silent.
NEW=$(printf '%s' "$INPUT" | jq -r '
  [ .tool_input.content // empty,
    .tool_input.new_string // empty,
    ( .tool_input.edits // [] | map(.new_string // empty) | join("\n") )
  ] | join("\n")' 2>/dev/null || true)
LINES=$(printf '%s' "$NEW" | awk 'END{print NR}')
BYTES=$(printf '%s' "$NEW" | wc -c | tr -d '[:space:]')
THRESHOLD="${SELF_CHECK_MIN_LINES:-30}"
BYTE_THRESHOLD="${SELF_CHECK_MIN_BYTES:-1500}"
# Sanitize the env overrides: a malformed value falls back to the default rather
# than leaking a `[: integer expression expected` warning to stderr.
case "$THRESHOLD"      in ''|*[!0-9]*) THRESHOLD=30 ;;       esac
case "$BYTE_THRESHOLD" in ''|*[!0-9]*) BYTE_THRESHOLD=1500 ;; esac
if [ "${LINES:-0}" -lt "$THRESHOLD" ] && [ "${BYTES:-0}" -lt "$BYTE_THRESHOLD" ]; then
  exit 0
fi

emit() {
  jq -nc --arg ctx "$1" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}'
}

emit "SELF-CHECK (substantial change to ${FILE_PATH}) - before you finish this turn, self-correct. Do NOT write a Code Change Analysis report. For this change: (1) name your key assumptions and VERIFY each against the code/repo; (2) weigh the risks and edge cases and ADDRESS them; (3) hunt your own likely bugs (nil/err handling, races, auth or tenant scope, off-by-one, wrong unit/scale) and FIX what is real. Present the corrected work. Note what the self-check changed in ONE line ONLY if it actually changed something; if the self-check was clean, say nothing. The reviewer panel still verifies independently - this is you fixing your own gaps first, not a report for the human."

exit 0
