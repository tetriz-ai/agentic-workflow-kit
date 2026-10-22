#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# PreToolUse hook: lockfile sync gate.
# Blocks `git commit` when a package.json the commit records leaves its lockfile out of sync.
#
# For each such package.json (at any depth: staged, or also unstaged for `-a` and pathspec
# commits), the gate finds the nearest lockfile in
# that folder or an ancestor up to the repo root, and regenerates it without
# installing packages:
#   pnpm-lock.yaml     pnpm install --lockfile-only
#   package-lock.json  npm install --package-lock-only --ignore-scripts
#   yarn.lock          yarn install --mode=update-lockfile   (Yarn 2 and later;
#                      Yarn 1 has no lockfile-only mode, so it is skipped with a note)
# If the regenerated lockfile differs from the index, the commit is blocked and the
# refreshed file is left in place to stage. A package manager that is present and fails
# blocks the commit with its output. A missing package manager is not a block: the gate
# says so on stderr and lets the commit through, since it cannot run the check at all.
#
# The working copy of each lockfile is snapshotted before regenerating and put back
# afterwards, except for a drifted lockfile that had no unstaged changes. So a hand
# edit to the lockfile is never lost: with one present and drift found, the commit
# is blocked and the edit is kept for the developer to reconcile.
#
# Worktree-aware: resolves the git repo from the commit's `git -C <dir>`, else the
# leading `cd <dir>` target (an inline-cd worktree commit), else the bash tool's cwd,
# else the process cwd, falling back to CLAUDE_PROJECT_DIR, the same order as
# commit-gate.sh.

set -euo pipefail

INPUT=$(cat)

# Cheap pre-filter: no "commit" and no "git" anywhere means no commit to gate (an alias such
# as `git ci` names no "commit").
case "$INPUT" in *commit*|*git*) ;; *) exit 0 ;; esac

# Worktree-aware cwd resolution and the commit classifier (git_toplevel,
# leading_cd_dir, find_git_sub), shared with review-cadence and the commit gate.
# Resolve relative to this script, never the runtime cwd. Fail CLOSED: a missing
# lib means the gate cannot classify or resolve, so block (exit 2).
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HOOK_LIB="$_HOOK_DIR/lib/cwd-resolve.sh"
if [ ! -r "$_HOOK_LIB" ] || [ ! -r "$_HOOK_DIR/lib/deadline.sh" ] || [ ! -r "$_HOOK_DIR/kit-config.sh" ]; then
  case "$INPUT" in *commit*) ;; *) exit 0 ;; esac
  echo "lockfile gate: cwd-resolve.sh, deadline.sh or kit-config.sh missing ($_HOOK_DIR) — blocking commit." >&2
  exit 2
fi
# shellcheck source=lib/cwd-resolve.sh
. "$_HOOK_LIB"
# shellcheck source=lib/deadline.sh
. "$_HOOK_DIR/lib/deadline.sh"
# shellcheck source=kit-config.sh
. "$_HOOK_DIR/kit-config.sh"

# jq parses the payload. Without it, a commit is blocked with a reason (exit 127
# from a missing tool would be a non-blocking error, which lets the commit through).
if command -v jq >/dev/null 2>&1; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
  TOOL_CWD=$(tool_cwd "$INPUT")
