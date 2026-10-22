#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# PostToolUse hook: PR Description Drift Check
#
# After Claude runs a `git push`, if the current branch has an open PR and its
# body was last edited BEFORE the most recent commit, emit a PASSIVE reminder
# (additionalContext) that Claude folds into its end-of-flow finalize — refresh
# the PR body at the next natural checkpoint (before mark-ready / handoff). It
# never asks a question. The reminder is non-blocking, and Claude may refresh the
# body directly.
#
# The detection (PR lookup, body-edit time, dedup) is shared with the git
# pre-push sibling via pr-drift-lib.sh; this script owns only the Claude trigger
# guard and the JSON output format.
#
# Silent when: command wasn't git push, gh not installed / not authenticated,
# not on a git branch, on the base branch, no open PR for the branch, no drift,
# or already reminded for this (PR, body-version) — so it fires at most once per
# stale body-version, not on every commit.

set -euo pipefail

# Advisory hook: without jq it cannot read the payload or build its reply, so it
# stays silent rather than exit non-zero (shown to the user as a hook error).
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

# Only a real `git push` counts: one that starts a simple command (lib/cwd-resolve.sh), so
# `echo "remember to git push later"` does not. The check then runs in the repo the push ran
# in: its `git -C <dir>`, else a leading `cd <dir>`, else the tool's working directory.
SEG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/cwd-resolve.sh"
[ -r "$SEG" ] || exit 0
# shellcheck source=lib/cwd-resolve.sh
. "$SEG"
TOOL_CWD=$(tool_cwd "$INPUT")
BASE=$(leading_cd_dir "$COMMAND" "$TOOL_CWD"); [ -n "$BASE" ] || BASE=$TOOL_CWD
read -r found push_dir < <(find_git_sub "$COMMAND" push "$BASE")
[ "$found" = 1 ] || exit 0
TARGET=$(git_toplevel "${push_dir:-${BASE:-.}}")
[ -z "$TARGET" ] || cd "$TARGET"

# Skip dry-runs — no commits were actually published, so there's nothing to nudge about.
if echo "$COMMAND" | grep -q -- '--dry-run'; then
  exit 0
fi

# Locate the shared detection library beside this script (inside the plugin), never
# through the repo or a git env override. Source defensively: a missing or broken
# lib makes the hook a silent no-op, never a non-zero exit that disrupts the tool
# result.
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-drift-lib.sh"
[ -f "$LIB" ] || exit 0
# Parse-check before sourcing: a truncated/corrupt lib is a no-op, never a
# non-zero exit (a syntax error in `. "$LIB"` is NOT catchable with `|| exit 0`).
bash -n "$LIB" 2>/dev/null || exit 0
# shellcheck source=pr-drift-lib.sh
. "$LIB"
# shellcheck source=kit-config.sh
. "$(dirname "$LIB")/kit-config.sh" 2>/dev/null || true

# gh probe. 1 = not installed (silent); 2 = installed but not authenticated
# (warn once/day so the user knows the hook is inert, then exit).
gh_rc=0
pr_drift_gh_status || gh_rc=$?
case "$gh_rc" in
  1) exit 0 ;;
  2)
    if pr_drift_should_warn_auth; then
      jq -n '{
        systemMessage: "PR drift hook inert — gh CLI not authenticated.",
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          additionalContext: "The PR description drift hook is inert because `gh` is installed but not authenticated. Run `gh auth login` once to enable drift detection. This warning prints at most once per day."
        }
      }'
    fi
    exit 0
    ;;
esac

# No drift (or no PR / already nudged) → nothing to say.
pr_drift_detect || exit 0

MSG="Passive reminder (no action required right now, do NOT stop to ask the user): PR #${PR_DRIFT_NUMBER}'s description was last edited before the latest commit (body ${PR_DRIFT_BODY_EDITED}; latest commit ${PR_DRIFT_LAST_COMMIT_ISO}), so it may be stale. Do not rewrite the body on every push. At your next natural checkpoint for this PR — before you mark it ready or hand off — refresh the description so it reflects the final state. If the current body was clearly hand-written by a human (curated prose or screenshots/media you did not author), confirm before a holistic rewrite; otherwise refresh it directly — an agent-authored body needs no confirmation.

When you do refresh, follow the \`/ship:pr-communication\` skill — its pr-template.md is the single source for the PR description format; don't invent your own sections. Two hook-specific notes the skill doesn't cover:
1. Read the current body first (\`gh pr view ${PR_DRIFT_NUMBER} --json body --jq .body\`) and treat it as a HOLISTIC REFRESH so the description reflects current state — NOT an append-only changelog of new commits. Preserve every existing image/screenshot/video element.
2. Write the new body to a tempfile (e.g. with the Write tool) and apply via \`gh pr edit ${PR_DRIFT_NUMBER} --body-file <tempfile>\` — never inline \`--body \"...\"\`, since backticks/quotes in long bodies break shell escaping."
jq -n --arg m "$MSG" '{
  systemMessage: "PR description may be stale — passive reminder, refresh at handoff.",
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $m
  }
}'

exit 0
