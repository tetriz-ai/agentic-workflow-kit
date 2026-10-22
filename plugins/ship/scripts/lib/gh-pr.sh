# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# shellcheck shell=bash
# Library: the PR lookups pr-feedback.sh and codex-sweep.sh share. Each function takes the
# calling tool's name for its error messages and returns 1 (message on stderr) on failure.
# Callers run with `set -o pipefail`, so a failed `gh` survives the colour-strip pipe.
#
#   gh_pr_number <tool> [pr]         -> prints the given PR number, else the current
#                                       branch's open PR; it must be all digits.
#   gh_pr_repo <tool>                -> sets OWNER, NAME and SLUG from `gh repo view`.
#   gh_pr_graphql <tool> <pr> <query> -> prints the response for the PR (variables owner,
#                                       name, num), ANSI colour stripped. Fails on a failed
#                                       query (with gh's stderr), a GraphQL errors array,
#                                       unparseable JSON, or a missing PR.

gh_pr_number() {
  local tool="$1" pr="${2:-}"
  [ -n "$pr" ] || pr=$(gh pr view --json number -q .number 2>/dev/null || true)
  [ -n "$pr" ] || { echo "$tool: no PR number (pass one, or run on a branch with an open PR)" >&2; return 1; }
  case "$pr" in *[!0-9]*) echo "$tool: PR must be a number, got '$pr'" >&2; return 1 ;; esac
  printf '%s' "$pr"
}

gh_pr_repo() {
  SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  [ -n "$SLUG" ] || { echo "$1: could not resolve the repo (run inside the checkout)" >&2; return 1; }
  OWNER=${SLUG%/*}; NAME=${SLUG#*/}
}

gh_pr_graphql() {
  local tool="$1" pr="$2" query="$3" json err
  err=$(mktemp)
  # Some setups (a colourising gh wrapper) emit coloured JSON that jq cannot parse; the
  # strip is a no-op on plain output.
  json=$(gh api graphql -f owner="$OWNER" -f name="$NAME" -F num="$pr" -f query="$query" 2>"$err" \
    | sed $'s/\x1b\\[[0-9;]*m//g') \
    || { echo "$tool: GraphQL query failed: $(cat "$err") (gh auth? does PR #$pr exist in $SLUG?)" >&2; rm -f "$err"; return 1; }
  rm -f "$err"
  # Fail closed on a partial or errored response: never present a fetch failure as "no feedback".
  if [ "$(printf '%s' "$json" | jq -r '(.errors // []) | length' 2>/dev/null)" != "0" ]; then
    echo "$tool: GraphQL returned errors or unparseable JSON" >&2; return 1
  fi
  [ "$(printf '%s' "$json" | jq -r '.data.repository.pullRequest // "null"')" != "null" ] \
    || { echo "$tool: PR #$pr not found in $SLUG" >&2; return 1; }
  printf '%s' "$json"
}
