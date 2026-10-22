#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# claude-lens.sh — local read-only Claude review engine for /review:claude-lens and
# review-panel's counterpart-model pass.
#
# Classification mirrors codex-lens.sh:
#   FINDINGS — Claude completed and returned valid structured output.
#   SKIPPED  — the Claude CLI is not installed, or BASE..HEAD changes no file (nothing to
#              review, so no model call). These are the only skips.
#   FAILED   — every other failure, including auth, quota, parse, base, and timeout.
# Self-determined outcomes exit 0 because the panel is soft; caller TERM/INT propagate.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE=""
FOCUS=""
case "${1:-}" in
  --base)   BASE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
  --base=*) BASE="${1#--base=}"; shift ;;
esac
[ $# -gt 0 ] && FOCUS="$*"

if [ -z "$BASE" ]; then
  echo "CLAUDE-LENS: FAILED --base <ref> is required (branch mode reviews committed BASE..HEAD)"
  exit 0
fi
case "$BASE" in
  -*)
    echo "CLAUDE-LENS: FAILED (non-blocking, investigate): --base must be a revision, not a Git option: '$BASE'"
    exit 0
    ;;
esac

if ! command -v claude >/dev/null 2>&1; then
  echo "CLAUDE-LENS: SKIPPED claude unavailable (not installed): claude='$(command -v claude || true)'"
  exit 0
fi

CONFIG="${CLAUDE_LENS_CONFIG:-$SCRIPT_DIR/../claude-lens.config}"
KIT_CONFIG="$SCRIPT_DIR/../../../scripts/kit-config.sh"
if [ ! -f "$CONFIG" ]; then
  echo "CLAUDE-LENS: FAILED (non-blocking, investigate): config not found at $CONFIG"
  exit 0
fi
# shellcheck disable=SC1090
. "$CONFIG"

PROMPT_TEMPLATE="${CLAUDE_LENS_PROMPT:-$SCRIPT_DIR/../../codex-lens/codex-lens.prompt.md}"
SCHEMA="${CLAUDE_LENS_SCHEMA:-$SCRIPT_DIR/../../codex-lens/codex-lens.schema.json}"
if [ ! -f "$PROMPT_TEMPLATE" ]; then
  echo "CLAUDE-LENS: FAILED (non-blocking, investigate): prompt not found at $PROMPT_TEMPLATE"
  exit 0
fi
if [ ! -f "$SCHEMA" ]; then
  echo "CLAUDE-LENS: FAILED (non-blocking, investigate): schema not found at $SCHEMA"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "CLAUDE-LENS: FAILED (non-blocking, investigate): jq is required to extract Claude structured output"
  exit 0
fi

# Model and effort are settings: CLAUDE_LENS_MODEL / CLAUDE_LENS_EFFORT carry the values the skill
# passes, resolved through kit-config.sh. A blank model leaves the CLI on its own default.
if [ ! -r "$KIT_CONFIG" ]; then
  echo "CLAUDE-LENS: FAILED (non-blocking, investigate): settings resolver not found at $KIT_CONFIG"
  exit 0
fi
# shellcheck source=../../../scripts/kit-config.sh
. "$KIT_CONFIG"
MODEL="$(kit_config claude_model "${CLAUDE_LENS_MODEL:-}")"
EFFORT="$(kit_config claude_effort "${CLAUDE_LENS_EFFORT:-}")"
: "${EFFORT:=medium}"

if ! TIP=$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null); then
  echo "CLAUDE-LENS: FAILED (non-blocking, investigate): cannot resolve HEAD to an immutable commit"
  exit 0
fi
if ! MB=$(git merge-base "$BASE" "$TIP" 2>/dev/null); then
  echo "CLAUDE-LENS: FAILED (non-blocking, investigate): cannot resolve merge-base of '$BASE' and HEAD (bad --base?)"
  exit 0
fi
RANGE="$MB..$TIP"

tmpdir=$(mktemp -d); cout="$tmpdir/stdout"; cerr="$tmpdir/stderr"; pfile="$tmpdir/prompt"; diff_file="$tmpdir/branch.diff"
chmod 700 "$tmpdir"
trap 'kill "${cpid:-}" "${wpid:-}" 2>/dev/null; rm -rf "${tmpdir:-}"' EXIT

