# shellcheck shell=bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# bridge-install.sh: the copy step the sync scripts share. Sourced, never executed.
#
#   bridge_install_tree <src-dir> <dst-dir> <force 0|1>
# copies every file under <src-dir> into <dst-dir>, keeping modes. A file that does
# not exist yet is added; an identical file is left alone; a file that differs is
# kept as it is (a local edit wins) unless force is 1, when it is replaced. Prints
# one line per added, replaced or kept file and returns 0. Source and destination
# being the same folder is a no-op.
#
#   bridge_check_path <path>   and   bridge_check_tree <src-dir> <dst-dir>
# return 2, with a message, when the path, or any file the tree would write, leads out of the
# repo through a symlink; the sync scripts call them before writing anything, and the install
# and link functions repeat the check for each write.

# shellcheck source=path-contained.sh
. "$(dirname "${BASH_SOURCE[0]}")/path-contained.sh"

bridge_check_path() {
  local root real
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "  not inside a git repo; refusing to write $1" >&2; return 2; }
  case "$1" in /*) real="$1" ;; *) real="$PWD/$1" ;; esac
  real="$(path_contained "$root" "$real")" && return 0
  echo "  $1 leads to ${real:-a path that cannot be resolved}, outside the repo ($root), through a symlink; refusing to write it. Nothing was written." >&2
  return 2
}

bridge_check_tree() {
  local src="$1" dst="$2" s
  [ -d "$src" ] || return 0
  bridge_check_path "$dst" || return 2
  while IFS= read -r -d '' s; do
    bridge_check_path "$dst/${s#"$src"/}" || return 2
  done < <(find "$src" -type f -print0)
}

bridge_install_tree() {
  local src="$1" dst="$2" force="${3:-0}" rel s d
  [ -d "$src" ] || return 0
  src="$(cd "$src" && pwd -P)"
  bridge_check_tree "$src" "$dst" || return 2
  mkdir -p "$dst"
  dst="$(cd "$dst" && pwd -P)"
  [ "$src" = "$dst" ] && return 0
  while IFS= read -r -d '' s; do
    rel="${s#"$src"/}"
    d="$dst/$rel"
    if [ ! -e "$d" ]; then
      mkdir -p "$(dirname "$d")"
      cp -p "$s" "$d"
      echo "  added    $rel"
    elif cmp -s "$s" "$d"; then
      :
    elif [ "$force" = 1 ]; then
      cp -p "$s" "$d"
      echo "  replaced $rel"
    else
      echo "  kept     $rel (differs from the kit's copy; --force replaces it)"
    fi
  done < <(find "$src" -type f -print0 | sort -z)
}

# bridge_link <link> <target>: create a relative symlink when nothing exists at <link>;
# leave an existing correct link alone; report anything else and return 1.
bridge_link() {
  local link="$1" target="$2"
  bridge_check_path "$link" || return 2
  if [ -L "$link" ]; then
    [ "$(readlink "$link")" = "$target" ] && return 0
    echo "  $link points at $(readlink "$link"), expected $target" >&2
    return 1
  elif [ -e "$link" ]; then
    echo "  $link exists and is not a symlink to $target; left as is" >&2
    return 1
  fi
  mkdir -p "$(dirname "$link")"
  ln -s "$target" "$link"
  echo "  linked   $link -> $target"
}
