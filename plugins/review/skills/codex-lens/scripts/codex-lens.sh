#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# codex-lens.sh — the 0-token engine for the /review:codex-lens skill and review-panel
# Step 2.6's cross-model (Codex) lens. Invokes `codex exec` DIRECTLY over the
# committed BASE..HEAD range with the model and reasoning effort from the review
# plugin's settings, the adversarial review prompt beside this skill, and a
# read-only sandbox. It prints one leading status token so the caller reads a
# verdict, not shell.
#
# Why direct `codex exec` — not OpenAI's Codex plugin companion, not `codex review`:
#   - The companion's adversarial review IS a `codex exec`-style read-only turn, but it
#     never plumbs reasoning effort, so effort could only come from each person's own
#     Codex config. `codex exec -c` sets model and effort per run from the settings.
#   - `codex review` (the built-in reviewer) rejects a custom prompt alongside --base, so
#     it cannot carry our adversarial persona in branch mode; it also defaults to
#     workspace-write (runs tests/build) and reviews base->working-tree, not committed
#     BASE..HEAD. This lens must be read-only and persona-driven, so it uses exec.
#
# Why an engine, not an LLM relay subagent: Codex reads the diff (assembled here from git),
# so resolving/running/classifying need no model — a relay would only re-cache context to
# parse shell and echo Codex verbatim. The caller's sole model step is folding the printed
# FINDINGS into the panel's grades.
#
# Classification (same contract as ocr-lens.sh, so both fold into the panel the same):
#   FINDINGS  — the review completed (exit 0); its output follows.
#   SKIPPED   — `codex` is not installed (PATH miss), or BASE..HEAD changes no file (nothing
#               to review, so no model call). Both are structural — nothing in a branch name
#               or the review content can spoof them.
#   FAILED    — any other outcome (not logged in, quota, model not on the plan, crash, a bad
#               or flag-shaped --base, a git error while collecting the diff, a missing
#               config/prompt/schema, a run with no final message) OR a self-imposed
#               wall-clock timeout (a wedged run): no verdict; the error / partial output is
#               printed. Not a skip — never treat it as a clean pass.
#
# Codex runs from a `git archive` snapshot of the pinned tip (`codex exec -C`), so the files
# it browses are the committed ones, not the live checkout's untracked files (`.env` and the
# like). The read-only sandbox still lets it read an absolute path elsewhere on disk.
# Exits 0 on every self-determined outcome (soft lens: must never block the panel or the
# gate); it propagates 143/130 only when the CALLER signals TERM/INT.
#
# Usage: codex-lens.sh --base <ref> [focus text ...]
#   --base <ref>   REQUIRED, and must precede any focus text. Branch mode reviews committed
#                  BASE..HEAD (not the working tree) — run once the reviewed work is committed.
#   focus text     OPTIONAL. Extra targeting; passed to the prompt's User focus.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE=""
FOCUS=""
# --base is honored ONLY as the first argument — the documented contract ("--base must precede
# focus"). Everything after that first token is opaque focus, so a stray --base *inside* the focus
# text (even as its own word) stays in focus and can never hijack the review range.
case "${1:-}" in
  --base)   BASE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;   # 2nd shift only if the operand is present (a bare trailing --base must not hang)
  --base=*) BASE="${1#--base=}"; shift ;;
esac
[ $# -gt 0 ] && FOCUS="$*"

if [ -z "$BASE" ]; then
  echo "CODEX-LENS: FAILED --base <ref> is required (branch mode reviews committed BASE..HEAD)"
  exit 0
fi
case "$BASE" in
  -*) echo "CODEX-LENS: FAILED --base must not start with '-' (got '$BASE'); pass a ref"; exit 0 ;;
esac

# The one skip: Codex itself is not installed. Structural, so nothing spoofs it.
if ! command -v codex >/dev/null 2>&1; then
  echo "CODEX-LENS: SKIPPED codex unavailable (not installed): codex='$(command -v codex || true)'"
  exit 0
fi

# Sandbox and caps come from codex-lens.config; a missing config is a broken install, not a skip:
# FAILED. Model and effort come from the plugin settings through kit-config.sh.
CONFIG="${CODEX_LENS_CONFIG:-$SCRIPT_DIR/../codex-lens.config}"
KIT_CONFIG="$SCRIPT_DIR/../../../scripts/kit-config.sh"
if [ ! -f "$CONFIG" ]; then
  echo "CODEX-LENS: FAILED (non-blocking, investigate): config not found at $CONFIG"
  exit 0
fi
# shellcheck disable=SC1090
. "$CONFIG"

