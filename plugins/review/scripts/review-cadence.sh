#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# PreToolUse hook: during-coding review cadence (soft, runtime-local).
#
# Fires the soft reviewer-panel nudge every ~N commits OR ~M changed lines since
# the last panel run, before a PR is opened, and before pushing further commits
# to an already-open PR. It is ADVISORY: it NEVER blocks the commit/push and
# never runs the merge gate. It is the soft, runtime-local review layer.
#
# Mechanism: emits hookSpecificOutput.additionalContext, which PreToolUse hooks
# may return, so the nudge reaches the agent without blocking the tool.
# permissionDecision is intentionally OMITTED so the commit proceeds through its
# normal permission flow (and any commit gate) unchanged.
#
# Counting is SHA-based rather than a naive incrementing counter, so it is
# self-correcting across terminal commits, amends, and rebases: the only state
# is a baseline commit (the HEAD at the last panel run) plus a once-per-crossing
# nudge flag. "commits since" = rev-list baseline..HEAD; "lines since" = the
# committed diff baseline..HEAD (a commit in flight counts once it lands).
#
# Worktree-aware: scopes to the git repo where the bash command actually runs —
# a leading `cd <dir>` target if present (inline-cd worktree work), else the bash
# tool's cwd — so state and counts belong to the right checkout.
#
# Subcommands:
#   review-cadence.sh reset   -> rebaseline to current HEAD, clear the nudge flag
#                                (the review-panel skill calls this after a run)
#
# Settings (plugin options, see kit-config.sh): review_cadence_commits (default 5),
# review_cadence_lines (default 200), base_branch, rfc_dir, adr_dir.
# REVIEW_CADENCE_COMMITS / REVIEW_CADENCE_LINES, when set, win over the settings.

set -uo pipefail

# Worktree-aware cwd resolution (git_toplevel, leading_cd_dir), shared with the
# commit gates. Resolve relative to this script, never the runtime cwd (these helpers exist
# to resolve the cwd correctly). This is an advisory hook (never blocks), so
# a missing lib degrades cleanly and silently (exit 0) rather than printing
# command-not-found noise per commit; the deny gates instead fail closed.
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$_HOOK_DIR/lib/cwd-resolve.sh" ] && [ -r "$_HOOK_DIR/kit-config.sh" ] || exit 0
# shellcheck source=lib/cwd-resolve.sh
. "$_HOOK_DIR/lib/cwd-resolve.sh"
# shellcheck source=kit-config.sh
. "$_HOOK_DIR/kit-config.sh"

THRESHOLD_COMMITS="$(kit_config review_cadence_commits "${REVIEW_CADENCE_COMMITS:-}")"
THRESHOLD_LINES="$(kit_config review_cadence_lines "${REVIEW_CADENCE_LINES:-}")"
# A value that is not a non-negative integer falls back to the default rather than
# making every `[ -ge ]` below fail (which would silence the cadence).
case "$THRESHOLD_COMMITS" in ''|*[!0-9]*) THRESHOLD_COMMITS=5 ;; esac
case "$THRESHOLD_LINES"   in ''|*[!0-9]*) THRESHOLD_LINES=200 ;; esac
RFC_DIR="$(kit_config rfc_dir)"; RFC_DIR="${RFC_DIR%/}"; : "${RFC_DIR:=docs/rfc}"
ADR_DIR="$(kit_config adr_dir)"; ADR_DIR="${ADR_DIR%/}"; : "${ADR_DIR:=docs/adr}"

# Appended to a nudge when the reviewed range touches a routed design doc (an RFC
# or a numbered ADR). Naming the routing at the trigger closes the self-grant: the
# docs-only skip cannot be claimed on a design doc. The review-panel skill's
# "Routing a design doc" table is the authority; this only points at it.
DESIGN_DOC_NUDGE="This diff includes an RFC/ADR design doc — review-panel routes design docs through /plan:tech-design-doc-review + the correctness/team-rules/simplification design lenses; the docs-only skip does NOT apply to it."

