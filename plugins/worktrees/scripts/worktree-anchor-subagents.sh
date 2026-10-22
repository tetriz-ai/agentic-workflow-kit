#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# PreToolUse(Agent|Task) — guard the worktree/subagent cwd split.
#
# Root cause (Claude Code platform behaviour, not a repo bug): the EnterWorktree
# tool moves the interactive SHELL cwd into the worktree, but a subagent spawned
# via the Agent/Task tool inherits the ORIGINAL session launch dir (the main-repo
# root / CLAUDE_PROJECT_DIR), which EnterWorktree never repoints. So a subagent's
# Read/Grep/Glob resolve RELATIVE repo paths against the MAIN repo and silently
# read stale, pre-edit files — yielding confident-but-wrong analysis. Bash is
# immune because it is cwd-based via an explicit `cd`, which is exactly why the
# split hides: the obvious checks pass while reviewer subagents read the wrong tree.
#
# There is no Agent `cwd` param, no settings knob, and a hook cannot change a
# subagent's cwd. But a PreToolUse hook CAN rewrite the tool input: we AUTO-INJECT
# a worktree-anchor preamble into the subagent's prompt (verified to propagate to
# the spawned subagent) so it resolves repo paths under the worktree absolute root
# and `cd`s there for Bash. This needs nothing from the caller — unlike a deny,
# it works for Workflow-tool orchestration (agents spawned from a SCRIPT that
# can't read a deny and retry) and for non-course-correcting/weaker models, with
# no extra round-trip.
#
# updatedInput REPLACES tool_input (it is not a field-merge): emitting a bare
# {prompt} drops the Agent tool's required `description` and fails schema
# validation, so we merge the original tool_input and override only `prompt`.
#
# Scope — minimal, and inject UNCONDITIONALLY rather than guess "is this prompt
# repo-touching":
#   - only in a linked worktree (main checkout passes through);
#   - skipped when the prompt already names the worktree root (no double-inject
#     on retry — the injected preamble itself contains the root);
#   - otherwise inject. We deliberately do NOT source-detect: enumerating repo
#     paths is whack-a-mole (Makefile / go.mod / *.sh / uppercase extensions /
#     bare dir words all slip a regex → a silent stale-read, the exact failure
#     this guards), and the preamble is harmless to a non-repo agent because it
#     DEFERS to any explicit out-of-repo path the task gives. So inject always
#     and keep the wording conditional, rather than gamble on a detection regex.
#
# The decision is carried in the JSON (permissionDecision: allow + updatedInput),
# so the script always exits 0 — a non-zero exit is reserved for genuine failure.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0

CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null)
PROMPT=$(jq -r '.tool_input.prompt // empty' <<<"$INPUT" 2>/dev/null)
[ -z "$CWD" ] && exit 0
[ -z "$PROMPT" ] && exit 0

# Linked worktree? --absolute-git-dir differs from the (absolute) common dir only
# in a linked worktree; in the main checkout they are identical.
GIT_DIR=$(git -C "$CWD" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
COMMON_DIR=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
[ -z "$GIT_DIR" ] && exit 0
[ "$GIT_DIR" = "$COMMON_DIR" ] && exit 0   # main checkout — nothing to guard

WT_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -z "$WT_ROOT" ] && exit 0

# Already anchored — the prompt names the worktree root AT A PATH BOUNDARY, so
# trust the spawn. Match the root only when followed by `/`, a quote, whitespace,
# or end-of-string: a bare substring would let a sibling path that merely shares
# the root as a PREFIX (e.g. "<root>-stale/x.go") satisfy the anchor while
# pointing the subagent outside the worktree. Regex metacharacters in the root
# are escaped so a path with `.`/`[` can't widen the match.
# grep via a here-string, NOT `printf | grep -q`: under `set -o pipefail`,
# grep -q short-circuits on the first match and closes the pipe, so printf can
# take SIGPIPE and the pipeline reports failure even though grep matched — on a
# long prompt that would flip a real match to "no match" and wrongly deny an
# anchored spawn. A here-string has no upstream process to signal.
ESC_ROOT=$(printf '%s' "$WT_ROOT" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
if grep -qE "${ESC_ROOT}([/\"' ]|\$)" <<<"$PROMPT"; then
  exit 0
fi

# Auto-inject the anchor: allow the spawn, but rewrite tool_input.prompt to
# prepend the worktree directive. updatedInput REPLACES tool_input, so merge the
# original (preserving subagent_type/description/model/…) and override prompt.
TOOL_INPUT=$(jq -c '.tool_input' <<<"$INPUT" 2>/dev/null)
[ -z "$TOOL_INPUT" ] && exit 0
jq -n --arg wt "$WT_ROOT" --argjson ti "$TOOL_INPUT" '
  ($ti.prompt // "") as $orig |
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      updatedInput: ($ti + { prompt: (
        "<<WORKTREE ANCHOR — auto-injected by the worktree-anchor-subagents hook>>\n" +
        "You are operating inside the git worktree at:\n  " + $wt + "\n" +
        "A subagent inherits the MAIN-repo cwd, so for THIS REPO resolve every relative path under this worktree root for Read/Grep/Glob (prefer absolute paths beginning with it), and `cd \"" + $wt + "\"` before repo Bash/test/build — otherwise you read the stale main checkout. If this task explicitly directs you to a path OUTSIDE this repo (e.g. /tmp or another repo), that takes precedence; this anchor only governs repo-relative paths.\n\n" +
        $orig
      ) })
    }
  }'
exit 0