PROMPT_TEMPLATE="${CODEX_LENS_PROMPT:-$SCRIPT_DIR/../codex-lens.prompt.md}"
if [ ! -f "$PROMPT_TEMPLATE" ]; then
  echo "CODEX-LENS: FAILED (non-blocking, investigate): prompt not found at $PROMPT_TEMPLATE"
  exit 0
fi
SCHEMA="${CODEX_LENS_SCHEMA:-$SCRIPT_DIR/../codex-lens.schema.json}"
if [ ! -f "$SCHEMA" ]; then
  echo "CODEX-LENS: FAILED (non-blocking, investigate): schema not found at $SCHEMA"
  exit 0
fi

# The config HARD-assigns the sandbox (plain `=`), so sourcing it above already overwrote any
# pre-set CODEX_LENS_SANDBOX env var. Model and effort are settings: CODEX_LENS_MODEL /
# CODEX_LENS_EFFORT carry the values the skill passes, resolved through kit-config.sh. A blank
# model leaves Codex on its own configured default.
if [ ! -r "$KIT_CONFIG" ]; then
  echo "CODEX-LENS: FAILED (non-blocking, investigate): settings resolver not found at $KIT_CONFIG"
  exit 0
fi
# shellcheck source=../../../scripts/kit-config.sh
. "$KIT_CONFIG"
MODEL="$(kit_config codex_model "${CODEX_LENS_MODEL:-}")"
EFFORT="$(kit_config codex_effort "${CODEX_LENS_EFFORT:-}")"
: "${EFFORT:=high}"
SANDBOX="${CODEX_LENS_SANDBOX:-}"
# A review never writes. Reject anything but read-only, so a mis-edited config can never make this
# lens write-capable — the read-only contract is enforced in code, not just documented.
if [ "$SANDBOX" != "read-only" ]; then
  echo "CODEX-LENS: FAILED (non-blocking, investigate): sandbox must be read-only (a review never writes); got '$SANDBOX' from $CONFIG"
  exit 0
fi

# Resolve the committed review range against a tip pinned once, so a commit landing mid-run
# cannot skew it. Callers pass a base ref (review-panel passes a merge-base); compute the
# merge-base ourselves so a plain branch name also reviews only what BASE..HEAD introduced.
# A bad --base fails here (not a skip).
if ! TIP=$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null); then
  echo "CODEX-LENS: FAILED (non-blocking, investigate): cannot resolve HEAD to a commit"
  exit 0
fi
if ! MB=$(git merge-base "$BASE" "$TIP" 2>/dev/null); then
  echo "CODEX-LENS: FAILED (non-blocking, investigate): cannot resolve merge-base of '$BASE' and HEAD (bad --base?)"
  exit 0
fi
RANGE="$MB..$TIP"

tmpdir=$(mktemp -d); chmod 700 "$tmpdir"
cout="$tmpdir/stdout"; cerr="$tmpdir/stderr"; lastmsg="$tmpdir/last-message"; pfile="$tmpdir/prompt"
diff_file="$tmpdir/branch.diff"; gerr="$tmpdir/git-stderr"
# Kill the child on EXIT too, not just in the TERM/INT traps: a signal in the window between
# launching `codex exec &` below and installing those traps would otherwise let the parent die
# (running this EXIT trap) while codex keeps running orphaned. ${cpid:-} is empty until launch
# (harmless no-op) and already-reaped on the normal path (also a no-op).
trap 'kill "${cpid:-}" "${wpid:-}" 2>/dev/null; rm -rf "${tmpdir:-}"' EXIT

# Collect the review input. Any git failure is FAILED: a swallowed error would hand Codex an
# empty diff and read as a clean review.
git_failed() { printf 'CODEX-LENS: FAILED (non-blocking, investigate): could not collect %s:\n%s\n' "$1" "$(cat "$gerr")"; exit 0; }
git diff --no-ext-diff --submodule=diff "$RANGE" > "$diff_file" 2>"$gerr" || git_failed "the branch diff"
changed_files=$(git diff --name-only "$RANGE" 2>"$gerr") || git_failed "the changed files"
commit_log=$(git log --oneline --decorate "$RANGE" 2>"$gerr") || git_failed "the commit log"
diff_stat=$(git diff --stat "$RANGE" 2>"$gerr") || git_failed "the diff stat"
file_count=$(printf '%s\n' "$changed_files" | grep -c . || true)
if [ "${file_count:-0}" -eq 0 ]; then
  echo "CODEX-LENS: SKIPPED empty range: $RANGE changes no file (nothing to review)"
  exit 0