# --- helpers ----------------------------------------------------------------

state_dir()    { printf '%s/.claude/review-cadence' "$1"; }
baseline_file(){ printf '%s/.claude/review-cadence/baseline' "$1"; }
nudged_file()  { printf '%s/.claude/review-cadence/nudged' "$1"; }

# Resolve the base ref for the merge-base fallback, on the remote the base branch tracks (else
# origin, else the repo's first remote): the base_branch setting's remote branch first, then
# <remote>/HEAD (the remote's actual default), then the conventional <remote>/main and
# <remote>/master. Empty if none resolve.
default_base_ref() {
  local repo="$1" ref c base remote
  base=$(kit_config base_branch)
  remote=$(cd "$repo" && git config --get "branch.${base:-main}.remote" 2>/dev/null || true)
  if [ -z "$remote" ]; then
    if (cd "$repo" && git remote 2>/dev/null | grep -qx origin); then remote=origin
    else remote=$(cd "$repo" && git remote 2>/dev/null | head -1); fi
  fi
  remote=${remote:-origin}
  if [ -n "$base" ] && (cd "$repo" && git rev-parse --verify --quiet "$remote/$base" >/dev/null 2>&1); then
    printf '%s' "$remote/$base"; return
  fi
  ref=$(cd "$repo" && git symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)
  if [ -n "$ref" ]; then printf '%s' "$ref"; return; fi
  for c in "$remote/main" "$remote/master"; do
    if (cd "$repo" && git rev-parse --verify --quiet "$c" >/dev/null 2>&1); then printf '%s' "$c"; return; fi
  done
}

# Does the committed range $base..HEAD touch a routed design doc? Matches the
# review-panel "Routing a design doc" table: an RFC (<rfc_dir>/**/*.md) or a
# NUMBERED ADR (<adr_dir>/<digit>...md, not README/TEMPLATE/an index).
# Used only to decide whether to append DESIGN_DOC_NUDGE, so an over-match is a
# harmless extra reminder and the pattern stays simple. Empty base -> not touched.
# --no-renames so a design doc RENAMED OUT of its routed path (<rfc_dir>/foo.md ->
# docs/archive/foo.md) still lists the OLD path: rename detection would collapse it
# to the destination alone and hide it, but that move is exactly the deletion/
# supersession case the routing table flags.
touches_design_doc() {
  local repo="$1" base="$2" names
  [ -n "$base" ] || return 1
  # Capture into a var, then grep the var — never `git diff | grep -q`. Under
  # `set -o pipefail`, grep -q exits on its first match and closes the pipe; on a
  # large diff git is still writing and takes SIGPIPE (141), which pipefail surfaces
  # as the pipeline status, so the function would falsely report "no design doc".
  names=$(cd "$repo" && git diff --name-only --no-renames "$base" HEAD 2>/dev/null) || true
  printf '%s\n' "$names" | grep -qE "^$(_ere_quote "$RFC_DIR")/.+\.md\$|^$(_ere_quote "$ADR_DIR")/[0-9][^/]*\.md\$"
}

# Escape a literal path for use inside an ERE.
_ere_quote() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }

