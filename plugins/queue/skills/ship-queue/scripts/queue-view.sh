#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Team-portable tabular view of a person's queue: the open, labeled issues
# ASSIGNED to them (the person who should work them), newest-first, enriched with
# project-board Priority + Status, the GitHub assignee(s), and any linked OPEN
# (unmerged) PR.
#
# Emits TSV to stdout, one row per issue, header first:
#   number \t created \t priority \t status \t assignees \t open_prs \t title
#
# It is the single source feeding BOTH the /queue:ship-queue "show my tickets" view and
# the session-start ship-queue nudge handler, so the two never drift.
#
# Why ASSIGNEE, not author: /queue:bug-hunt is run by one person who files findings and
# assigns owners to teammates. The habit loop nudges the OWNER (assignee), so the
# default scope is "assigned to me". Pass AUTHOR to additionally scope by creator.
#
# Env overrides (all optional; the defaults come from the queue plugin's settings):
#   REPO      default repo_slug, else `gh repo view`   (owner/name)
#   LABEL     default queue_label (ship-queue)          (issue label to filter on)
#   ASSIGNEE  default @me                       (GitHub login or @me; "" disables)
#   AUTHOR    default (unset)                   (also scope by creator when set)
#   DAYS      default 0                         (created within last N days; 0 = no window)
#   STATE     default open                      (open|closed|all)
#   PROJECT_NUMBER default from github_project (owner/number); blank = no board,
#             so priority and status read "-"
set -euo pipefail

# shellcheck source=../../../scripts/kit-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/kit-config.sh"
REPO="${REPO:-$(kit_config repo_slug)}"
[ -n "$REPO" ] || REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
[ -n "$REPO" ] || { echo "queue-view: could not resolve the repo (set repo_slug or REPO)" >&2; exit 2; }
LABEL="${LABEL:-$(kit_config queue_label)}"
LABEL="${LABEL:-ship-queue}"
# Unset-only default (`-`, not `:-`): an explicit ASSIGNEE="" means "all assignees"
# (the documented disable), and must NOT fall back to @me.
ASSIGNEE="${ASSIGNEE-@me}"
AUTHOR="${AUTHOR:-}"
DAYS="${DAYS:-0}"
STATE="${STATE:-open}"
# The GitHub project board whose Priority/Status this view reports (the
# github_project setting, see /ship:github-issues). Exported so the per-issue jq can read
# it via `env` and ignore field values from any OTHER project the issue sits on.
# 0 means no board: no project item matches, so priority and status read "-".
_project="$(kit_config github_project)"
export PROJECT_NUMBER="${PROJECT_NUMBER:-${_project##*/}}"
case "$PROJECT_NUMBER" in ''|*[!0-9]*) PROJECT_NUMBER=0 ;; esac

OWNER="${REPO%/*}"
NAME="${REPO#*/}"

# Bound every gh network call so a slow/half-open connection cannot wedge a
# backgrounded caller (the session-start nudge runs detached). timeout/gtimeout
# when present; else run bare (macOS without coreutils) — best-effort, not a dep.
TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT="timeout 20"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT="gtimeout 20"; fi

# Build the `gh issue list` argument set. --search carries sort + optional window.
search="sort:created-desc"
if [ "${DAYS}" != "0" ] && [ -n "${DAYS}" ]; then
  # today - DAYS as YYYY-MM-DD (macOS `date -v` first, GNU `date -d` fallback)
  since="$(date -v-"${DAYS}"d +%F 2>/dev/null || date -d "-${DAYS} days" +%F)"
  search="created:>=${since} ${search}"
fi

args=(--repo "$REPO" --label "$LABEL" --state "$STATE" --search "$search" --limit 200 --json number --jq '.[].number')
[ -n "$ASSIGNEE" ] && args=(--assignee "$ASSIGNEE" "${args[@]}")
[ -n "$AUTHOR" ]   && args=(--author "$AUTHOR" "${args[@]}")

nums="$($TIMEOUT gh issue list "${args[@]}")"

