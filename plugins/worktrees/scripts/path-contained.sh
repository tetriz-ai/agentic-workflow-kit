# shellcheck shell=bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# path-contained.sh: decide whether writing a path stays inside a folder. Sourced, never executed.
# A script that writes into a user's repo checks each destination with it first, so a symlink in
# the repo, at the file or at any folder above it, can never make the kit change a file outside.
#
#   resolve_path <path>
# prints the absolute physical path <path> leads to, following every symlink on the way, the
# last one included. The path need not exist, so a dangling link resolves to where it points.
# Returns 1 on a symlink loop.
#
#   path_contained <root> <path>
# returns 0 when <path> resolves inside <root> (itself resolved), 1 when it leads outside, cannot
# be resolved, or keeps a `..` in a part that does not exist yet. Prints the resolved path.

resolve_path() {
  local p="$1" t d n=0
  while [ -L "$p" ]; do
    n=$((n + 1)); [ "$n" -le 40 ] || return 1
    t="$(readlink "$p")"
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
  done
  d="$(dirname "$p")"
  if [ -d "$d" ]; then d="$(cd -P "$d" && pwd)" || return 1
  elif [ "$d" = "$p" ]; then return 1
  else d="$(resolve_path "$d")" || return 1; fi
  printf '%s/%s' "${d%/}" "$(basename "$p")"
}

path_contained() {
  local root real
  root="$(cd -P "$1" 2>/dev/null && pwd)" || return 1
  real="$(resolve_path "$2")" || return 1
  printf '%s' "$real"
  # A `..` left in a part that does not exist yet cannot be judged, so it counts as outside.
  case "$real" in */../*|*/..) return 1 ;; esac
  case "$real" in "$root"/*) return 0 ;; *) return 1 ;; esac
}
