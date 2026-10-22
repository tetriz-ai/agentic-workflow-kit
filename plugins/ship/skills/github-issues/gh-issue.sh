#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# gh-issue.sh — token-cheap GitHub issue creation + project triage in ONE call.
# The GraphQL never lands in the agent's context and the whole flow returns a
# single compact result line, instead of the hand-run create → item-add →
# item-id resolve → four field edits. Priority defaults to P1 and Version is
# auto-resolved to the current release; the rationale for both conventions lives
# in labels.md ("Priority convention" / "Version convention").
#
# Settings (kit-config.sh): repo_slug (blank: `gh repo view`), github_project
# (`owner/number` of a GitHub Project; blank: no board, so only the issue is
# created), github_project_version_fallback (the Version a new issue gets when no current
# release resolves; blank: Version is left unset). GH_ISSUE_REPO / GH_ISSUE_PROJECT, when
# set, win over the settings.
#
# Field / option IDs are fetched LIVE from the project by name (never hardcoded),
# so a new Version option added on the board is picked up with no script change.
#
# Subcommands:
#   create --title T [--body B | --body-file F] [--label L]... [--assignee A]
#          [--priority NAME] [--version NAME] [--estimate N] [--status S]
#              create the issue, add it to the project, set Status/Priority/
#              Version/Estimate, print one compact result line. Every value is
#              checked against the board before the issue is created; a field the
#              board lacks is skipped with a note. Exits non-zero if the issue was
#              created but a field could not be set (the ISSUE: line still prints
#              first, so the URL is never lost).
#   version     print the auto-resolved current Version (name) and its option id.
#   fields      print the live field/option id map (debugging).

set -uo pipefail

command -v gh >/dev/null 2>&1 || { echo "gh-issue: 'gh' not installed/authed" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "gh-issue: 'jq' not installed" >&2; exit 1; }

# shellcheck source=../../scripts/kit-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/kit-config.sh" \
  || { echo "gh-issue: settings resolver missing" >&2; exit 1; }

SLUG=$(kit_config repo_slug "${GH_ISSUE_REPO:-}")
[ -n "$SLUG" ] || SLUG=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
OWNER="${SLUG%/*}"; REPO="${SLUG#*/}"
PROJECT=$(kit_config github_project "${GH_ISSUE_PROJECT:-}")
VERSION_FALLBACK=$(kit_config github_project_version_fallback)   # also excluded from the current-release vote
PROJECT_OWNER=""; PROJECT_NUM=""; PROJECT_ID=""
if [ -n "$PROJECT" ]; then
  PROJECT_OWNER="${PROJECT%/*}"; PROJECT_NUM="${PROJECT##*/}"
  case "$PROJECT_NUM" in ''|*[!0-9]*) echo "gh-issue: github_project must be owner/number (got '$PROJECT')" >&2; exit 2 ;; esac
fi

