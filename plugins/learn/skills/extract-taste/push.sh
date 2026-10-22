#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# extract-taste / push.sh
# ---------------------------------------------------------------------------
# The ONLY sanctioned path that pushes a taste-collection artifact and opens its
# PR. It binds the privacy gates to exit codes instead of to an LLM remembering
# to run them. SKILL.md Step 5 must call this and never raw `git push`/`gh`.
#
# It refuses unless ALL hold:
#   1. --confirm-push is present       (no accidental / default push)
#   2. scrub.sh returns clean          (no credential signatures)
#   3. the staged diff touches ONLY    (no stray files riding along)
#      docs/taste-collection/<handle>.md
#
# The PR targets the base_branch setting (default main) on the repo_slug setting (default:
# the owner/name of the worktree's origin, else whatever gh infers).
#
# Usage: push.sh <handle> <worktree-path> --confirm-push
# Exit:  0 pushed+PR, or nothing new since the last push | 1 scrub blocked |
#        2 usage/precondition | 3 not confirmed |
#        4 a git or gh step failed (nothing after the failed step ran)
# ---------------------------------------------------------------------------
# A failed commit/push/PR step exits 4 through step(), never falls through to the success
# echo. Genuinely-optional commands below keep an explicit `|| true`.
set -uo pipefail

handle="${1:-}"; wt="${2:-}"; confirm="${3:-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# step <description> <command...>: run it; on failure say which step failed and exit 4.
step() { local what="$1"; shift; "$@" || { echo "push.sh: $what failed — stopped (exit 4)." >&2; exit 4; }; }
# The person tagged on the PR (EXTRACT_TASTE_CONSOLIDATOR); blank tags nobody.
CONSOLIDATOR="${EXTRACT_TASTE_CONSOLIDATOR:-}"

[[ -n "$handle" && -n "$wt" ]] || { echo "usage: push.sh <handle> <worktree-path> --confirm-push" >&2; exit 2; }
if [[ "$confirm" != "--confirm-push" ]]; then
  echo "push.sh: refusing — --confirm-push not supplied. A default run never pushes; the artifact stays local for review." >&2
  exit 3
fi
[[ -d "$wt/.git" || -f "$wt/.git" ]] || { echo "push.sh: not a worktree: $wt" >&2; exit 2; }

rel="docs/taste-collection/${handle}.md"
artifact="$wt/$rel"
[[ -f "$artifact" ]] || { echo "push.sh: artifact not found: $artifact" >&2; exit 2; }
# Reject a symlink: scrub follows the link (scans the target) while `git add`
# stores the link path — so scrub and the committed blob would cover different
# bytes. Refuse so both operate on the same real file.
[[ -L "$artifact" ]] && { echo "push.sh: artifact is a symlink — refusing" >&2; exit 2; }

branch="taste/${handle}"
cur="$(git -C "$wt" branch --show-current 2>/dev/null || true)"
[[ "$cur" == "$branch" ]] || { echo "push.sh: worktree is on '$cur', expected '$branch'" >&2; exit 2; }

# Settings: the PR's base branch and repo.
if [[ -r "$here/../../scripts/kit-config.sh" ]]; then
  # shellcheck source=../../scripts/kit-config.sh
  . "$here/../../scripts/kit-config.sh"
  base_branch="$(kit_config base_branch)"; repo_slug="$(kit_config repo_slug)"
fi
: "${base_branch:=main}"
if [[ -z "${repo_slug:-}" ]]; then
  origin_url="$(git -C "$wt" remote get-url origin 2>/dev/null || true)"
  repo_slug="$(printf '%s' "$origin_url" | sed -nE 's#^(https://[^/]+/|git@[^:]+:|ssh://git@[^/]+/)([^/]+/[^/]+?)(\.git)?/?$#\2#p')"
fi
repo_args=(); [[ -n "$repo_slug" ]] && repo_args=( --repo "$repo_slug" )

# Gate 2: scrub must be clean.
if ! "$here/scrub.sh" "$artifact"; then
  echo "push.sh: scrub did not pass — push blocked." >&2
  exit 1
fi

