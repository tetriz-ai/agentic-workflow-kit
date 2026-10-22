#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# PreToolUse(Bash) dispatcher for PR-lifecycle ADVISORY nudges.
#
# One settings.json entry, dispatched internally — a new PR-moment nudge is a
# function here, not another hook bolted onto the Bash matcher. Same idea as
# post-edit-dispatcher.sh (one entry for the PostToolUse edit checks): one shell
# startup + one jq parse + a cheap pre-filter, instead of N separate hooks each
# re-spawning and re-parsing on every Bash call.
#
# Folds in three would-be-separate nudges, all firing at the moment of the action:
#   - feedback: a partial PR-comment fetch → point at the complete /ship:pr-feedback.
#   - sync:     a `git push` → reconcile the PR title/description vs the full diff.
#   - codex:    a `gh pr create` → launch the /ship:codex-sweep background `await`.
#
# All three share one contract: advisory only (hookSpecificOutput.additionalContext),
# never block, make NO network calls (the agent acts, not the hook), always exit 0.
# That keeps the dispatcher deterministic and hook_test-safe.
#
# NOT folded in (different contracts — keep them separate):
#   - block-unpinned-npx / commit-gate / lockfile-gate (guards plugin) DENY
#     (block the call) and carry long, distinct timeouts; mixing a blocking
#     decision into this advisory aggregator is fragile.
#   - review-cadence.sh (review plugin) is git-stateful and is invoked by name
#     (`review-cadence.sh reset` from /review:review-panel), so it stays a standalone
#     callable script.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat 2>/dev/null || true)

# This plugin's root, so the nudges can name scripts by absolute path: a hook runs
# with the plugin's scripts on disk, while the agent's Bash tool has neither
# CLAUDE_PLUGIN_ROOT nor a cwd inside the plugin.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Fast pre-filter: the vast majority of Bash calls touch none of these surfaces.
# Exit before the jq parse unless the payload mentions a comment surface, a push,
# or a PR creation. (A `gh pr view` can fetch comments via the short `-c` flag
# with no "comments" substring, so match `pr view` explicitly.)
case "$INPUT" in
  *comments*|*'pr view'*|*push*|*'pr create'*|*'pr new'*) ;;
  *) exit 0 ;;
esac

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

NUDGES=()
add() { [ -n "$1" ] && NUDGES+=("$1"); }

# ── feedback: a partial single-surface comment fetch → the complete /ship:pr-feedback.
# `gh pr view --comments` / `gh api .../pulls/N/comments` return ONE surface and
# silently miss review BODIES (where Codex and review summaries post). Never nudge
# the complete graphql fetch, a write (reply/post), a single comment BY ID, a `-c`
# that belongs to a piped tool, or pr-feedback itself.
nudge_feedback() {
  printf '%s' "$CMD" | grep -q 'graphql' && return 0
  printf '%s' "$CMD" | grep -q 'pr-feedback' && return 0
  printf '%s' "$CMD" | grep -qE 'in_reply_to|--method|([[:space:]]-X[[:space:]])|body=' && return 0

  local incomplete=0
  if printf '%s' "$CMD" | grep -oE '(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+view[^|;&]*' \
     | grep -qE '(^|[[:space:]])(--comments|-c)([[:space:]=]|$)'; then incomplete=1; fi
  if printf '%s' "$CMD" | grep -qE '(^|[^[:alnum:]_-])gh[[:space:]]+api' \
     && printf '%s' "$CMD" | grep -qE '(pulls|issues)/[0-9]+/comments([^/0-9]|$)'; then incomplete=1; fi
  [ "$incomplete" = 1 ] || return 0

  add "PR-FEEDBACK: this fetches only a PARTIAL / single comment surface. To gather ALL review feedback for triage - inline comments, review BODIES (commonly missed - where Codex and review summaries post their findings), and conversation - in one pass with thread state, run \`\"$PLUGIN_ROOT/skills/pr-feedback/pr-feedback.sh\" <PR>\` (the \`/ship:pr-feedback\` skill) instead. If this is a deliberate targeted lookup of one surface, ignore this."
}