if ! git diff --no-ext-diff --submodule=diff "$RANGE" > "$diff_file" 2>"$cerr"; then
  printf 'CLAUDE-LENS: FAILED (non-blocking, investigate): could not collect branch diff:\n%s\n' "$(cat "$cerr")"
  exit 0
fi
chmod 600 "$diff_file"
if ! changed_files=$(git diff --name-only "$RANGE" 2>"$cerr"); then
  printf 'CLAUDE-LENS: FAILED (non-blocking, investigate): could not collect changed files:\n%s\n' "$(cat "$cerr")"
  exit 0
fi
if ! commit_log=$(git log --oneline --decorate "$RANGE" 2>"$cerr"); then
  printf 'CLAUDE-LENS: FAILED (non-blocking, investigate): could not collect commit log:\n%s\n' "$(cat "$cerr")"
  exit 0
fi
if ! diff_stat=$(git diff --stat "$RANGE" 2>"$cerr"); then
  printf 'CLAUDE-LENS: FAILED (non-blocking, investigate): could not collect diff stat:\n%s\n' "$(cat "$cerr")"
  exit 0
fi
file_count=$(printf '%s\n' "$changed_files" | grep -c . || true)
if [ "${file_count:-0}" -eq 0 ]; then
  echo "CLAUDE-LENS: SKIPPED empty range: $RANGE changes no file (nothing to review)"
  exit 0
fi
diff_bytes=$(wc -c < "$diff_file" | tr -d ' ')
review_root="$tmpdir/repo"
mkdir -p "$review_root"
archive_file="$tmpdir/repo.tar"
if ! git archive --format=tar -o "$archive_file" "$TIP" 2>"$cerr" \
  || ! tar -xf "$archive_file" -C "$review_root" 2>>"$cerr"; then
  printf 'CLAUDE-LENS: FAILED (non-blocking, investigate): could not create tracked-file review snapshot:\n%s\n' "$(cat "$cerr")"
  exit 0
fi
rm -f "$archive_file"
: "${CLAUDE_LENS_MAX_INLINE_FILES:=50}"
: "${CLAUDE_LENS_MAX_INLINE_DIFF_BYTES:=262144}"
if [ "${file_count:-0}" -le "$CLAUDE_LENS_MAX_INLINE_FILES" ] && [ "${diff_bytes:-0}" -le "$CLAUDE_LENS_MAX_INLINE_DIFF_BYTES" ]; then
  collection_guidance="Use the repository context below as primary evidence."
  review_input=$(printf '## Commit Log\n```\n%s\n```\n\n## Diff Stat\n```\n%s\n```\n\n## Branch Diff\n```\n%s\n```\n' \
    "$commit_log" \
    "$diff_stat" \
    "$(cat "$diff_file")")
else
  collection_guidance="The complete patch is in $diff_file. Read it from beginning to end, paging with offsets when needed, before finalizing findings. The repository tools are read-only; do not claim a complete verdict from the summary alone."
  review_input=$(printf '## Commit Log\n```\n%s\n```\n\n## Diff Stat\n```\n%s\n```\n\n## Changed Files\n```\n%s\n```\n\n## Complete Patch\n%s\n' \
    "$commit_log" \
    "$diff_stat" \
    "$changed_files" \
    "$diff_file")
fi
add_dir_args=( --add-dir "$tmpdir" )
model_args=()
[ -n "$MODEL" ] && model_args=( --model "$MODEL" )

user_focus="No extra focus provided."
[ -n "$FOCUS" ] && user_focus="$FOCUS"

system_prompt=$(sed '/<repository_context>/,$d' "$PROMPT_TEMPLATE")
replace_token() {
  local source="$1" token="$2" replacement="$3"
  case "$source" in
    *"$token"*) ;;
    *) return 1 ;;
  esac
  printf '%s%s%s' "${source%%"$token"*}" "$replacement" "${source#*"$token"}"
}
for prompt_binding in \
  'You are Codex performing|You are Claude performing' \
  "{{TARGET_LABEL}}|branch diff against $BASE" \
  "{{USER_FOCUS}}|$user_focus" \
  "{{REVIEW_COLLECTION_GUIDANCE}}|$collection_guidance"
