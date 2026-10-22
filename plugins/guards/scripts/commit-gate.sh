#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# PreToolUse hook: commit gate.
# Blocks `git commit` when the command in the commit_gate setting fails. A blank
# setting (the default) turns the gate off. The command runs from the repo root
# with `sh -c`; its exit status decides (0 allows, anything else blocks), and the
# tail of its output is shown with the block.
#
# Worktree-aware: scopes to the git repo where the commit actually runs — its
# `git -C <dir>`, else a leading `cd <dir>` target (inline-cd worktree commit), else
# the bash tool's `cwd`, else the process cwd — falling back to CLAUDE_PROJECT_DIR.
# The Bash tool reports the SESSION cwd, so an inline `cd <wt> && git commit`
# would otherwise run this DENY gate against the MAIN checkout and let the
# worktree's failures through.

set -euo pipefail

INPUT=$(cat)

# Cheap pre-filter: no "commit" and no "git" anywhere means no commit to gate (an alias such
# as `git ci` names no "commit").
case "$INPUT" in *commit*|*git*) ;; *) exit 0 ;; esac

# Shared libs resolve relative to this script, never the runtime cwd. Fail CLOSED:
# without them the gate cannot classify the command or resolve the repo, so a
# payload that mentions "commit" is blocked (exit 2) rather than let through.
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HOOK_LIB="$_HOOK_DIR/lib/cwd-resolve.sh"
if [ ! -r "$_HOOK_LIB" ] || [ ! -r "$_HOOK_DIR/kit-config.sh" ] || [ ! -r "$_HOOK_DIR/lib/deadline.sh" ]; then
  case "$INPUT" in *commit*) ;; *) exit 0 ;; esac
  echo "commit gate: cwd-resolve.sh, deadline.sh or kit-config.sh missing ($_HOOK_DIR) — blocking commit." >&2
  exit 2
fi
# shellcheck source=lib/cwd-resolve.sh
. "$_HOOK_LIB"
# shellcheck source=kit-config.sh
. "$_HOOK_DIR/kit-config.sh"
# shellcheck source=lib/deadline.sh
. "$_HOOK_DIR/lib/deadline.sh"

# jq parses the payload. Without it the command is read with a plain pattern, and a
# commit is blocked with a reason: exit 127 from a missing tool would be a
# non-blocking error, which lets the commit through.
if command -v jq >/dev/null 2>&1; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
  TOOL_CWD=$(tool_cwd "$INPUT")
else
  COMMAND=$(printf '%s' "$INPUT" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p')
  read -r found _ < <(find_git_sub "$COMMAND" commit "")
  [ "$found" = 1 ] || exit 0
  echo "commit gate: jq is not installed, so the gate cannot read this commit — commit blocked. Install jq." >&2
  exit 2
fi

# Only gate a real `git commit`: the first word of a simple command, after any
# assignments, wrappers or git global options (`git -C <dir> commit` and
# `git -c k=v commit` count). `echo "git commit ..."`, `git commit-graph` and
# `git log --grep commit` are not commits.
BASE_DIR=$(leading_cd_dir "$COMMAND" "$TOOL_CWD")
[ -n "$BASE_DIR" ] || BASE_DIR=$TOOL_CWD
read -r found GIT_DIR_ARG < <(find_git_sub "$COMMAND" commit "$BASE_DIR")
[ "$found" = 1 ] || exit 0

# Resolve the repo in order: the commit's own `git -C <dir>`, the leading `cd <dir>`
# target (the inline-cd worktree commit the Bash tool reports against the main cwd),
# the tool cwd, then the process cwd. Empty -> fall back to CLAUDE_PROJECT_DIR.
PROJECT_DIR=""
[ -z "$GIT_DIR_ARG" ] || PROJECT_DIR=$(git_toplevel "$GIT_DIR_ARG")
[ -n "$PROJECT_DIR" ] || PROJECT_DIR=$(git_toplevel "$(leading_cd_dir "$COMMAND" "$TOOL_CWD")")
[ -n "$PROJECT_DIR" ] || PROJECT_DIR=$(git_toplevel "$TOOL_CWD")
[ -n "$PROJECT_DIR" ] || PROJECT_DIR=$(git_toplevel "$(pwd)")
[ -n "$PROJECT_DIR" ] || PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
cd "$PROJECT_DIR"

# A repo settings file that does not parse could hide the gate setting: block, with the reason.
if ! kit_config_file_ok 2>/dev/null; then
  echo "commit gate: .agentic-workflow-kit.json in $PROJECT_DIR is not valid JSON, so the commit_gate setting cannot be read — commit blocked. Fix the file." >&2
  exit 2
fi
GATE=$(kit_config commit_gate)
[ -n "$GATE" ] || exit 0

# The gate runs under its own deadline (commit_gate_timeout, below the hook's 600-second
# timeout): a hook that times out does not block, so a slow gate must not run past it.
CAP=$(deadline_cap "$(kit_config commit_gate_timeout)")
OUTFILE=$(mktemp)
trap 'rm -f "$OUTFILE"' EXIT
rc=0; run_with_deadline "$CAP" "$OUTFILE" sh -c "$GATE" || rc=$?
OUTPUT=$(cat "$OUTFILE")
if [ "$rc" -eq 124 ]; then
  echo "Commit gate timed out after ${CAP}s; speed up the check, or raise commit_gate_timeout up to $DEADLINE_MAX — commit blocked." >&2
  echo "  command: $GATE" >&2
  printf '%s\n' "$OUTPUT" | tail -n 20 >&2
  exit 2
fi
if [ "$rc" -ne 0 ]; then
  echo "Commit gate failed — commit blocked." >&2
  echo "  command: $GATE" >&2
  echo "" >&2
  printf '%s\n' "$OUTPUT" | tail -n 40 >&2
  echo "" >&2
  echo "Fix the failure above, then commit again." >&2
  exit 2
fi

exit 0