# Insertions+deletions in a committed range, or 0 if none / binary-only / the diff
# could not be computed. Shared by the pre-PR nudge and the during-coding counter so
# the two parses cannot drift. Committed range only (never the working tree): a
# working-tree diff would recount changes a panel just reviewed and miss untracked
# files in a combined add+commit. A binary or uncountable delta reports 0 here; the
# pre-PR caller defaults such an unmeasurable delta to the full-panel path rather than
# reading it as small.
count_changed_lines() {
  local repo="$1" range="$2" ss ins del
  ss=$(cd "$repo" && git diff --shortstat "$range" 2>/dev/null || true)
  ins=$(printf '%s' "$ss" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
  del=$(printf '%s' "$ss" | grep -oE '[0-9]+ deletion'  | grep -oE '[0-9]+' || echo 0)
  echo $((ins + del))
}

# Rebaseline to current HEAD and clear the nudge flag. Idempotent.
do_reset() {
  local repo="$1" head sd
  head=$(cd "$repo" && git rev-parse HEAD 2>/dev/null) || return 0
  sd=$(state_dir "$repo")
  mkdir -p "$sd" 2>/dev/null || return 0
  printf '%s\n' "$head" > "$(baseline_file "$repo")" 2>/dev/null || true
  rm -f "$(nudged_file "$repo")" 2>/dev/null || true
}

# --- reset mode (CLI, no stdin) ---------------------------------------------

if [ "${1:-}" = "reset" ]; then
  REPO=$(git_toplevel "$(pwd)")
  [ -n "$REPO" ] && do_reset "$REPO"
  exit 0
fi

# --- hook mode (stdin JSON) -------------------------------------------------

# Anything below must NEVER block a commit: every path exits 0.
#
# Hot-path optimization: this hook fires on every Bash tool call. Before paying
# for jq + the slow-path classifier, do a cheap substring check on the raw stdin -
# if none of "commit", "pr create", "pr new" or "push" appears anywhere in the payload,
# the command cannot possibly trigger this hook's logic (`git -C <dir> commit` has
# no "git commit" substring, hence the bare words). False positives are safe (the
# classifier below makes the real decision).
INPUT=$(cat 2>/dev/null || true)
case "$INPUT" in
  *commit*|*'pr create'*|*'pr new'*|*push*) ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$COMMAND" ] || exit 0

# Classify the command. We care about real git commits, PR creation, and pushes.
# A commit or push is the first word of a simple command, after any assignments,
# wrappers or git global options (find_git_sub, shared with the commit gates):
# `git -C <dir> commit` counts and is keyed to <dir>; `git commit-graph`, `git
# commit-tree`, `echo "git commit ..."` and "committed" in prose do not (a false
# match would mutate the once-per-crossing state).
IS_COMMIT=0
IS_PR=0
IS_PUSH=0
GIT_DIR_HINT=""
# Codex command adapters can carry the per-command checkout as `workdir` while
# the outer hook cwd still points at the session's main checkout. Prefer that
# explicit workdir so cadence state follows the checkout the command actually
# mutates; Claude's payload falls back to `.cwd` (tool_cwd in lib/cwd-resolve.sh).
TOOL_CWD=$(tool_cwd "$INPUT")
CLASSIFY_BASE=$(leading_cd_dir "$COMMAND" "$TOOL_CWD")
[ -n "$CLASSIFY_BASE" ] || CLASSIFY_BASE=$TOOL_CWD
read -r found sub_dir < <(find_git_sub "$COMMAND" commit "$CLASSIFY_BASE")
if [ "$found" = 1 ]; then IS_COMMIT=1; GIT_DIR_HINT=$sub_dir; fi
simple_commands "$COMMAND" gh | grep -qE '^[^ ]+( (-R|--repo) [^ ]+| --repo=[^ ]+)* pr (create|new)( |$)' && IS_PR=1
# A push to an already-open PR is a pre-review point too - see the pre-PR block below.
read -r found sub_dir < <(find_git_sub "$COMMAND" push "$CLASSIFY_BASE")
if [ "$found" = 1 ]; then IS_PUSH=1; [ -n "$GIT_DIR_HINT" ] || GIT_DIR_HINT=$sub_dir; fi
[ "$IS_COMMIT" = 1 ] || [ "$IS_PR" = 1 ] || [ "$IS_PUSH" = 1 ] || exit 0