fi
diff_bytes=$(wc -c < "$diff_file" | tr -d ' ')

# The snapshot Codex runs in: the tracked files at the pinned tip.
review_root="$tmpdir/repo"; mkdir -p "$review_root"
if ! git archive --format=tar -o "$tmpdir/repo.tar" "$TIP" 2>"$gerr" \
  || ! tar -xf "$tmpdir/repo.tar" -C "$review_root" 2>>"$gerr"; then
  git_failed "a review snapshot"
fi
rm -f "$tmpdir/repo.tar"

# Inline vs file: embed the full patch for a diff within the caps; past either cap, carry only
# log + diffstat + changed files and point the model at the complete patch file — keeps a huge
# diff from blowing the context while still reviewing all of it.
: "${CODEX_LENS_MAX_INLINE_FILES:=50}"
: "${CODEX_LENS_MAX_INLINE_DIFF_BYTES:=262144}"
if [ "${file_count:-0}" -le "$CODEX_LENS_MAX_INLINE_FILES" ] && [ "${diff_bytes:-0}" -le "$CODEX_LENS_MAX_INLINE_DIFF_BYTES" ]; then
  collection_guidance="Use the repository context below as primary evidence. The working directory is a snapshot of the reviewed tip."
  review_input=$(printf '## Commit Log\n```\n%s\n```\n\n## Diff Stat\n```\n%s\n```\n\n## Branch Diff\n```\n%s\n```\n' \
    "$commit_log" "$diff_stat" "$(cat "$diff_file")")
else
  collection_guidance="The repository context below is a lightweight summary. The complete patch is in $diff_file: read it from beginning to end, paging when needed, before finalizing findings. The working directory is a snapshot of the reviewed tip."
  review_input=$(printf '## Commit Log\n```\n%s\n```\n\n## Diff Stat\n```\n%s\n```\n\n## Changed Files\n```\n%s\n```\n' \
    "$commit_log" "$diff_stat" "$changed_files")
fi

user_focus="No extra focus provided."
[ -n "$FOCUS" ] && user_focus="$FOCUS"

# Interpolate the template by splicing around each token. `${var//pat/$rep}` is not safe here:
# on bash 5.2 and later (patsub_replacement) an `&` in the replacement means the matched text,
# and the focus text and the diff are full of `&&`. Replace REVIEW_INPUT last so diff bytes that
# happen to look like a placeholder are never re-substituted.
replace_token() {  # replace_token <text> <token> <replacement>: every occurrence, literally
  local text="$1" token="$2" rep="$3" out=""
  while :; do
    case "$text" in
      *"$token"*) out="$out${text%%"$token"*}$rep"; text=${text#*"$token"} ;;
      *) printf '%s' "$out$text"; return 0 ;;
    esac
  done
}
prompt=$(cat "$PROMPT_TEMPLATE")
prompt=$(replace_token "$prompt" '{{TARGET_LABEL}}' "branch diff against $BASE")
prompt=$(replace_token "$prompt" '{{USER_FOCUS}}' "$user_focus")
prompt=$(replace_token "$prompt" '{{REVIEW_COLLECTION_GUIDANCE}}' "$collection_guidance")
prompt=$(replace_token "$prompt" '{{REVIEW_INPUT}}' "$review_input")
printf '%s' "$prompt" > "$pfile"

model_args=()
[ -n "$MODEL" ] && model_args=( -c "model=$MODEL" )

# Run codex exec in the BACKGROUND and `wait` on it (not a foreground call) so a hung run can be
# interrupted two ways: a caller's TERM/INT (trapped below) and the self-imposed watchdog. A
# foreground call would block until the run returned — never, if it hangs — so neither the trap
# nor the EXIT cleanup would ever run.
# --output-schema pins the final-message shape. The ${arr[@]+...} form is bash-3.2 + set-u safe
# on an empty array (macOS default shell).
codex exec \
  ${model_args[@]+"${model_args[@]}"} \
  -c model_reasoning_effort="$EFFORT" \
  -s "$SANDBOX" \
  -C "$review_root" --skip-git-repo-check \
  --output-schema "$SCHEMA" \
  -o "$lastmsg" \
  - >"$cout" 2>"$cerr" <"$pfile" &
cpid=$!

# Trap the moment the child exists — before the watchdog fork below — so a caller signal landing in
# that gap still reaps it. ${wpid:-} is set-u-safe: the watchdog pid may not be set yet.
trap 'kill "$cpid" "${wpid:-}" 2>/dev/null; exit 143' TERM
trap 'kill "$cpid" "${wpid:-}" 2>/dev/null; exit 130' INT

