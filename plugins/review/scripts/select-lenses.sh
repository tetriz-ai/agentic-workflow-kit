#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# select-lenses.sh: pick the opt-in review lenses that apply to a diff.
#
# Usage: select-lenses.sh --changed <file of changed paths, one per line> <lens folder>...
#
# Each *.md in a lens folder is a lens file with a YAML header:
#   ---
#   lens: database-migrations          the lens name (defaults to the file name)
#   applies-to:                        required: repo-relative globs, one per item
#     - "**/migrations/**"
#   needs-setting: some_setting        optional: offer the lens only when it resolves non-blank
#   summary: one line                  optional
#   ---
# Globs: `**` matches any number of path segments (none included), `*` and `?` stay inside one
# segment, `{a,b}` is a set of alternatives; a glob with no `/` matches only at the repo root.
#
# Prints the selected lens files, one per line. Folders are read in the order given and a later
# folder's lens replaces an earlier one with the same name, so a team's .claude/review-lenses
# overrides a plugin lens by naming the repo folder last. A folder that does not exist is
# skipped (the plugin may not be installed). A needs-setting key resolves through the
# kit-config.sh of the plugin that ships the lens (<folder>/../scripts/), else this plugin's.
# Exit: 0 selection printed (possibly none) | 2 usage error, unreadable changed-paths file, or a
# lens file with no applies-to or a malformed glob (named on stderr; fix the file, do not skip it).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { echo "usage: select-lenses.sh --changed <changed-paths file> <lens folder>..." >&2; exit 2; }
[ "${1:-}" = "--changed" ] && [ -n "${2:-}" ] || usage
CHANGED="$2"; shift 2
[ -r "$CHANGED" ] || { echo "select-lenses: cannot read changed-paths file: $CHANGED" >&2; exit 2; }
[ "$#" -gt 0 ] || usage

# glob_to_ere <glob>: an anchored ERE for one glob, braces expanded into alternatives.
glob_to_ere() {
  printf '%s' "$1" | awk '
    function esc(c) { return (index(".^$+()|[]\\", c) ? "\\" c : c) }
    {
      s = $0; out = ""; i = 1; n = length(s); depth = 0
      while (i <= n) {
        c = substr(s, i, 1)
        if (substr(s, i, 3) == "**/") { out = out "(.*/)?"; i += 3; continue }
        if (substr(s, i, 2) == "**")  { out = out ".*"; i += 2; continue }
        if (c == "*") { out = out "[^/]*"; i++; continue }
        if (c == "?") { out = out "[^/]"; i++; continue }
        if (c == "{") { out = out "("; depth++; i++; continue }
        if (c == "}" && depth > 0) { out = out ")"; depth--; i++; continue }
        if (c == "," && depth > 0) { out = out "|"; i++; continue }
        out = out esc(c); i++
      }
      if (depth > 0) exit 1
      print "^" out "$"
    }'
}

# Shared awk: unquote(v) strips one pair of matching double or single quotes.
AWK_UNQUOTE='function unquote(v,  a, z) { a = substr(v, 1, 1); z = substr(v, length(v), 1)
  if (length(v) >= 2 && a == z && (a == "\"" || a == q)) v = substr(v, 2, length(v) - 2); return v }'

# header_field <file> <key>: the value of a scalar header key.
header_field() {
  awk -v k="$2" -v q="'" "$AWK_UNQUOTE"'
    NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit }
    NR > 1 && index($0, k ":") == 1 { v = substr($0, length(k) + 2); gsub(/^[ \t]+|[ \t\r]+$/, "", v); print unquote(v); exit }' "$1"
}

# header_globs <file>: the applies-to items, one per line.
header_globs() {
  awk -v q="'" "$AWK_UNQUOTE"'
    NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit }
    NR > 1 && /^applies-to:[ \t]*$/ { inlist = 1; next }
    NR > 1 && inlist {
      if ($0 ~ /^[ \t]*-[ \t]+/) { v = $0; sub(/^[ \t]*-[ \t]+/, "", v); gsub(/[ \t\r]+$/, "", v); print unquote(v); next }
      if ($0 ~ /^[ \t]*(#.*)?$/) next
      inlist = 0
    }' "$1"
}

names=(); files=(); bad=0
for dir in "$@"; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    globs="$(header_globs "$f")"
    if [ -z "$globs" ]; then echo "select-lenses: $f has no applies-to globs" >&2; bad=1; continue; fi
    name="$(header_field "$f" lens)"; [ -n "$name" ] || name="$(basename "$f" .md)"
    need="$(header_field "$f" needs-setting)"
    if [ -n "$need" ]; then
      cfg="$(cd "$dir/.." 2>/dev/null && pwd)/scripts/kit-config.sh"; [ -r "$cfg" ] || cfg="$HERE/kit-config.sh"
      if [ -z "$(bash "$cfg" get "$need" 2>/dev/null)" ]; then
        echo "select-lenses: $name not offered: setting $need is blank" >&2
        for i in "${!names[@]}"; do [ "${names[$i]}" = "$name" ] && files[$i]=""; done
        continue
      fi
    fi
    match=""
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      re="$(glob_to_ere "$g")" || { echo "select-lenses: $f has a malformed glob: $g (an unclosed {)" >&2; bad=1; continue; }
      grep -Eq "$re" "$CHANGED"; rc=$?
      [ "$rc" -le 1 ] || { echo "select-lenses: $f has a malformed glob: $g" >&2; bad=1; continue; }
      if [ "$rc" -eq 0 ]; then match=1; break; fi
    done <<<"$globs"
    # A later folder replaces an earlier lens of the same name, matched or not.
    found=""
    for i in "${!names[@]}"; do
      if [ "${names[$i]}" = "$name" ]; then found=1; files[$i]="${match:+$f}"; fi
    done
    [ -n "$found" ] || { names+=("$name"); files+=("${match:+$f}"); }
  done
done
[ "$bad" -eq 0 ] || exit 2
for f in "${files[@]:-}"; do [ -n "$f" ] && printf '%s\n' "$f"; done
exit 0