SESSION_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
# Prefer the command's own `git -C <dir>`, then a leading `cd` target so inline-cd
# worktree work is attributed to the worktree, then the tool cwd, then the process cwd. git_toplevel returns empty
# for a missing/non-git dir, so this degrades to the prior behavior for plain
# commands.
REPO=""
[ -z "$GIT_DIR_HINT" ] || REPO=$(git_toplevel "$GIT_DIR_HINT")
[ -n "$REPO" ] || REPO=$(git_toplevel "$(leading_cd_dir "$COMMAND" "$TOOL_CWD")")
[ -n "$REPO" ] || REPO=$(git_toplevel "$TOOL_CWD")
[ -n "$REPO" ] || REPO=$(git_toplevel "$(pwd)")
[ -n "$REPO" ] || exit 0

HEAD=$(cd "$REPO" && git rev-parse HEAD 2>/dev/null) || exit 0   # no commits yet -> nothing to do

SD=$(state_dir "$REPO")
mkdir -p "$SD" 2>/dev/null || exit 0
BASELINE=$(cat "$(baseline_file "$REPO")" 2>/dev/null || true)
BASELINE_VALID=1
# Valid only if it EXISTS and is an ANCESTOR of HEAD. The ancestor check is what
# catches a baseline left on a divergent lineage — after a rebase, or a switch to
# / fresh branch off a different base. The SHA still exists (so cat-file passes),
# but counting `baseline..HEAD` across lineages reports the entire divergence as
# "unreviewed" — the inflated "N commits / huge lines" false nudge. Off-lineage
# -> invalid -> recovered below.
if [ -z "$BASELINE" ] \
   || ! (cd "$REPO" && git cat-file -e "${BASELINE}^{commit}" 2>/dev/null) \
   || ! (cd "$REPO" && git merge-base --is-ancestor "$BASELINE" HEAD 2>/dev/null); then
  BASELINE_VALID=0
fi

