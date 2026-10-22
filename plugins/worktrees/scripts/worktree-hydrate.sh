#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Hydrate a freshly-created git worktree with the local, gitignored files a
# checkout needs to actually run (.env, *-development.local.yml, dev secrets, …)
# by copying them from the MAIN checkout per the repo-root .worktreeinclude.
#
# Why this exists: a plain `git worktree add` or Claude's EnterWorktree produces
# a worktree with none of these local files, so servers would not start until you
# hand-copied them. This script is the single shared implementation of the
# `.worktreeinclude` contract; two thin entry points call it: a git
# post-checkout hook (fires on `git worktree add`; the starter plugin ships one)
# and the PostToolUse:EnterWorktree hook in this plugin.
#
# Contract:
#   - arg $1 (optional): worktree root to hydrate. Defaults to $PWD.
#   - Only ever hydrates a LINKED worktree, never the main checkout.
#   - Idempotent: a file already present in the worktree is left untouched.
#   - Never writes through a symlink that leads out of the worktree (that file is skipped).
#   - Non-fatal by design: always exits 0 so it can never block worktree
#     creation. Problems are printed, not raised.
#
# Portability: must run on macOS's stock bash 3.2 — no globstar, no `declare -A`.
# Honours literal paths + trailing dir/** (expanded via find); richer globs rejected.
#
# Heavy deps (node_modules, a Python .venv) are deliberately NOT handled here:
# they break when copied (platform binaries, internal symlinks) and belong to
# the package manager's install step in the worktree.

set -uo pipefail

WT="${1:-$PWD}"

log() { printf '[worktree-hydrate] %s\n' "$*"; }

# A destination that leads out of the worktree through a symlink is never written.
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$_HERE/path-contained.sh" ]; then
  # shellcheck source=path-contained.sh
  . "$_HERE/path-contained.sh"
else
  log "path-contained.sh is missing beside this script, so destinations cannot be checked; copying nothing"
  exit 0
fi

# Resolve to an absolute path without requiring the dir to pre-exist on $1.
abspath() { (cd "$1" 2>/dev/null && pwd) || return 1; }

WT="$(abspath "$WT")" || { log "worktree path not found: ${1:-$PWD}"; exit 0; }

# Must be inside a git worktree.
gitdir="$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
commondir="$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
# Main checkout: git-dir == common-dir. We never hydrate main onto itself.
[ "$gitdir" = "$commondir" ] && exit 0

# The MAIN checkout root is the first entry of `git worktree list` (porcelain).
MAIN="$(git -C "$WT" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')"
[ -n "$MAIN" ] && MAIN="$(abspath "$MAIN")"
if [ -z "${MAIN:-}" ] || [ "$MAIN" = "$WT" ]; then
  log "could not resolve main checkout; skipping"
  exit 0
fi

# Rules come from the tracked .worktreeinclude (worktree copy first, else main's).
# It is tracked, so a normal checkout always has it; if it is genuinely absent
# there is nothing to hydrate.
rules_src=""
if [ -f "$WT/.worktreeinclude" ]; then rules_src="$WT/.worktreeinclude"
elif [ -f "$MAIN/.worktreeinclude" ]; then rules_src="$MAIN/.worktreeinclude"; fi
if [ -z "$rules_src" ]; then
  log "no .worktreeinclude in worktree or main checkout; nothing to hydrate"
  exit 0
fi

# Reject patterns that could spread credentials or escape the repo.
dangerous() {
  case "$1" in
    '*'|'**'|'**/*') return 0 ;;
    /*) return 0 ;;        # absolute
    \~/*) return 0 ;;      # home dir
    *..*) return 0 ;;      # parent traversal
    .ssh/*|.aws/*) return 0 ;;
  esac
  return 1
}

# bash 3.2 has no globstar, so trailing ** is expanded with find. Callers reject
# unsupported globs first (unsupported_glob), so only the two honoured shapes
# reach here; stdout is the file list the caller reads.
match_files() {
  case "$1" in
    */\*\*)
      # Trailing dir/** — recurse the dir. -L follows symlinked secrets (some
      # setups symlink a secrets folder's files into a vault).
      prefix="${1%/\*\*}"
      [ -d "$MAIN/$prefix" ] && find -L "$MAIN/$prefix" -type f 2>/dev/null
      ;;
    *)
      [ -f "$MAIN/$1" ] && printf '%s\n' "$MAIN/$1"
      ;;
  esac
}

# The hook honours only literal paths + trailing dir/**. Every other glob shape
# (mid-path **, single-level *, ?) is unsupported: reimplementing doublestar in
# bash 3.2 risks silent over-copy, and no .worktreeinclude rule needs it.
unsupported_glob() {
  case "$1" in
    */\*\*) return 1 ;;              # trailing dir/** is honoured
    *\*\**|*'*'*|*'?'*) return 0 ;;  # any other glob is not
    *) return 1 ;;                    # literal path
  esac
}

copied=0; skipped=0; missing_required=0

process_rule() {
  kind="$1"; pattern="$2"
  if dangerous "$pattern"; then
    log "ignoring unsafe pattern: $pattern" >&2
    return
  fi
  # Reject unsupported globs here, before the match accounting — otherwise a
  # `required` unsupported pattern would also log a misleading "matched nothing".
  if unsupported_glob "$pattern"; then
    log "unsupported pattern (literal paths or trailing dir/** only): $pattern" >&2
    return
  fi
  matched_any=0
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    matched_any=1
    rel="${src#"$MAIN"/}"
    dest="$WT/$rel"
    if ! real="$(path_contained "$WT" "$dest")"; then
      log "refusing to copy $rel: it leads to ${real:-a path that cannot be resolved}, outside the worktree, through a symlink"
      skipped=$((skipped + 1))
      continue
    fi
    if [ -e "$dest" ]; then
      skipped=$((skipped + 1))      # idempotent: also dedups repeat matches
      continue
    fi
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    if cp -p "$src" "$dest" 2>/dev/null; then
      copied=$((copied + 1))
    else
      log "failed to copy $rel"
    fi
  done < <(match_files "$pattern")
  if [ "$matched_any" -eq 0 ] && [ "$kind" = "required" ]; then
    missing_required=$((missing_required + 1))
    log "required pattern matched nothing in main checkout: $pattern"
  fi
}

while IFS= read -r line || [ -n "$line" ]; do
  line="${line#"${line%%[![:space:]]*}"}"   # ltrim
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  # `read -a` splits on whitespace without glob expansion: an unquoted `set -- $line`
  # would expand `secrets/**` against the caller's cwd (the main checkout, when run
  # from worktree-hydrate-claude.sh) and copy only the first match.
  read -r -a words <<<"$line"
  if [ "${words[0]}" = "required" ] || [ "${words[0]}" = "optional" ]; then
    [ -n "${words[1]:-}" ] && process_rule "${words[0]}" "${words[1]}"
  else
    process_rule "required" "${words[0]}"
  fi
done < "$rules_src"

if [ "$copied" -gt 0 ] || [ "$missing_required" -gt 0 ]; then
  log "worktree=$WT copied=$copied skipped=$skipped missing_required=$missing_required (heavy deps: run pnpm install / uv sync as needed)"
fi
exit 0