# The remote branch as it is now: the lease below names it, and an artifact identical to the
# one already pushed means there is nothing new, so nothing is committed, pushed or refreshed.
git -C "$wt" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || true
lease_sha="$(git -C "$wt" rev-parse -q --verify "refs/remotes/origin/$branch" 2>/dev/null || true)"
if [[ -n "$lease_sha" ]] && git -C "$wt" cat-file -e "$lease_sha:$rel" 2>/dev/null \
   && cmp -s "$artifact" <(git -C "$wt" show "$lease_sha:$rel"); then
  echo "push.sh: no new taste since $(git -C "$wt" log -1 --format='%h (%cs)' "$lease_sha") — nothing committed, pushed or refreshed."
  exit 0
fi

# Gate 3: stage ONLY the artifact, then verify nothing else is staged.
step "git add" git -C "$wt" add "$rel"
staged="$(git -C "$wt" diff --cached --name-only)" || { echo "push.sh: git diff failed — stopped (exit 4)." >&2; exit 4; }
if [[ "$staged" != "$rel" ]]; then
  echo "push.sh: refusing — staged set is not exactly $rel:" >&2
  printf '%s\n' "$staged" | sed 's/^/  /' >&2
  exit 2
fi

step "git commit" git -C "$wt" commit -q -m "chore(taste): collect ${handle} Claude working-knowledge (research, do not merge)"
# Re-runs are expected (Step 0 resets the branch off the fresh base branch), so the local
# branch diverges from any previously-pushed taste/<handle>. Force-with-lease is
# correct — the branch holds a single regenerated research artifact, not shared
# history — and it updates an existing PR's branch in place instead of dead-ending
# on a non-fast-forward reject. The lease names the remote's current value, fetched before
# staging, so a run from a clone that never fetched taste/<handle> (a second machine) is not
# refused as stale; an absent remote branch leases on "must not exist".
step "git push" git -C "$wt" push -q -u --force-with-lease="$branch:$lease_sha" origin "$branch"

gh label create taste-collection --color BFD4F2 \
  --description "extract-taste research artifacts (collected, not merged)" 2>/dev/null || true

body="$(cat <<EOF
## What & Why

Research artifact from \`/learn:extract-taste\` — an abstracted profile of how @${handle}
works with Claude (preferences, workflow mechanics, efficiencies, repeated
corrections, frustrations), surfaced from their local Claude setup.

**Do NOT merge.** This is a data point, not a change. The file lives in
\`docs/taste-collection/\` which no harness path reads, so it is inert even if
merged by accident. These PRs are collected and clustered to decide what belongs
in the shared harness (gate / rule / skill / hook / CLAUDE.md / something new).

## Validation

- \`scrub.sh\` returned clean (no credential signatures) before push.
- Staged diff verified to touch only \`${rel}\`.
- Owner reviewed the artifact before passing \`--confirm-push\`.
EOF
)"

# Idempotent PR: a re-run updates the existing open PR for this branch rather than
# failing `gh pr create` with "already exists"; otherwise create one. (One PR per
# handle, refreshed on re-run.)
pr_num="$(cd "$wt" && gh pr list ${repo_args[@]+"${repo_args[@]}"} --head "$branch" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)"
opened=0
if [[ -n "$pr_num" ]]; then
  url="$(cd "$wt" && gh pr view ${repo_args[@]+"${repo_args[@]}"} "$pr_num" --json url --jq .url)" \
    || { echo "push.sh: gh pr view failed — stopped (exit 4)." >&2; exit 4; }
  (cd "$wt" && gh pr edit ${repo_args[@]+"${repo_args[@]}"} "$pr_num" --body "$body") >/dev/null 2>&1 || true
else
  url="$(cd "$wt" && gh pr create ${repo_args[@]+"${repo_args[@]}"} --base "$base_branch" --head "$branch" \
    --title "[taste-collection] ${handle} — Claude working-knowledge (research, do not merge)" \
    --label taste-collection \
    --body "$body")" || { echo "push.sh: gh pr create failed — stopped (exit 4)." >&2; exit 4; }
  pr_num="$(printf '%s' "$url" | grep -oE 'pull/[0-9]+' | grep -oE '[0-9]+' || true)"
  opened=1
fi

echo "$url"
# Tag the consolidator once, when the PR is opened; a refresh pushes to a PR they already follow.
if [[ "$opened" = 1 && -n "$pr_num" && -n "$CONSOLIDATOR" ]]; then
  (cd "$wt" && gh pr comment ${repo_args[@]+"${repo_args[@]}"} "$pr_num" --body "@${CONSOLIDATOR} new taste-collection artifact from @${handle} for harness review.") || true
fi
command -v pbcopy >/dev/null 2>&1 && printf '%s' "$url" | pbcopy || true
echo "push.sh: done — $url"