# --- pre-PR / pre-update run point ------------------------------------------
# Nudge the full-branch panel when the branch carries unreviewed commits, at
# either of two points:
#   - `gh pr create` (IS_PR): the obvious pre-PR review.
#   - `git push` to an ALREADY-OPEN PR (IS_PUSH): closes the gap where a PR is
#     opened early then rewritten - the pre-PR checkpoint otherwise fires only at
#     creation, so iterating on an open PR escapes review entirely.
# For a push we only treat it as a review point when there is unreviewed work AND
# an open PR already exists (otherwise the gh-pr-create path owns the nudge).
# Cost control: the `gh pr view` call is a NETWORK call, so we gate it on
# PRCOMMITS>0 - a cheap LOCAL check - so a routine push with nothing new since
# the last panel run never hits the network. We pass NO branch argument, so gh
# resolves the current branch's PR itself; that correctly handles a local/remote
# branch-name mismatch (e.g. `git push origin HEAD:other-name`). The call is
# bounded by `timeout` where available; any failure (no gh, no PR, offline) fails
# OPEN - silent, never blocking the push.
# This is a SOFT, best-effort nudge: because gh-unavailable fails open, the
# re-review can be evaded by gh being logged out/offline. That is acceptable for
# a non-blocking nudge; a non-gameable guarantee belongs in the merge gate, not
# in this hook.
# Runs even with no baseline yet - opening/updating a PR from a branch the cadence
# never saw is when review matters most; with no baseline, fall back to the branch
# point (merge-base with the base branch).
PRCOMMITS=0
# Pre-PR review target, kept in PR_* vars SEPARATE from REPO/HEAD/BASELINE_VALID:
# the session-cwd fallback below may retarget the pre-PR nudge, and that must
# never perturb the during-coding cadence counter, which stays keyed to the
# workdir-attributed checkout ($REPO) even on a combined `git commit && git push`.
PR_REPO="$REPO"; PR_HEAD="$HEAD"; PR_PRBASE=""; PR_BV="$BASELINE_VALID"
if [ "$IS_PR" = 1 ] || [ "$IS_PUSH" = 1 ]; then
  if [ "$BASELINE_VALID" = 1 ]; then
    PR_PRBASE="$BASELINE"
  else
    BASE_REF=$(default_base_ref "$PR_REPO")
    [ -n "$BASE_REF" ] && PR_PRBASE=$(cd "$PR_REPO" && git merge-base "$BASE_REF" "$PR_HEAD" 2>/dev/null || true)
  fi
  [ -n "$PR_PRBASE" ] && PRCOMMITS=$(cd "$PR_REPO" && git rev-list --count "${PR_PRBASE}..${PR_HEAD}" 2>/dev/null || echo 0)
  # A command-controlled workdir must not be able to zero the one guaranteed
  # pre-PR review. When the attributed $REPO shows nothing unreviewed, re-check
  # the harness-set session cwd repo before concluding there is nothing to
  # review: if the real branch lives there (a spoofed or mismatched workdir),
  # the checkpoint still fires. An arbitrary `git -C`/`gh -C` target the command
  # parser cannot see stays out of reach; the non-gameable backstop is the
  # merge gate, not this soft nudge.
  if [ "$PRCOMMITS" -eq 0 ]; then
    ALT_REPO=$(git_toplevel "$SESSION_CWD")
    if [ -n "$ALT_REPO" ] && [ "$ALT_REPO" != "$PR_REPO" ]; then
      ALT_HEAD=$(cd "$ALT_REPO" && git rev-parse HEAD 2>/dev/null || true)
      if [ -n "$ALT_HEAD" ]; then
        ALT_BASELINE=$(cat "$(baseline_file "$ALT_REPO")" 2>/dev/null || true)
        if [ -n "$ALT_BASELINE" ] \
           && (cd "$ALT_REPO" && git cat-file -e "${ALT_BASELINE}^{commit}" 2>/dev/null) \
           && (cd "$ALT_REPO" && git merge-base --is-ancestor "$ALT_BASELINE" "$ALT_HEAD" 2>/dev/null); then
          ALT_PRBASE="$ALT_BASELINE"; ALT_BV=1
        else
          ALT_BR=$(default_base_ref "$ALT_REPO"); ALT_PRBASE=""; ALT_BV=0
          [ -n "$ALT_BR" ] && ALT_PRBASE=$(cd "$ALT_REPO" && git merge-base "$ALT_BR" "$ALT_HEAD" 2>/dev/null || true)
        fi
        ALT_PRCOMMITS=0
        [ -n "$ALT_PRBASE" ] && ALT_PRCOMMITS=$(cd "$ALT_REPO" && git rev-list --count "${ALT_PRBASE}..${ALT_HEAD}" 2>/dev/null || echo 0)
        # Adopt the session repo as the pre-PR review target only if it carries
        # the unreviewed work the workdir-attributed repo lacked.
        if [ "$ALT_PRCOMMITS" -gt 0 ]; then
          PR_REPO="$ALT_REPO"; PR_HEAD="$ALT_HEAD"; PR_PRBASE="$ALT_PRBASE"
          PRCOMMITS="$ALT_PRCOMMITS"; PR_BV="$ALT_BV"
        fi
      fi
    fi
  fi
fi

PRE_PR=0
[ "$IS_PR" = 1 ] && PRE_PR=1
if [ "$IS_PUSH" = 1 ] && [ "$PRE_PR" = 0 ] && [ "$PRCOMMITS" -gt 0 ]; then
  if command -v timeout >/dev/null 2>&1; then GH_BOUND="timeout 5"; else GH_BOUND=""; fi
  PR_STATE=$(cd "$PR_REPO" && $GH_BOUND gh pr view --json state --jq '.state' 2>/dev/null || true)
  [ "$PR_STATE" = "OPEN" ] && PRE_PR=1
