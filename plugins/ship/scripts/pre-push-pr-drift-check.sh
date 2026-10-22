#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Git pre-push hook: PR Description Drift Reminder
#
# Mirrors the Claude Code PostToolUse drift hook but for pushes that Claude
# never observes — terminal `git push`, IDE/GUI pushes, wrapper scripts like
# `make deploy` that internally invoke `git push`, etc. Output goes to stderr
# (visible in the terminal); the hook NEVER blocks the push.
#
# Detection (PR lookup, body-edit time, dedup) is shared with the PostToolUse
# sibling via pr-drift-lib.sh; this script owns only the in-session guard and
# the stderr output format.
#
# Stays silent when running inside a Claude Code session (CLAUDE_CODE_ENTRYPOINT
# is set) — those pushes are handled by the PostToolUse hook's passive reminder.
# This keeps the two hooks from double-nudging.
#
# Install: the starter plugin's `githooks/pre-push` wrapper calls this script;
# `/starter:setup` writes it to the repo's hooks directory. The shared library is
# resolved beside this script, so it is found wherever the hook is installed.

set -euo pipefail

# When invoked from a Claude-spawned shell, defer to the PostToolUse hook.
# Notes: this also silences `!`-prefix shell-outs from inside Claude Code,
# since they inherit the env. Pushes from a fresh terminal / IDE / GUI do
# NOT have this var set and proceed normally.
[ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] && exit 0

# git invokes pre-push with refspecs on stdin, but we don't need them — the
# drift check compares HEAD's commit time to the PR body's edit time, which
# is what reviewers actually see. Drain stdin so git doesn't see SIGPIPE.
cat >/dev/null 2>&1 || true

# Locate the shared detection library beside this script (inside the plugin).
# Source defensively: a missing or broken lib must leave the push untouched (this
# hook never blocks), so any failure collapses to a silent exit 0.
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-drift-lib.sh"
[ -f "$LIB" ] || exit 0
# Parse-check before sourcing: a truncated/corrupt lib must leave the push
# untouched (a syntax error in `. "$LIB"` is NOT catchable with `|| exit 0`).
bash -n "$LIB" 2>/dev/null || exit 0
# shellcheck source=pr-drift-lib.sh
. "$LIB"
# shellcheck source=kit-config.sh
. "$(dirname "$LIB")/kit-config.sh" 2>/dev/null || true

# gh probe. 1 = not installed (silent); 2 = installed but not authenticated
# (warn to stderr once/day, shared throttle with the PostToolUse hook).
gh_rc=0
pr_drift_gh_status || gh_rc=$?
case "$gh_rc" in
  1) exit 0 ;;
  2)
    if pr_drift_should_warn_auth; then
      cat >&2 <<EOM

  PR drift hook inert — \`gh\` CLI is not authenticated.
  Run \`gh auth login\` once to enable drift detection.
  (This warning prints at most once per day.)

EOM
    fi
    exit 0
    ;;
esac

# No drift (or no PR / already nudged) → say nothing, never block the push.
pr_drift_detect || exit 0

cat >&2 <<EOM

  PR description drift
  ────────────────────
  PR #${PR_DRIFT_NUMBER} body hasn't been updated since the latest commit.
  Refresh it before requesting review:
    gh pr edit ${PR_DRIFT_NUMBER}
  Or ask your coding agent for a refresh that follows the
  /ship:pr-communication template and preserves existing media.

EOM

exit 0