do
  token=${prompt_binding%%|*}
  replacement=${prompt_binding#*|}
  if ! system_prompt=$(replace_token "$system_prompt" "$token" "$replacement"); then
    echo "CLAUDE-LENS: FAILED (non-blocking, investigate): shared prompt template drift; missing token '$token'"
    exit 0
  fi
done
printf '<repository_context>\n%s\n</repository_context>\n' "$review_input" > "$pfile"

# Claude Code's structured-output validator accepts the schema vocabulary but rejects
# the draft URI metadata itself. Preserve the committed schema in parity with Codex and
# remove only that annotation at the CLI boundary.
schema_json=$(jq -c 'del(."$schema")' "$SCHEMA")
(
  cd "$review_root" || exit 1
  exec claude -p \
    --safe-mode \
    --restricted \
    --tools "Read,Grep,Glob" \
    --permission-mode dontAsk \
    --permission-prompts none \
    --no-session-persistence \
    --system-prompt "$system_prompt" \
    ${model_args[@]+"${model_args[@]}"} \
    --effort "$EFFORT" \
    --output-format json \
    --json-schema "$schema_json" \
    ${add_dir_args[@]+"${add_dir_args[@]}"}
) >"$cout" 2>"$cerr" <"$pfile" &
cpid=$!

trap 'kill "$cpid" "${wpid:-}" 2>/dev/null; exit 143' TERM
trap 'kill "$cpid" "${wpid:-}" 2>/dev/null; exit 130' INT

cap="${CLAUDE_LENS_TIMEOUT:-900}"
case "$cap" in ''|*[!0-9]*) cap=900 ;; esac
[ "${#cap}" -gt 8 ] && cap=900
[ "$cap" -lt 1 ] && cap=900
( waited=0
  while [ "$waited" -lt "$cap" ]; do
    kill -0 "$cpid" 2>/dev/null || exit 0
    sleep 1; waited=$((waited + 1))
  done
  kill -0 "$cpid" 2>/dev/null || exit 0
  : >"$cout.timedout"
  kill "$cpid" 2>/dev/null
  grace=0
  while [ "$grace" -lt 3 ]; do
    kill -0 "$cpid" 2>/dev/null || exit 0
    sleep 1; grace=$((grace + 1))
  done
  kill -9 "$cpid" 2>/dev/null ) &
wpid=$!
wait "$cpid" 2>/dev/null; rc=$?
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
out=$(cat "$cout" 2>/dev/null)
err=$(cat "$cerr" 2>/dev/null)
timedout=""; [ -f "$cout.timedout" ] && timedout=1

if [ -n "$timedout" ] && [ "$rc" -ne 0 ]; then
  printf 'CLAUDE-LENS: FAILED (non-blocking, investigate — not a clean verdict): timed out after %ss (CLAUDE_LENS_TIMEOUT); partial output follows:\n%s\n%s\n' "$cap" "$out" "$err"
elif [ "$rc" -eq 0 ]; then
  final=$(printf '%s' "$out" | jq -c '.structured_output // empty' 2>/dev/null || true)
  # structured_output is checked against the shared schema here too, by a checker that reads
  # the schema file itself (codex-lens/schema-check.jq), so the two cannot drift.
  problems=""
  [ -z "$final" ] || problems=$(printf '%s' "$final" | jq -r --argjson schema "$schema_json" -f "$SCRIPT_DIR/../../codex-lens/schema-check.jq" 2>&1) \
    || problems="not JSON: $problems"
  if [ -n "$final" ] && [ -z "$problems" ]; then
    printf 'CLAUDE-LENS: FINDINGS\n%s\n' "$final"
  elif [ -n "$final" ]; then
    printf 'CLAUDE-LENS: FAILED (non-blocking, investigate — not a clean verdict): structured_output does not match the output schema:\n%s\n%s\n' "$problems" "$final"
  else
    printf 'CLAUDE-LENS: FAILED (non-blocking, investigate — valid structured output missing):\n%s\n' "$out"
  fi
else
  printf 'CLAUDE-LENS: FAILED (non-blocking, investigate — not a clean verdict):\n%s\n%s\n' "$out" "$err"
fi
exit 0