fi
if [ "$PRE_PR" = 1 ]; then
  if [ "$PRCOMMITS" -gt 0 ]; then
    # Size the unreviewed delta (text only — no panel runs here, so this costs no
    # tokens) to decide whether to ADD the full-fan-out emphasis. The size NEVER
    # gates review coverage down: every branch below points at the same review-panel
    # (pre-pr), which routes lenses by what the diff TOUCHES — blast radius is not
    # line count, so a small diff can still be high-stakes and content-routing gives
    # it the fitting lenses regardless. Sizing only escalates, never lightens.
    PRLINES=$(count_changed_lines "$PR_REPO" "${PR_PRBASE}..${PR_HEAD}")
    # Default to material (full same-model fan-out) and downgrade only for a CONFIRMED
    # small measurable delta since a real panel baseline: below both thresholds, at
    # least one counted line (a binary/uncountable delta reports 0 and stays material
    # rather than reading as small), and a valid baseline (a branch the panel never
    # saw is wholly unreviewed — full rigor). Fail toward more review, never less.
    MATERIAL=1
    if [ "$PR_BV" = 1 ] \
       && [ "$PRCOMMITS" -lt "$THRESHOLD_COMMITS" ] \
       && [ "$PRLINES" -gt 0 ] && [ "$PRLINES" -lt "$THRESHOLD_LINES" ]; then
      MATERIAL=0
    fi

    if [ "$IS_PR" = 1 ]; then
      # `gh pr create`: the one guaranteed checkpoint — non-optional even for a
      # trivial/config-only diff, and it names the skip-whitelist so a confident
      # skip cannot masquerade as a sanctioned judgment call.
      MSG="[review-cadence] About to open a PR with ${PRCOMMITS} commit(s) / ${PRLINES} changed line(s) not yet reviewed by the panel. Run the soft reviewer panel in pre-PR mode first: invoke the \`review-panel\` skill (pre-pr) - it routes the lenses that fit the diff and grades findings Critical/Important/Minor. Fix Critical/Important, then proceed. SOFT means findings never block the PR or the merge gate - it does NOT mean the run is optional: the pre-PR pass is the one guaranteed checkpoint and runs even for 'trivial' or config-only diffs. Skip ONLY for a reason on the skill's skip-whitelist (the skill owns the list - read it), logged with its evidence; confidence or triviality are not skip reasons."
    else
      # Push to an already-open PR. Word the reference honestly: a valid baseline is
      # the last panel run; no baseline means the branch was never reviewed (and is
      # therefore material). The base ask always points at review-panel (pre-pr),
      # which content-routes — so a small diff naturally gets a light pass WITHOUT the
      # hook licensing reduced coverage.
      if [ "$PR_BV" = 1 ]; then
        SINCE="${PRCOMMITS} commit(s) / ${PRLINES} changed line(s) since the last reviewer-panel run"
      else
        SINCE="${PRCOMMITS} commit(s) / ${PRLINES} changed line(s) on this branch, not yet reviewed by the panel"
      fi
      MSG="[review-cadence] Updating this open PR - ${SINCE}. Run the \`review-panel\` skill (pre-pr) over the updated diff: it routes the fitting lens set by what the diff TOUCHES (blast radius is not line count - a small diff can still be high-stakes). Fix Critical/Important, then push. SOFT means findings never block the PR or the merge gate, not that the run is optional."
      # Materially-changed (or wholly-unreviewed) re-push: add the full-fan-out
      # emphasis. A cross-model/counterpart-only or single-lens pass is a supplement, not a
      # substitute — the same-model fan-out catches a class (stale comments, repeated
      # rationale, over-commenting) a cross-model-only pass misses, which is how a
      # series of partial re-reviews can silently pass a materially-changed diff.
      [ "$MATERIAL" = 1 ] && MSG="$MSG This diff has changed materially since the last full review, so run the COMPLETE same-model fan-out - a cross-model/counterpart-only or single-lens pass is a supplement, not a substitute for it."
    fi
    touches_design_doc "$PR_REPO" "$PR_PRBASE" && MSG="$MSG $DESIGN_DOC_NUDGE"
    jq -nc --arg ctx "$MSG" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}'
  fi
  exit 0