else
  COMMAND=$(printf '%s' "$INPUT" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p')
  read -r found _ < <(find_git_sub "$COMMAND" commit "")
  [ "$found" = 1 ] || exit 0
  echo "lockfile gate: jq is not installed, so the gate cannot read this commit — commit blocked. Install jq." >&2
  exit 2
fi

# Only gate a real `git commit` (same classifier as commit-gate.sh).
BASE_DIR=$(leading_cd_dir "$COMMAND" "$TOOL_CWD")
[ -n "$BASE_DIR" ] || BASE_DIR=$TOOL_CWD
read -r found GIT_DIR_ARG < <(find_git_sub "$COMMAND" commit "$BASE_DIR")
[ "$found" = 1 ] || exit 0

PROJECT_DIR=""
[ -z "$GIT_DIR_ARG" ] || PROJECT_DIR=$(git_toplevel "$GIT_DIR_ARG")
[ -n "$PROJECT_DIR" ] || PROJECT_DIR=$(git_toplevel "$(leading_cd_dir "$COMMAND" "$TOOL_CWD")")
[ -n "$PROJECT_DIR" ] || PROJECT_DIR=$(git_toplevel "$TOOL_CWD")
[ -n "$PROJECT_DIR" ] || PROJECT_DIR=$(git_toplevel "$(pwd)")
[ -n "$PROJECT_DIR" ] || PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
cd "$PROJECT_DIR"

SNAP_DIR=$(mktemp -d)
trap 'rm -rf "$SNAP_DIR"' EXIT

# nearest_lockfile <dir>: the first lockfile in <dir> or an ancestor up to the repo
# root, as a repo-relative path; empty when none.
nearest_lockfile() {
  local d="$1" f
  while :; do
    for f in pnpm-lock.yaml package-lock.json yarn.lock; do
      if [ -f "$d/$f" ]; then
        if [ "$d" = "." ]; then printf '%s' "$f"; else printf '%s/%s' "$d" "$f"; fi
        return 0
      fi
    done
    [ "$d" = "." ] && return 0
    d=$(dirname "$d")
  done
}

# commit_takes_worktree <command>: succeeds when the commit records working-tree changes
# beyond the index: `-a`/`--all` (also inside a short cluster such as `-am`), `-i`/`--include`,
# `-o`/`--only`, `--pathspec-from-file`, or a pathspec. Quoted text (the message) is set aside
# first, and the arguments of options that take one are skipped.
commit_takes_worktree() {
  local rest tok skip=0 after_dashdash=0
  local -a toks=()
  rest=$(printf '%s' "$1" | tr -d '\\' | sed -E "s/\"[^\"]*\"/Q/g; s/'[^']*'/Q/g")
  rest=$(printf '%s\n' "$rest" | tr ';&|(){}`' '\n\n\n\n\n\n\n\n' \
    | sed -nE 's/^(.*[[:space:]])?commit([[:space:]]+(.*))?$/\3/p' | head -1)
  read -r -a toks <<<"$rest"
  for tok in ${toks[@]+"${toks[@]}"}; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    if [ "$after_dashdash" = 1 ]; then return 0; fi
    case "$tok" in
      --) after_dashdash=1 ;;
      --all|--include|--only|--pathspec-from-file*) return 0 ;;
      -m|-F|-C|-c|-t|--author|--date|--template|--file|--fixup|--squash|--cleanup|--trailer|--reuse-message|--reedit-message) skip=1 ;;
      --*) ;;
      -*)
        case "$tok" in -*[aio]*) return 0 ;; esac
        case "$tok" in *[mFCct]) skip=1 ;; esac ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# The package.json files this commit records: the index, or every change against HEAD when the
# commit also takes working-tree changes. NUL-separated, so no path is quoted or escaped.
changed_files() {
  if commit_takes_worktree "$COMMAND" && git rev-parse -q --verify HEAD >/dev/null 2>&1; then
    git diff HEAD --name-only -z
  else
    git diff --cached --name-only -z
  fi
}

LOCKFILES=""
while IFS= read -r -d '' pkg; do
  case "$pkg" in package.json|*/package.json) ;; *) continue ;; esac
  lock=$(nearest_lockfile "$(dirname "$pkg")")
  [ -n "$lock" ] || continue
  case $'\n'"$LOCKFILES"$'\n' in *$'\n'"$lock"$'\n'*) ;; *) LOCKFILES="${LOCKFILES:+$LOCKFILES$'\n'}$lock" ;; esac
done < <(changed_files)
[ -n "$LOCKFILES" ] || exit 0

