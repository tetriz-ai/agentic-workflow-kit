# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# shellcheck shell=bash
# Shared detection for the PR-description-drift hooks. Sourced (never executed)
# by check-pr-description-drift.sh (Claude PostToolUse) and
# pre-push-pr-drift-check.sh (git pre-push). Each caller owns only its trigger
# guard and its output format — all the gh/GraphQL/epoch/dedup logic lives here,
# so a fix lands in one place instead of drifting between two copies.
#
# Every function is meant to be called in an errexit-disabled context (as the
# left of `||`, or an `if` condition), so the callers' `set -e` does not abort
# on an expected non-zero return.

# gh availability/auth probe. Returns: 0 ready · 1 gh not installed · 2 gh
# installed but not authenticated. The caller decides how (or whether) to warn,
# since the two channels render it differently.
pr_drift_gh_status() {
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1 || return 2
  return 0
}

# Throttle the "gh not authenticated" warning to at most once per UTC day, and
# stamp the marker when it fires. Returns 0 if the caller should warn now, 1 if
# already warned today. The marker is shared across both hooks so the user
# never sees two warnings on the same day.
pr_drift_should_warn_auth() {
  local today marker
  today=$(date -u +%Y-%m-%d)
  # With no HOME there is nowhere to keep the marker: warn, and never fail the caller.
  [ -n "${HOME:-}" ] || return 0
  marker="$HOME/.cache/drift-hook-gh-warned"
  [ "$(cat "$marker" 2>/dev/null)" = "$today" ] && return 1
  mkdir -p "$(dirname "$marker")" 2>/dev/null || true
  echo "$today" > "$marker" 2>/dev/null || true
  return 0
}

# Detect whether the current branch's open PR has a description older than its
# latest commit. On drift, sets PR_DRIFT_NUMBER / PR_DRIFT_BODY_EDITED /
# PR_DRIFT_LAST_COMMIT_ISO, writes the dedup marker, and returns 0. Returns 1 in
# every no-nudge case (not a branch, on the base branch, no PR, already nudged this
# (PR, body-version), no drift, or any lookup failure) so the caller can exit
# silently.
pr_drift_detect() {
  local branch pr git_dir marker marker_key nwo owner name
  local body_edited last_commit_iso last_commit_epoch body_edited_epoch
  # Default 60s: a human edit-then-immediately-commit burst is sub-30s; 60s gives
  # headroom. Overridable so a test can pin it to 0 for deterministic runs.
  local grace="${PR_DRIFT_GRACE_SECONDS:-60}"
  case "$grace" in ''|*[!0-9]*) grace=60 ;; esac  # not an integer -> default

  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
  case "$branch" in master|main|HEAD|"") return 1 ;; esac
  # The configured base branch is never a PR head either (kit_config is loaded by
  # the callers when available; absent, only main/master are skipped).
  if command -v kit_config >/dev/null 2>&1 && [ "$branch" = "$(kit_config base_branch)" ]; then
    return 1
  fi

  pr=$(gh pr list --head "$branch" --state open --limit 1 \
         --json number --jq '.[0].number // empty' 2>/dev/null || true)
  [ -n "$pr" ] || return 1

  nwo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  [ -n "$nwo" ] || return 1
  owner=${nwo%/*}
  name=${nwo#*/}

  # lastEditedAt is NULL until the body is edited after creation; fall back to
  # createdAt so a brand-new PR with an unchanged body is still flagged as stale
  # once any commit lands.
  body_edited=$(gh api graphql \
    -f query='query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){lastEditedAt createdAt}}}' \
    -F o="$owner" -F n="$name" -F p="$pr" \
    --jq '.data.repository.pullRequest | (.lastEditedAt // .createdAt) // empty' \
    2>/dev/null || true)
  [ -n "$body_edited" ] || return 1

  # GitHub DateTime is Z-suffixed UTC, which jq's fromdateiso8601 parses
  # natively (it rejects "+HH:MM" offsets, so don't rewrite the string).
  # Require a pure integer: guards the arithmetic below against a stray "null"
  # or float that would otherwise error out under the caller's set -e.
  body_edited_epoch=$(jq -rn --arg s "$body_edited" '$s | fromdateiso8601' 2>/dev/null || true)
  [[ "$body_edited_epoch" =~ ^[0-9]+$ ]] || return 1

  # Dedup marker keyed by (PR, body-edit epoch) — NOT the commit SHA. The
  # reminder is about a stale body, so it should fire once per stale
  # body-version and then go quiet, however many more commits land; a per-SHA
  # key would re-fire on every push.
  # Editing the body (a new lastEditedAt) changes the key and re-arms detection
  # for the next time it drifts. For a body that is NEVER edited (the createdAt
  # fallback above), the key is fixed for the PR's life, so the reminder fires
  # exactly once ever — the deliberate trade-off: no periodic re-nudge on a body
  # the author has already been told is stale. Lives in .git/ so it's per-clone
  # and gitignored, and is SHARED with the pre-push sibling — a PostToolUse fire
  # and a later terminal push for the same body-version count as one reminder.
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 1
  marker="${git_dir}/.pr-drift-nudged"
  marker_key="${pr}:${body_edited_epoch}"
  [ "$(cat "$marker" 2>/dev/null)" = "$marker_key" ] && return 1

  # Compare as epoch seconds — avoids lexicographic pitfalls when git emits
  # local-tz ISO (e.g. "…+05:30") while the GitHub API emits UTC Z-suffix.
  last_commit_iso=$(git log -1 --format=%cI 2>/dev/null || true)
  last_commit_epoch=$(git log -1 --format=%ct 2>/dev/null || true)
  [ -n "$last_commit_epoch" ] || return 1

  # Require a small lead before flagging — filters the edit-body-then-commit
  # burst where the two timestamps differ by seconds, which isn't real drift.
  [ "$last_commit_epoch" -gt $((body_edited_epoch + grace)) ] || return 1

  # Write the marker before the caller emits, so a crash mid-message doesn't
  # loop on the next push of the same body-version.
  echo "$marker_key" > "$marker" 2>/dev/null || true

  # Outputs for the caller, which reads them after this returns 0. Exported so a
  # caller that runs its message step in a child process sees them too.
  export PR_DRIFT_NUMBER="$pr" PR_DRIFT_BODY_EDITED="$body_edited" PR_DRIFT_LAST_COMMIT_ISO="$last_commit_iso"
  return 0
}