fi
# A push that is NOT a review point (no unreviewed commits, or no open PR) and is
# not also a commit: nothing to do. (A commit+push falls through to the cadence
# counter below.)
[ "$IS_PUSH" = 1 ] && [ "$IS_COMMIT" = 0 ] && exit 0

# --- during-coding cadence (git commit) -------------------------------------
# Initialize, or recover if the baseline was rewritten away or left off-lineage
# (rebase / amend / branch-switch / fresh branch). Re-baseline to THIS branch's
# point (merge-base with the default base ref) so genuine unreviewed work on the
# branch still counts on the next trigger; fall back to HEAD when no base ref
# resolves (e.g. a repo with no origin). Do not nudge on this recovery pass — the
# corrected baseline takes effect next trigger.
if [ "$BASELINE_VALID" = 0 ]; then
  NEWBASE="$HEAD"
  # Distinguish a REWIND from true DIVERGENCE. If the old baseline still exists
  # and HEAD is an ancestor of it, the baseline is a DESCENDANT of HEAD — HEAD was
  # reset/checked-out backward on the same lineage. There is no new work, so
  # re-baseline to HEAD (count stays 0); recovering to an earlier branch point
  # would re-count already-reviewed commits as a false nudge. Otherwise it is true
  # divergence (rebase / branch-switch / fresh branch): re-baseline to the branch
  # point so genuine unreviewed work still counts. Do not nudge on this pass.
  if [ -n "$BASELINE" ] \
     && (cd "$REPO" && git cat-file -e "${BASELINE}^{commit}" 2>/dev/null) \
     && (cd "$REPO" && git merge-base --is-ancestor HEAD "$BASELINE" 2>/dev/null); then
    : # rewind — keep NEWBASE=HEAD
  else
    BR=$(default_base_ref "$REPO")
    if [ -n "$BR" ]; then
      MB=$(cd "$REPO" && git merge-base "$BR" HEAD 2>/dev/null || true)
      [ -n "$MB" ] && NEWBASE="$MB"
    fi
  fi
  printf '%s\n' "$NEWBASE" > "$(baseline_file "$REPO")" 2>/dev/null || true
  rm -f "$(nudged_file "$REPO")" 2>/dev/null || true
  exit 0
fi

COMMITS=$(cd "$REPO" && git rev-list --count "${BASELINE}..${HEAD}" 2>/dev/null || echo 0)
LINES=$(count_changed_lines "$REPO" "${BASELINE}..${HEAD}")

CROSSED=0
[ "$COMMITS" -ge "$THRESHOLD_COMMITS" ] && CROSSED=1
[ "$LINES"   -ge "$THRESHOLD_LINES"   ] && CROSSED=1

# Nudge once per crossing; the panel's `reset` re-arms it. If we have dropped
# back below threshold (HEAD rewound, or a false-positive set the flag), clear
# it so a genuine future crossing nudges again without needing an explicit reset.
if [ "$CROSSED" = 1 ]; then
  if [ ! -f "$(nudged_file "$REPO")" ]; then
    MSG="[review-cadence] ${COMMITS} commit(s) / ${LINES} changed line(s) since the last reviewer-panel run (threshold: ${THRESHOLD_COMMITS} commits or ${THRESHOLD_LINES} lines). Before continuing, run the soft reviewer panel: invoke the \`review-panel\` skill (cadence mode) - it picks the lenses that fit the diff and grades findings Critical/Important/Minor. Fix Critical/Important, then continue. SOFT means findings never block this commit or the merge gate - not that the run is optional. The panel resets this cadence when it runs."
    touches_design_doc "$REPO" "$BASELINE" && MSG="$MSG $DESIGN_DOC_NUDGE"
    touch "$(nudged_file "$REPO")" 2>/dev/null || true
    jq -nc --arg ctx "$MSG" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}'
  fi
else
  rm -f "$(nudged_file "$REPO")" 2>/dev/null || true
fi

exit 0
