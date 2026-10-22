#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# append-review-rule.sh: append one picked review-rule candidate to the team rules file, in the
# format the review panel's team-rules lens reads.
#
# Usage: append-review-rule.sh --file <rules file> --prefix <ID prefix> --title <title>
#          --statement <one-line rule> --apply-to <files or diff shapes> [--evidence <PRs>]
#
# The rule gets the next free id for the prefix (one past the highest existing <PREFIX>-NNN, so
# hand-numbered gaps are kept). A missing file is created with a short heading. Prints the new id.
# Exit: 0 appended | 2 usage (prefix not 2 to 8 capitals, a missing field, a field with a
#       newline) | 3 a rule with the same title (any case) already exists; nothing is written.
set -uo pipefail

usage() { echo "usage: append-review-rule.sh --file F --prefix ABC --title T --statement S --apply-to A [--evidence E]" >&2; exit 2; }
file="" prefix="" title="" statement="" apply="" evidence=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file|--prefix|--title|--statement|--apply-to|--evidence) [ $# -ge 2 ] || usage ;;
    *) echo "append-review-rule: unknown flag '$1'" >&2; usage ;;
  esac
  case "$1" in
    --file) file="$2" ;; --prefix) prefix="$2" ;; --title) title="$2" ;;
    --statement) statement="$2" ;; --apply-to) apply="$2" ;; --evidence) evidence="$2" ;;
  esac
  shift 2
done
[ -n "$file" ] && [ -n "$title" ] && [ -n "$statement" ] && [ -n "$apply" ] || usage
[[ "$prefix" =~ ^[A-Z]{2,8}$ ]] || { echo "append-review-rule: --prefix must be 2 to 8 capital letters (got '$prefix')" >&2; exit 2; }
nl=$'\n'
for v in "$title" "$statement" "$apply" "$evidence"; do
  case "$v" in *"$nl"*) echo "append-review-rule: a field may not contain a newline" >&2; exit 2 ;; esac
done

if [ -f "$file" ]; then
  # The title goes in through the environment: `awk -v` would turn a backslash in it into an escape.
  if RULE_TITLE="$title" awk 'BEGIN { t = tolower(ENVIRON["RULE_TITLE"]) } /^## [A-Z]+-[0-9]+: / { sub(/^## [A-Z]+-[0-9]+: /, ""); if (tolower($0) == t) found = 1 } END { exit !found }' "$file"; then
    echo "append-review-rule: a rule titled '$title' already exists in $file" >&2
    exit 3
  fi
  last=$(grep -oE "^## ${prefix}-[0-9]+:" "$file" | sed -E "s/^## ${prefix}-0*([0-9]+):/\\1/" | sort -n | tail -1)
else
  mkdir -p "$(dirname "$file")"
  printf '# Team review rules\n\nThe review panel'"'"'s team-rules lens applies these rules to every non-docs diff. Each rule is\na `## <ID>: <title>` heading, a one-line statement, and an `Apply to:` line.\n' > "$file"
  last=""
fi
id=$(printf '%s-%03d' "$prefix" $(( ${last:-0} + 1 )))
{
  printf '\n## %s: %s\n\n%s\n\nApply to: %s\n' "$id" "$title" "$statement" "$apply"
  [ -z "$evidence" ] || printf 'Evidence: %s\n' "$evidence"
} >> "$file"
printf '%s\n' "$id"