# ── sync: a `git push` → reconcile the PR title/description vs the full diff.
# Only a `git push` that starts a simple command counts (lib/cwd-resolve.sh find_git_sub), so
# `git commit -m "push fix"` and `echo git push` do not; skip a dry-run.
nudge_sync() {
  local found
  read -r found _ < <(find_git_sub "$CMD" push "")
  [ "$found" = 1 ] || return 0
  printf '%s' "$CMD" | grep -q -- '--dry-run' && return 0

  local base
  base=$(kit_config base_branch); : "${base:=main}"
  add "PR-SYNC: pushing this branch. If it has an open PR, reconcile the PR title & description with the full branch diff (\`git log origin/$base..HEAD\`, \`git diff origin/$base...HEAD\`) before calling this done - if the scope grew past what they say, rewrite them with \`gh pr edit\` (the \`/ship:pr\` skill's 'Reconcile an existing PR' step). If nothing material changed, ignore."
}

# ── codex: a `gh pr create` → launch the /ship:codex-sweep background `await`.
# This is the deterministic backstop for /ship:pr's "Arm the Codex review sweep" step. A
# hook cannot start the background task itself (only the agent's Bash can), so it
# nudges at the moment of creation and is phrased to defeat the rationalized skip
# ("user is here / overkill") that leaves Codex's review unaddressed. PreToolUse
# fires before the PR number exists; the agent reads it from the `gh pr create`
# output it gets the same turn.
nudge_codex() {
  # `gh pr create` and its documented alias `gh pr new`, starting a simple command (after gh's
  # `-R`/`--repo` option if any); `echo "gh pr create"` is not one.
  # Quoted text (a title or body) is set aside first, so its words are not read as flags.
  local create
  create=$(simple_commands "$(printf '%s' "$CMD" | sed -E "s/\"[^\"]*\"/Q/g; s/'[^']*'/Q/g")" gh \
    | grep -E '^[^ ]+( (-R|--repo) [^ ]+| --repo=[^ ]+)* pr (create|new)( |$)' | head -1)
  [ -n "$create" ] || return 0
  # Invocations that create no PR (so there is no `/pull/<N>` to arm a sweep for), read in the
  # create command only: a help/usage lookup (--help/-h), a dry-run (--dry-run prints instead
  # of creating), and the browser flow (--web/-w opens a create page, emits no PR number).
  printf '%s' "$create" | grep -qE '(^|[[:space:]])(--help|-h|--dry-run|--web|-w)([[:space:]]|$)' && return 0

  # Self-sufficient on purpose (this fires precisely when /ship:pr was bypassed), but
  # /ship:pr steps 10-11 own the canonical contract — keep the params here minimal and
  # point there. The skip clause is falsifiable (check the conversation, not
  # memory), not a self-attestable escape hatch.
  add "CODEX-SWEEP: once this PR exists, start its Codex review sweep — conditional-mandatory, not skippable on a 'user is here / I'll check manually' basis. Launch it as a background task: Bash(command: '\"$PLUGIN_ROOT/skills/codex-sweep/codex-sweep.sh\" await <NEW_PR_NUMBER>', run_in_background: true) with the PR number from the gh output. Use that absolute path so it runs from any cwd or worktree; \$CLAUDE_PLUGIN_ROOT and \$CLAUDE_PROJECT_DIR are empty in a Bash-tool command. See \`/ship:pr\`'s 'Arm the Codex review sweep' step for the full why. It waits for Codex at zero token cost (a shell poll loop, not an LLM re-arm timer) and wakes you once with a triage whose NEXT line hands off to '/ship:codex-sweep <PR>' to address the findings. Start it exactly once; skip ONLY if a 'codex-sweep.sh await' for this PR is already visible in this conversation's tool calls (not from memory)."
}

# shellcheck source=kit-config.sh
. "$PLUGIN_ROOT/scripts/kit-config.sh" 2>/dev/null || kit_config() { :; }
# The shared command segmenter (simple_commands, find_git_sub). Advisory hook: without it, no
# sync or codex nudge.
# shellcheck source=lib/cwd-resolve.sh
. "$PLUGIN_ROOT/scripts/lib/cwd-resolve.sh" 2>/dev/null || { simple_commands() { :; }; find_git_sub() { echo 0; }; }

nudge_feedback
nudge_sync
nudge_codex

[ "${#NUDGES[@]}" -eq 0 ] && exit 0

MSG=""
for n in "${NUDGES[@]}"; do
  if [ -z "$MSG" ]; then MSG="$n"; else MSG="$MSG"$'\n\n'"$n"; fi
done
# jq -Rs slurps stdin into one string — avoids an ARG_MAX failure on a large
# merged message that --arg could hit; `|| true` keeps the exit-0 contract.
printf '%s' "$MSG" | jq -Rsc '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:.}}' || true
exit 0