# gh api graphql can emit ANSI-colored JSON (TTY/config dependent); strip the
# escapes before jq, or jq chokes on them. Same guard codex-sweep.sh uses.
# pipefail preserves gh's exit code through the pipe so callers can still detect
# a failed query.
gql() { gh api graphql "$@" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g'; }

# ── live field metadata ─────────────────────────────────────────────────────
# One query fetches every project field's id plus every single-select option's
# id+name. load_fields caches it in the _FIELDS_JSON PARENT-scope global; the
# field_id/option_id readers take it as a here-string (`<<<`) rather than piping
# `load_fields`, so the fetch stays in the caller's shell and truly runs once —
# piping the loader would run it in a subshell and lose the cache every call.
_FIELDS_JSON=""
load_fields() {
  [ -n "$_FIELDS_JSON" ] && return 0
  [ -n "$PROJECT_NUM" ] || { echo "gh-issue: no github_project configured" >&2; return 1; }
  local out project
  # A project belongs to an organization or a user; repositoryOwner covers both.
  out=$(gql -f owner="$PROJECT_OWNER" -F num="$PROJECT_NUM" -f query='
    query($owner:String!,$num:Int!){
      repositoryOwner(login:$owner){
        ... on Organization { projectV2(number:$num){ ...P } }
        ... on User { projectV2(number:$num){ ...P } }
      }
    }
    fragment P on ProjectV2 { id fields(first:50){ nodes{
      __typename
      ... on ProjectV2FieldCommon { id name }
      ... on ProjectV2SingleSelectField { id name options { id name } }
    } } }') || { echo "gh-issue: could not read project fields (gh auth? project $PROJECT?)" >&2; return 1; }
  project=$(printf '%s' "$out" | jq -c '.data.repositoryOwner.projectV2 // empty')
  [ -n "$project" ] || { echo "gh-issue: project $PROJECT not found" >&2; return 1; }
  PROJECT_ID=$(printf '%s' "$project" | jq -r '.id')
  _FIELDS_JSON=$(printf '%s' "$project" | jq -c '.fields.nodes')
  [ "$_FIELDS_JSON" != "null" ] && [ -n "$_FIELDS_JSON" ] || { echo "gh-issue: empty project field metadata" >&2; return 1; }
}

field_id()  { jq -r --arg n "$1" '.[] | select(.name==$n) | .id' <<<"$_FIELDS_JSON" | head -1; }
# option_id <field-name> <option-name>  (exact, then case-insensitive fallback)
option_id() {
  local id
  id=$(jq -r --arg f "$1" --arg o "$2" '.[] | select(.name==$f) | .options[]? | select(.name==$o) | .id' <<<"$_FIELDS_JSON" | head -1)
  [ -z "$id" ] && id=$(jq -r --arg f "$1" --arg o "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" '.[] | select(.name==$f) | .options[]? | select((.name|ascii_downcase)==$o) | .id' <<<"$_FIELDS_JSON" | head -1)
  printf '%s' "$id"
}

# ── current-version resolution ──────────────────────────────────────────────
# The current release = the most frequent Version among the 20 most-recently
# CREATED issues; an equal-count tie breaks toward the most recent. The query
# orders by CREATED_AT DESC explicitly (not `last:20`'s implicit order), so the
# jq sees the list most-recent-first and `first(... count==max)` returns the
# most-recent winner. The github_project_version_fallback value is excluded from the
# vote — it is the fallback, never the resolved release. NOTE: this is a *lagging* signal — right
# after a release is cut, recent issues still carry the previous release, so
# callers targeting a just-cut or future release must pass --version explicitly.
resolve_current_version() {
  local out
  # The project filter is applied in jq (select .project.number), so the query
  # takes no $num — GitHub rejects a declared-but-unused GraphQL variable.
  out=$(gql -f owner="$OWNER" -f name="$REPO" -f query='
    query($owner:String!,$name:String!){
      repository(owner:$owner,name:$name){ issues(first:20, orderBy:{field:CREATED_AT, direction:DESC}){ nodes{
        projectItems(first:5){ nodes{
          project{ number }
          fieldValueByName(name:"Version"){ ... on ProjectV2ItemFieldSingleSelectValue { name } }
        } }
      } } }
    }') || return 1
  printf '%s' "$out" | jq -r --argjson num "$PROJECT_NUM" --arg nv "$VERSION_FALLBACK" '
    [ .data.repository.issues.nodes[]
      | (.projectItems.nodes // [])[]        # an issue with no project items -> skip, not error
      | select(.project.number==$num)
      | .fieldValueByName.name
      | select(. != null and . != $nv) ] as $v          # $v is most-recent-first (CREATED_AT DESC)
    | ($v | group_by(.) | map({v: .[0], n: length})) as $g
    | ($g | map(.n) | max // 0) as $mx
    | first($v[] | select(. as $x | any($g[]; .v == $x and .n == $mx))) // empty'
}

cmd_version() {
  [ -n "$PROJECT_NUM" ] || { echo "current version: (no github_project configured)"; return 0; }
  local v
  v=$(resolve_current_version) || { echo "gh-issue: version: current-version lookup failed (transient GitHub error / auth?)" >&2; return 1; }
  if [ -z "$v" ]; then echo "current version: (unresolved — recent issues carry none)"; return 0; fi
  load_fields || return 1
  printf 'current version: %s  (option id: %s)\n' "$v" "$(option_id Version "$v")"
}

cmd_fields() { load_fields || return 1; jq -r '.[] | "\(.name)\t\(.id)\t\((.options // []) | map(.name) | join(","))"' <<<"$_FIELDS_JSON"; }

cmd_create() {
  local title="" body="" bodyfile="" assignee="@me" priority="P1" version="" estimate="0.1" status="Todo"
  local explicit=" "   # the board fields the caller set explicitly
  local -a labels=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --title|--body|--body-file|--label|--assignee|--priority|--version|--estimate|--status)
        [ $# -ge 2 ] || { echo "gh-issue: create: $1 needs a value" >&2; return 2; } ;;
    esac
    case "$1" in
      --title)     title="$2"; shift 2 ;;
      --body)      body="$2"; shift 2 ;;
      --body-file) bodyfile="$2"; shift 2 ;;
      --label)     labels+=("$2"); shift 2 ;;
      --assignee)  assignee="$2"; shift 2 ;;
      --priority)  priority="$2"; explicit="${explicit}Priority "; shift 2 ;;
      --version)   version="$2"; explicit="${explicit}Version "; shift 2 ;;
      --estimate)  estimate="$2"; explicit="${explicit}Estimate "; shift 2 ;;
      --status)    status="$2"; explicit="${explicit}Status "; shift 2 ;;
      *) echo "gh-issue: create: unknown flag '$1'" >&2; return 2 ;;
    esac
  done
  [ -n "$title" ] || { echo "gh-issue: create: --title is required" >&2; return 2; }
  [ ${#labels[@]} -gt 0 ] || { echo "gh-issue: create: at least one --label is required (a primary type or area label)" >&2; return 2; }
  [[ "$estimate" =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]] \
    || { echo "gh-issue: create: --estimate must be a decimal number of days (e.g. 0.1), got '$estimate'" >&2; return 2; }
  # Reject values that would smuggle a flag into gh's own parser (a value starting
  # with '-'). Labels / versions / assignees never legitimately start with '-'.
  for v in "$assignee" "$version" "${labels[@]}"; do
    case "$v" in -*) echo "gh-issue: create: value '$v' may not start with '-'" >&2; return 2 ;; esac
  done

  [ -n "$OWNER" ] && [ -n "$REPO" ] && [ "$OWNER" != "$SLUG" ] \
    || { echo "gh-issue: create: could not resolve the repo (set repo_slug, or run inside a GitHub checkout)" >&2; return 1; }

  # ── validate every board field before anything is created (no orphan) ──
  # A field the board does not have is skipped with a note; an explicit value for it is
  # an error. An explicit value that names no option is an error; a default that names
  # no option (a board without "Todo" or "P1") is skipped with a note.
  local skipped="" set_status=1 set_priority=1 set_version=1 set_estimate=1
  if [ -n "$PROJECT_NUM" ]; then
    load_fields || return 1
    check_ss() { # check_ss <field> <value> -> 0 set it | 1 skip it (noted) | 2 reject
      if [ -z "$(field_id "$1")" ]; then
        case "$explicit" in *" $1 "*) echo "gh-issue: create: project $PROJECT has no $1 field (drop --$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'))" >&2; return 2 ;; esac
        skipped="$skipped $1"; return 1
      fi
      [ -n "$(option_id "$1" "$2")" ] && return 0
      case "$explicit" in *" $1 "*)
        echo "gh-issue: create: --$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') '$2' is not a $1 option on project $PROJECT (run 'gh-issue.sh fields')" >&2; return 2 ;;
      esac
      skipped="$skipped $1(no '$2' option)"; return 1
    }
    check_ss Status "$status";     case $? in 1) set_status=0 ;; 2) return 2 ;; esac
    check_ss Priority "$priority"; case $? in 1) set_priority=0 ;; 2) return 2 ;; esac
    if [ -z "$(field_id Version)" ]; then
      check_ss Version "$version"; case $? in 1) set_version=0 ;; 2) return 2 ;; esac
    elif [ -z "$version" ]; then
      # Distinguish a resolver ERROR (query failed — rate-limit / auth / transient)
      # from a successful-but-empty result: only the latter takes the fallback.
      # A failed lookup must NOT silently mis-file a routine issue.
      version=$(resolve_current_version) || { echo "gh-issue: create: current-version lookup failed (transient GitHub error / auth?) — re-run, or pass --version" >&2; return 1; }
      [ -n "$version" ] || version="$VERSION_FALLBACK"
      if [ -z "$version" ]; then
        skipped="$skipped Version(no current release; set github_project_version_fallback or pass --version)"; set_version=0
      else
        check_ss Version "$version"; case $? in 1) set_version=0 ;; 2) return 2 ;; esac
      fi
    else
      check_ss Version "$version"; case $? in 1) set_version=0 ;; 2) return 2 ;; esac
    fi
    if [ -z "$(field_id Estimate)" ]; then
      case "$explicit" in *" Estimate "*) echo "gh-issue: create: project $PROJECT has no Estimate field (drop --estimate)" >&2; return 2 ;; esac
      skipped="$skipped Estimate"; set_estimate=0
    fi
  fi

  # ── create the issue ──
  local -a create_args=(--repo "$OWNER/$REPO" --title "$title" --assignee "$assignee")
  for l in "${labels[@]}"; do create_args+=(--label "$l"); done
  if [ -n "$bodyfile" ]; then create_args+=(--body-file "$bodyfile")
  elif [ -n "$body" ]; then create_args+=(--body "$body")
  else create_args+=(--body "$title"); fi

  local url; url=$(gh issue create "${create_args[@]}") || { echo "gh-issue: issue create failed" >&2; return 1; }
  url=$(printf '%s' "$url" | grep -oE 'https://[^/[:space:]]+/[^[:space:]]+/issues/[0-9]+' | head -1)   # github.com or a GitHub Enterprise host
  local num="${url##*/}"
  [ -n "$num" ] || { echo "gh-issue: could not parse issue number from create output" >&2; return 1; }

  # The issue now exists — surface its URL immediately, so it is never lost even
  # if the triage below aborts.
  printf 'ISSUE: #%s  %s\n' "$num" "$url"

  if [ -z "$PROJECT_NUM" ]; then
    printf 'labels=%s  board=none (github_project not set; priority, version, estimate and status not applied)\n' "$(IFS=,; echo "${labels[*]}")"
    return 0
  fi

  # ── add to the board (idempotent: an item that already exists is fine) ──
  local add_err; add_err=$(gh project item-add "$PROJECT_NUM" --owner "$PROJECT_OWNER" --url "$url" 2>&1 >/dev/null) || true

  # ── resolve the item id via the issue's OWN projectItems edge (O(1)) ──
  # Filter with our own jq (not gh's --jq) so the flow is uniform and stub-testable.
  local item_id
  item_id=$(gql -f owner="$OWNER" -f name="$REPO" -F num="$num" -f query='
    query($owner:String!,$name:String!,$num:Int!){
      repository(owner:$owner,name:$name){ issue(number:$num){ projectItems(first:10){ nodes{ id project{ number } } } } }
    }' | jq -r --argjson pnum "$PROJECT_NUM" '.data.repository.issue.projectItems.nodes[] | select(.project.number==$pnum) | .id' | head -1)
  if [ -z "$item_id" ]; then
    echo "gh-issue: WARN — issue #$num created but not on project $PROJECT; triage it by hand${add_err:+ (item-add failed: $add_err)}" >&2
    return 1
  fi

  # ── set the fields ── (failures noted, not fatal — the issue already exists)
  local warn=""
  set_ss() { # set_ss <field-name> <option-name>
    local fid oid; fid=$(field_id "$1"); oid=$(option_id "$1" "$2")
    gh project item-edit --project-id "$PROJECT_ID" --id "$item_id" --field-id "$fid" --single-select-option-id "$oid" >/dev/null 2>&1 \
      || warn="$warn ${1}=setfailed"
  }
  [ "$set_status" = 1 ]   && set_ss Status   "$status"
  [ "$set_priority" = 1 ] && set_ss Priority "$priority"
  [ "$set_version" = 1 ]  && set_ss Version  "$version"
  if [ "$set_estimate" = 1 ]; then
    gh project item-edit --project-id "$PROJECT_ID" --id "$item_id" --field-id "$(field_id Estimate)" --number "$estimate" >/dev/null 2>&1 \
      || warn="$warn Estimate=setfailed"
  fi

  printf 'labels=%s  priority=%s  version=%s  estimate=%s  status=%s\n' "$(IFS=,; echo "${labels[*]}")" "$priority" "${version:-none}" "$estimate" "$status"
  [ -z "$skipped" ] || printf 'note — not on the board:%s (not set)\n' "$skipped"
  # A field that would not set is a real triage gap — report it AND exit non-zero
  # so a caller branching on the exit code sees the partial failure.
  [ -n "$warn" ] && { printf 'WARN — some fields not set:%s (fix by hand)\n' "$warn"; return 1; }
  return 0
}

usage() { echo "usage: gh-issue.sh create --title T --label L [--body B|--body-file F] [--priority P1] [--version NAME] [--estimate N] [--assignee A] [--status S] | version | fields"; }

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  create)  shift; cmd_create "$@" ;;
  version) shift; cmd_version "$@" ;;
  fields)  shift; cmd_fields "$@" ;;
  *) usage >&2; exit 2 ;;
esac