# Self-imposed wall-clock cap. The documented invocation is an unattended background task that nothing
# signals, so a run that never returns would `wait` forever and wedge the task. This watchdog kills the
# run once the cap elapses and drops a marker, so `wait` returns and the lens degrades to FAILED instead
# of hanging. It polls (not one long sleep) so it self-exits the instant the run finishes. Portable to
# macOS bash-3.2 (no coreutils `timeout`). Override with CODEX_LENS_TIMEOUT (seconds).
cap="${CODEX_LENS_TIMEOUT:-900}"
case "$cap" in ''|*[!0-9]*) cap=900 ;; esac    # non-integer/empty -> default (else `[ -lt ]` errors -> instant FAIL)
[ "${#cap}" -gt 8 ] && cap=900                  # >8 digits overflows int64 -> `[ -lt ]` errors; clamp by LENGTH before any numeric compare
[ "$cap" -lt 1 ] && cap=900                     # 0 -> default (a bare `[ 0 -lt 0 ]` would instant-FAIL, not disable)
( waited=0
  while [ "$waited" -lt "$cap" ]; do
    kill -0 "$cpid" 2>/dev/null || exit 0    # run finished -> nothing to cap
    sleep 1; waited=$((waited + 1))
  done
  kill -0 "$cpid" 2>/dev/null || exit 0      # finished during the final sleep -> not a timeout, don't mislabel/kill
  : >"$cout.timedout"                        # marker: written only past the liveness re-check
  kill "$cpid" 2>/dev/null                   # TERM the wedged run
  # Escalate to SIGKILL only if it survives a short grace — POLL for death, not a blind sleep, so we
  # exit the instant TERM works (node honors TERM) and don't block the parent's `wait` on a fixed sleep.
  grace=0
  while [ "$grace" -lt 3 ]; do
    kill -0 "$cpid" 2>/dev/null || exit 0    # died on TERM -> done
    sleep 1; grace=$((grace + 1))
  done
  kill -9 "$cpid" 2>/dev/null ) &            # last resort for a TERM-deaf run
wpid=$!
# 2>/dev/null: when the watchdog SIGKILLs a TERM-deaf run, bash would print an async "Killed: 9 …"
# job notice to stderr — noise ahead of our leading status token. Suppressing it keeps the token
# leading; rc is unaffected.
wait "$cpid" 2>/dev/null; rc=$?
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null   # stop the watchdog if the run won the race
out=$(cat "$cout" 2>/dev/null)
err=$(cat "$cerr" 2>/dev/null)
final=$(cat "$lastmsg" 2>/dev/null)
timedout=""; [ -f "$cout.timedout" ] && timedout=1

# A run that finished in the ~1s window between the watchdog's liveness check and its marker write
# is genuinely done (rc 0 with a captured final message) even though the marker was set — report its
# FINDINGS rather than discarding a valid review as a timeout. A real timeout leaves rc!=0 / no final.
# FINDINGS is only ever the final message: stdout and stderr are shown for a failure, never
# relabelled as findings.
if [ -n "$timedout" ] && { [ "$rc" -ne 0 ] || [ -z "$final" ]; }; then
  printf 'CODEX-LENS: FAILED (non-blocking, investigate — not a clean verdict): timed out after %ss (CODEX_LENS_TIMEOUT); partial output follows:\n%s\n%s\n' "$cap" "$out" "$err"
elif [ "$rc" -eq 0 ] && [ -n "$final" ]; then
  # The final message must match the output schema; anything else is not a review.
  problems=$(printf '%s' "$final" | jq -r --argjson schema "$(cat "$SCHEMA")" -f "$SCRIPT_DIR/../schema-check.jq" 2>&1) \
    || problems="not JSON: $problems"
  if [ -z "$problems" ]; then
    printf 'CODEX-LENS: FINDINGS\n%s\n' "$final"
  else
    printf 'CODEX-LENS: FAILED (non-blocking, investigate — not a clean verdict): the final message does not match the output schema:\n%s\nfinal message:\n%s\n' "$problems" "$final"
  fi
elif [ "$rc" -eq 0 ]; then
  printf 'CODEX-LENS: FAILED (non-blocking, investigate — not a clean verdict): codex exited 0 with no final message; output follows:\n%s\n%s\n' "$out" "$err"
else
  printf 'CODEX-LENS: FAILED (non-blocking, investigate — not a clean verdict):\n%s\n%s\n' "$out" "$err"
fi
exit 0