# Column order here MUST match the per-row jq below: the jq emits
# created..title and the trailing `sed` prepends `number`. Keep the two in sync.
printf 'number\tcreated\tpriority\tstatus\tassignees\topen_prs\ttitle\n'
[ -z "$nums" ] && exit 0

# Track whether any per-issue enrichment was dropped. A partial result must be
# distinguishable from a genuinely-empty queue (exit 3), so a caller — the
# session-start nudge — can fail closed and keep its last-known-good cache rather
# than mistake a rate-limit/timeout for "no tickets" and erase valid reminders.
partial=0
for n in $nums; do
  # One GraphQL call per issue. projectItems (with each item's project.number)
  # gives Priority/Status — jq keeps only the PROJECT_NUMBER board's values, so a
  # field from some other project the issue also sits on can't leak in. Linked
  # PRs use the robust pattern (CONNECTED_EVENT + closedByPullRequestsReferences,
  # incl. closed) — NOT CROSS_REFERENCED, which would count any PR that merely
  # mentions the issue; we then keep only state==OPEN. Same linkage /queue:ship-queue
  # documents.
  # Per-issue enrichment is best-effort: `|| continue` so one transient GraphQL
  # failure (a rate-limit blip mid-drain) skips that row instead of aborting the
  # whole list under `set -e` — a truncated table is worse than one missing row.
  $TIMEOUT gh api graphql -f query='
    query($owner:String!,$repo:String!,$num:Int!){
      repository(owner:$owner,name:$repo){
        issue(number:$num){
          title
          createdAt
          assignees(first:10){ nodes{ login } }
          projectItems(first:20){ nodes{
            project{ number }
            fieldValues(first:20){ nodes{
              ... on ProjectV2ItemFieldSingleSelectValue{ name field{ ... on ProjectV2FieldCommon{ name } } }
            }}
          }}
          connected: timelineItems(first:30, itemTypes:[CONNECTED_EVENT]){ nodes{
            ... on ConnectedEvent{ subject{ ... on PullRequest{ number state } } }
          }}
          closedBy: closedByPullRequestsReferences(first:20, includeClosedPrs:true){ nodes{ number state } }
        }
      }
    }' -f owner="$OWNER" -f repo="$NAME" -F num="$n" --jq '
      (env.PROJECT_NUMBER | tonumber) as $proj
      | .data.repository.issue as $i
      | ($i.createdAt | split("T")[0]) as $created
      | [$i.projectItems.nodes[] | select(.project.number == $proj) | .fieldValues.nodes[]] as $fv
      | ([$fv[] | select(.field.name=="Priority") | .name] | first // "-") as $priority
      | ([$fv[] | select(.field.name=="Status")   | .name] | first // "-") as $status
      | ([$i.assignees.nodes[].login] | join(", ")) as $assignees
      # Genuinely-linked PRs only (Development link + closing refs), OPEN ones —
      # incidental cross-references are excluded by construction.
      | ([$i.connected.nodes[].subject, $i.closedBy.nodes[]]
          | map(select(.number != null and .state=="OPEN"))
          | unique_by(.number) | map("#\(.number)") | join(", ")) as $prs
      # Neutralize the TSV/markdown separators (tab, CR, LF, pipe) in the
      # untrusted issue title: a title with a literal tab would shift every
      # downstream column (mis-parsed status/PR), and a pipe would break the
      # markdown table the caller renders. Also shrinks the prompt-injection
      # surface when the title lands in session additionalContext.
      | ($i.title | gsub("[\t\r\n|]"; " ")) as $title
      | "\($created)\t\($priority)\t\($status)\t\(if $assignees=="" then "-" else $assignees end)\t\(if $prs=="" then "-" else $prs end)\t\($title)"
    ' | sed "s|^|$n\t|" || { partial=1; continue; }
done

# Any dropped row makes this a partial result — signal it, don't pass it off clean.
if [ "$partial" -eq 1 ]; then exit 3; fi