drifted=""
kept=""
n=0
# One deadline covers every lockfile in the commit: each package manager run gets the time left.
CAP=$(deadline_cap "$(kit_config commit_gate_timeout)")
END=$((SECONDS + CAP))
timed_out() {
  echo "lockfile gate: $1 timed out after ${CAP}s in all; speed up the check, or raise commit_gate_timeout up to $DEADLINE_MAX — commit blocked." >&2
}
while IFS= read -r lock; do
  dir=$(dirname "$lock")
  case "$(basename "$lock")" in
    pnpm-lock.yaml)    tool=pnpm; args=(install --lockfile-only) ;;
    package-lock.json) tool=npm;  args=(install --package-lock-only --ignore-scripts) ;;
    yarn.lock)
      tool=yarn; args=(install --mode=update-lockfile)
      if command -v yarn >/dev/null 2>&1; then
        # The version check shares the deadline: a `yarn --version` that hangs blocks in time.
        left=$((END - SECONDS))
        if [ "$left" -lt 1 ]; then timed_out yarn; exit 2; fi
        yrc=0; run_with_deadline "$left" "$SNAP_DIR/yarn-version" sh -c 'cd "$1" && exec yarn --version 2>/dev/null' _ "$dir" || yrc=$?
        if [ "$yrc" -eq 124 ]; then timed_out yarn; exit 2; fi
        case "$(cat "$SNAP_DIR/yarn-version" 2>/dev/null)" in
          1.*) echo "lockfile gate: $lock is Yarn 1, which has no lockfile-only mode — not checked." >&2; continue ;;
        esac
      fi
      ;;
  esac
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "lockfile gate: $tool not installed — $lock not checked." >&2
    continue
  fi
  # Snapshot the working copy, and note whether it already differs from the index
  # (an unstaged edit, which must survive the regeneration).
  n=$((n + 1)); snap="$SNAP_DIR/$n"
  cp -p "$lock" "$snap"
  had_edit=0
  git diff --quiet -- "$lock" 2>/dev/null || had_edit=1
  # A tool that is present and fails blocks the commit with its output: the lockfile cannot be
  # verified. It runs under the commit_gate_timeout deadline, below the hook's own timeout.
  left=$((END - SECONDS))
  if [ "$left" -lt 1 ]; then cp -p "$snap" "$lock"; timed_out "$tool"; exit 2; fi
  trc=0; run_with_deadline "$left" "$SNAP_DIR/out" sh -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$tool" "${args[@]}" || trc=$?
  if [ "$trc" -ne 0 ]; then
    cp -p "$snap" "$lock"  # put back the working copy, including any unstaged edit
    if [ "$trc" -eq 124 ]; then
      timed_out "$tool"
    else
      echo "lockfile gate: $tool ${args[*]} failed in $dir, so $lock cannot be verified — commit blocked." >&2
    fi
    tail -20 "$SNAP_DIR/out" >&2
    exit 2
  fi
  if git diff --quiet -- "$lock" 2>/dev/null; then
    cp -p "$snap" "$lock"  # no drift: put back the working copy as it was
  else
    drifted="${drifted:+$drifted }$lock"
    if [ "$had_edit" = 1 ]; then
      cp -p "$snap" "$lock"  # keep the hand edit rather than overwrite it
      kept="${kept:+$kept }$lock"
    fi
  fi
done <<<"$LOCKFILES"

if [ -n "$drifted" ]; then
  echo "Lockfile out of sync with a staged package.json — commit blocked." >&2
  echo "" >&2
  if [ -n "$kept" ]; then
    echo "These lockfiles have unstaged edits, which the gate left in place: $kept" >&2
    echo "Reconcile them with your package manager's lockfile-only install, then stage." >&2
  fi
  refreshed=""
  for l in $drifted; do case " $kept " in *" $l "*) ;; *) refreshed="${refreshed:+$refreshed }$l" ;; esac; done
  if [ -n "$refreshed" ]; then
    echo "The lockfile has already been refreshed — stage it and commit again:" >&2
    echo "  git add $refreshed" >&2
  fi
  exit 2  # A refreshed lockfile stays dirty: the developer stages it.
fi
exit 0
