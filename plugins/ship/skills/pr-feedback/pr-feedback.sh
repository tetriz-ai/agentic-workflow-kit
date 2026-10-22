#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# pr-feedback - fetch ALL review feedback on a PR across every GitHub surface.
#
# The problem this solves: PR feedback is split across separate GitHub API
# surfaces, and no single common command returns all of them:
#   - inline review comments  -> /pulls/N/comments  (gh api ... /comments)
#   - REVIEW BODIES           -> /pulls/N/reviews[].body   <-- the silent gap:
#       `gh pr view --comments` and `gh api .../pulls/N/comments` BOTH miss this,
#       so a finding posted in a review body (e.g. a Codex review) is invisible
#       to the usual "fetch the comments" step and gets silently dropped.
#   - conversation comments   -> /issues/N/comments
# This pulls all three in ONE GraphQL call, with thread state (resolved /
# outdated - an *outdated* thread can still be a valid, unaddressed finding), and
# prints a triage list so "I addressed all the PR comments" is complete, not a
# guess. Use it via the `/ship:pr-feedback` skill, or run it directly.
#
# Usage:   pr-feedback.sh [PR_NUMBER]      (no arg -> the current branch's PR)
# Output:  grouped triage list on stdout; warns (does NOT silently truncate) if a
#          surface has >100 items. Exits non-zero on a hard failure (no gh/jq, no
#          PR, query error) so a caller never mistakes "couldn't fetch" for "clean".

set -uo pipefail

command -v gh >/dev/null 2>&1 || { echo "pr-feedback: 'gh' not installed/authed" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "pr-feedback: 'jq' not installed" >&2; exit 1; }

# shellcheck source=../../scripts/lib/gh-pr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/gh-pr.sh" \
  || { echo "pr-feedback: gh-pr.sh missing" >&2; exit 1; }
PR=$(gh_pr_number pr-feedback "${1:-}") || exit 1
gh_pr_repo pr-feedback || exit 1

GQL='
query($owner:String!,$name:String!,$num:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$num){
      title
      reviews(first:100){ pageInfo{hasNextPage} nodes{ author{login} state body } }
      reviewThreads(first:100){ pageInfo{hasNextPage} nodes{
        isResolved isOutdated path line
        comments(first:30){ pageInfo{hasNextPage} nodes{ databaseId author{login} body } }
      } }
      comments(first:100){ pageInfo{hasNextPage} nodes{ author{login} body } }
    }
  }
}'
JSON=$(gh_pr_graphql pr-feedback "$PR" "$GQL") || exit 1
PR_OBJ='.data.repository.pullRequest'

# Every surface must be in the response: a missing connection would print "(none)" for feedback
# that exists, so it is an error, never an empty section.
MISSING=$(printf '%s' "$JSON" | jq -r "$PR_OBJ as \$p | [\"reviews\", \"reviewThreads\", \"comments\"][] | select((\$p[.].nodes | type) != \"array\")" 2>/dev/null) \
  || { echo "pr-feedback: the GraphQL response for PR #$PR could not be read" >&2; exit 1; }
if [ -n "$MISSING" ]; then
  echo "pr-feedback: the GraphQL response for PR #$PR lacks: $(printf '%s' "$MISSING" | tr '\n' ' ')— not reporting an incomplete picture" >&2
  exit 1
fi

TITLE=$(printf '%s' "$JSON" | jq -r "$PR_OBJ.title // \"\"")

# Per-surface extraction (simple per-node maps - easy to read and debug).
# REVIEW BODIES: the surface the common fetches miss. Skip whitespace-only bodies
# (an approval or an inline-only review has an empty body).
REVIEW_BODIES=$(printf '%s' "$JSON" | jq -r "
  $PR_OBJ.reviews.nodes[]
  | select(((.body // \"\") | gsub(\"\\\\s\";\"\")) != \"\")
  | \"• @\(.author.login) [\(.state)]:\n\" + ((.body) | split(\"\n\") | map(\"    \" + .) | join(\"\n\"))
")
# Reply target = the thread's TOP-LEVEL (first) comment id. GitHub's reply API
# rejects replies-to-replies, so we surface that one id per thread, not every
# comment's. Bodies are one-lined and capped, but the cap is MARKED (not silent).
INLINE_THREADS=$(printf '%s' "$JSON" | jq -r "
  $PR_OBJ.reviewThreads.nodes[]
  | (.comments.nodes[0].databaseId) as \$root
  | \"• \(.path):\(.line // \"?\")  [\" + (if .isResolved then \"RESOLVED\" else \"UNRESOLVED\" end)
      + (if .isOutdated then \" · outdated\" else \"\" end) + \"]  (reply target: id \(\$root))\n\"
    + (.comments.nodes | map(\"    @\(.author.login): \" + (((.body)|gsub(\"\n\";\" \")) | if length > 280 then .[0:280] + \" … [truncated — open the comment for the rest]\" else . end)) | join(\"\n\"))
")
CONVERSATION=$(printf '%s' "$JSON" | jq -r "
  $PR_OBJ.comments.nodes[]
  | \"• @\(.author.login): \" + (((.body)|gsub(\"\n\";\" \")) | if length > 280 then .[0:280] + \" … [truncated — open the comment for the rest]\" else . end)
")

section() {  # $1 = title, $2 = body (empty -> "(none)")
  printf '\n── %s ──\n' "$1"
  if [ -n "$2" ]; then printf '%s\n' "$2"; else printf '  (none)\n'; fi
}

printf '=== PR #%s feedback — %s — %s ===\n' "$PR" "$SLUG" "$TITLE"
section "REVIEW BODIES (the surface 'gh ... comments' misses)" "$REVIEW_BODIES"
section "INLINE REVIEW THREADS" "$INLINE_THREADS"
section "CONVERSATION COMMENTS" "$CONVERSATION"

# Counts + a no-silent-truncation warning.
COUNTS=$(printf '%s' "$JSON" | jq -r "
  $PR_OBJ as \$p
  | ([\$p.reviews.nodes[] | select(((.body // \"\")|gsub(\"\\\\s\";\"\")) != \"\")] | length) as \$rb
  | (\$p.reviewThreads.nodes | length) as \$th
  | ([\$p.reviewThreads.nodes[] | select(.isResolved | not)] | length) as \$un
  | (\$p.comments.nodes | length) as \$cv
  | \"  review-bodies: \(\$rb) · inline-threads: \(\$th) (unresolved: \(\$un)) · conversation: \(\$cv)\"
")
printf '\n── SUMMARY ──\n%s\n' "$COUNTS"

# Truncation guard covers all four connections: the three outer surfaces AND the
# inner per-thread replies (a thread with >30 replies would otherwise drop its
# tail silently - often the latest, load-bearing disposition).
TRUNCATED=$(printf '%s' "$JSON" | jq -r "([$PR_OBJ.reviews.pageInfo.hasNextPage, $PR_OBJ.reviewThreads.pageInfo.hasNextPage, $PR_OBJ.comments.pageInfo.hasNextPage] + [$PR_OBJ.reviewThreads.nodes[].comments.pageInfo.hasNextPage]) | any")
if [ "$TRUNCATED" = "true" ]; then
  printf '  ⚠ a surface (or a thread'\''s replies) exceeds the page size - this list is NOT complete; paginate before claiming full coverage.\n'
fi

exit 0
