#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# extract-taste / gather.sh
# ---------------------------------------------------------------------------
# Deterministic source discovery + session inventory for the /learn:extract-taste
# skill. Prints a compact manifest to stdout. It does NOT push, does NOT mutate
# anything, and does NOT print transcript content beyond each session's `cwd`
# path (used as ground truth to decide repo membership) — never message text.
#
# Scope model
#   default     : sessions that provably belong to THIS repo. Membership is
#                 decided by GROUND TRUTH, not by the (lossy) encoded dir name:
#                 each transcript's first `cwd` is read, and a session is kept
#                 only if that cwd is under this checkout OR its git origin
#                 matches this repo's origin. This is what stops a sibling
#                 repo like `core-fork` / `core-2` (whose encoded name shares the
#                 `core` substring) from being swept in.
#   --all-work  : widen to all project dirs EXCEPT private-marker / tmp names.
#                 This is broad and origin-blind, so the skill must have the user
#                 approve the kept-dir list PER DIR before any session is read.
#
# gate: scope selector — keeps a session only when its transcript's first cwd
#       is under this repo (boundary-anchored) or origin-verified; a sibling
#       checkout like `core-fork` must NOT be swept in. Fixture: gather.test.sh
#       (block-the-leak + keep-the-real).
#
# Self-exclusion: a session whose transcript contains the artifact OUTPUT schema
# is dropped from the inventory (logged) so a re-run does not re-ingest an earlier
# run's conclusions. This also drops the skill's own dev/validation sessions (they
# handled the artifact) — accepted; no content signature separates them, and a
# precise session-id exclusion is a v2. See the inventory loop.
#
# Privacy: dirs whose basename matches a private marker (personal|private|
# secret|journal|finance|medical|tax|health) or is a tmp scratch dir are dropped
# under every mode. This is a coarse NAME filter, not a content classifier — a
# privately-named work dir is the user's responsibility to exclude (see SKILL.md).
#
# Usage: gather.sh [--all-work] [--approved]
#   --all-work             selection only — lists candidate dirs and STOPS before
#                          reading any session (so the owner approves the list).
#   --all-work --approved  proceed to the session inventory for the approved dirs.
# Default scope (this-repo-verified) inventories directly; no approval needed.
# ---------------------------------------------------------------------------
set -euo pipefail

ALL_WORK=0
APPROVED=0
for a in "$@"; do
  case "$a" in
    --all-work) ALL_WORK=1 ;;
    --approved) APPROVED=1 ;;
  esac
done

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECTS_DIR="$CLAUDE_HOME/projects"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
origin_url="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || true)"

PRIVATE_MARKERS='personal|private|secret|journal|finance|medical|tax|health'
TMP_MARKERS='^-?private-tmp$|^-?tmp$|-tmp-|scratch'

# First `cwd` recorded in a transcript — ground truth for which repo it was run
# in. grep -m1 stops at the first hit, so this is cheap even on large files.
first_cwd() { grep -aom1 '"cwd":"[^"]*"' "$1" 2>/dev/null | sed 's/.*"cwd":"//; s/"$//'; }

# cwd_in_repo <cwd>: 0 when <cwd> is this checkout (or under it, boundary-anchored: a sibling
# like <root>-fork shares the prefix but not the /), or a checkout whose origin matches ours.
# Sets IN_REPO_REASON.
cwd_in_repo() {
  local cwd="$1" o
  IN_REPO_REASON=""
  [[ -n "$cwd" ]] || return 1
  if [[ "$cwd" == "$REPO_ROOT" || "$cwd" == "$REPO_ROOT"/* ]]; then
    IN_REPO_REASON="under-repo-root"; return 0
  fi
  if [[ -d "$cwd" ]]; then
    # git -C works from ANY subdir of a checkout, not just the clone root.
    o="$(git -C "$cwd" config --get remote.origin.url 2>/dev/null || true)"
    if [[ -n "$o" && -n "$origin_url" && "$o" == "$origin_url" ]]; then IN_REPO_REASON="origin-verified"; return 0; fi
  fi
  return 1
}

# real_path <path>: the physical path (symlinks and .. resolved), or empty when it does not
# exist. Follows a symlinked file up to 10 hops.
real_path() {
  local p="$1" d b t n=0
  while [[ -L "$p" && $n -lt 10 ]]; do
    t="$(readlink "$p")"; case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
    n=$((n + 1))
  done
  [[ -e "$p" ]] || return 0
  d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 0
  b="$(basename "$p")"
  printf '%s/%s' "$d" "$b"
}

echo "# extract-taste source manifest"
echo "repo_root:   $REPO_ROOT"
echo "origin:      ${origin_url:-<none>}"
echo "scope:       $([[ $ALL_WORK -eq 1 ]] && echo all-work || echo this-repo-verified)"
if [[ $ALL_WORK -eq 0 && -z "$origin_url" ]]; then
  echo "WARNING: no git origin for this repo — default scope can only keep sessions whose cwd is under $REPO_ROOT. Do NOT reach for --all-work to 'fix' an empty result; check 'git remote -v' first." >&2
fi
echo

# ---------------------------------------------------------------------------
# Static sources — the skill reads these in full.
# ---------------------------------------------------------------------------
echo "## static sources (read in full)"
for f in \
  "$CLAUDE_HOME/CLAUDE.md" \
  "$CLAUDE_HOME/settings.json" \
  "$CLAUDE_HOME/settings.local.json" \
  "$REPO_ROOT/CLAUDE.md" \
  "$REPO_ROOT/.claude/settings.json" \
  "$REPO_ROOT/.claude/settings.local.json"; do
  [[ -f "$f" ]] && echo "file: $f"
done
# @-includes referenced from the global CLAUDE.md, line-anchored OR inline. Only a target inside
# the Claude home or this repo is listed to read in full; any other target (an absolute path or a
# ~/ path elsewhere, or a relative path that climbs out) is listed as refused and never read, so a
# stray `@~/.ssh/id_rsa` cannot reach a subagent. The person can add a refused file by hand.
if [[ -f "$CLAUDE_HOME/CLAUDE.md" ]]; then
  claude_real="$(cd "$CLAUDE_HOME" 2>/dev/null && pwd -P || true)"
  repo_real="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P || true)"
  while read -r inc; do
    case "$inc" in
      /*) p="$inc" ;;
      "~"/*) p="${HOME}/${inc#'~/'}" ;;   # quote so the tilde is literal, not bash-expanded
      *) p="$CLAUDE_HOME/$inc" ;;
    esac
    [[ -f "$p" ]] || continue
    rp="$(real_path "$p")"
    if [[ -n "$rp" && ( ( -n "$claude_real" && "$rp" == "$claude_real"/* ) || ( -n "$repo_real" && "$rp" == "$repo_real"/* ) ) ]]; then
      echo "file: $p"
    else
      echo "refused (outside the Claude home and the repo): $p"
    fi
  done < <(grep -oE '(^|[[:space:]])@[^[:space:]]+' "$CLAUDE_HOME/CLAUDE.md" 2>/dev/null | sed -E 's/^[[:space:]]*@//' || true)
fi
for d in "$CLAUDE_HOME/hooks" "$REPO_ROOT/.claude/hooks"; do
  [[ -d "$d" ]] && echo "dir:  $d"
done
echo

# ---------------------------------------------------------------------------
# Select in-scope project dirs (every dir logged keep/skip/drop — never silent).
# ---------------------------------------------------------------------------
echo "## project dir selection"
IN_SCOPE=()
MEM_DIRS=()
if [[ ! -d "$PROJECTS_DIR" ]]; then
  echo "(no projects dir at $PROJECTS_DIR — nothing to scope)"
else
  while IFS= read -r d; do
    base="$(basename "$d")"

    # HARD private/tmp filter — applies under every mode, runs first.
    if printf '%s' "$base" | grep -qiE "$PRIVATE_MARKERS"; then
      echo "drop (private-name): $base"; continue
    fi
    if printf '%s' "$base" | grep -qiE "$TMP_MARKERS"; then
      echo "drop (tmp-scratch): $base"; continue
    fi

    # No sessions to read — skip cleanly (common for empty worktree project dirs).
    sample="$(ls "$d"/*.jsonl 2>/dev/null | head -1 || true)"
    if [[ -z "$sample" ]]; then
      echo "skip (no sessions): $base"; continue
    fi

    keep=0; reason=""
    if [[ $ALL_WORK -eq 1 ]]; then
      keep=1; reason="all-work (needs per-dir approval)"
    else
      # Ground-truth membership via each transcript's own first cwd: the folder name encoding is
      # lossy, so one folder can hold sessions from two repos. Keep the folder when any session
      # is in this repo; the inventory below keeps only those sessions.
      for f in "$d"/*.jsonl; do
        if cwd_in_repo "$(first_cwd "$f")"; then keep=1; reason="$IN_REPO_REASON"; break; fi
      done
    fi

    if [[ $keep -eq 1 ]]; then
      echo "keep ($reason): $base"
      IN_SCOPE+=("$d")
      [[ -d "$d/memory" ]] && MEM_DIRS+=("$d/memory")
    else
      # Logged so a real but unverifiable clone (e.g. a deleted external
      # worktree whose cwd no longer resolves) is visible, not silently lost.
      echo "skip (unverified / other-repo): $base"
    fi
  done < <(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
fi
echo

# --all-work reads sessions from dirs that may belong to other repos, so split
# selection from session-reading: list the candidates and STOP until the owner
# re-runs with --approved. No .jsonl is scanned before that.
if [[ $ALL_WORK -eq 1 && $APPROVED -eq 0 ]]; then
  echo "## --all-work: selection only (no sessions read yet)"
  echo "Review the 'keep' dirs above. They are NOT this-repo-verified — they may be"
  echo "other repos. After approving the list, re-run to inventory them:"
  echo "  gather.sh --all-work --approved"
  exit 0
fi

# ---------------------------------------------------------------------------
# Memory dirs in scope (read in full).
# ---------------------------------------------------------------------------
echo "## memory dirs (read in full)"
if [[ ${#MEM_DIRS[@]} -eq 0 ]]; then
  echo "(none)"
else
  for m in "${MEM_DIRS[@]}"; do echo "dir:  $m"; done
fi
echo

# ---------------------------------------------------------------------------
# Session inventory — ALL in-scope sessions with cheap, multi-signal hints in a
# SINGLE pass per file (awk counts markers + user turns + bytes at once). NOT a
# frustration-ranked top-N: efficiencies/clever workflows carry none of the
# marker words, so a marker gate would bury them. bash does recall-complete
# inventory; the skill does the triage. No message text is printed.
#   markers    : correction/frustration marker hits (lens: frustrations)
#   user_turns : user-message count               (lens: substance/depth)
#   size_kb    : transcript size                  (lens: substance)
# Recency is available to the skill via `ls -t` over the same dirs.
# ---------------------------------------------------------------------------
MARKERS='(dont|do not|don.t) (do that|again)|never (do|use|add|commit|run|write)|always (use|run|do|add|prefer)|stop (doing|that)|i (told|already told|already said) you|why did you|that.?s (wrong|not right|not what)|not what i (asked|wanted|meant)|as i (said|asked)|keep (doing|forgetting|telling)|for the (last|nth) time|frustrat|annoying|use -> not'
echo "## session inventory (ALL in-scope) — markers<TAB>user_turns<TAB>size_kb<TAB>path"
if [[ ${#IN_SCOPE[@]} -eq 0 ]]; then
  echo "(no in-scope project dirs)"
else
  scanned=0
  {
    for d in "${IN_SCOPE[@]}"; do
      shopt -s nullglob
      for f in "$d"/*.jsonl; do
        # Default scope: a session from another repo in the same folder is left out (logged).
        if [[ $ALL_WORK -eq 0 ]] && ! cwd_in_repo "$(first_cwd "$f")"; then
          echo "  other-repo session left out: $(basename "$f")" >&2
          continue
        fi
        # one read: markers (case-insensitive), user turns, bytes, and a
        # self-reference flag. SELF-EXCLUSION feedback-loop guard: drop a session
        # whose transcript contains the artifact OUTPUT schema (`suggested_home:`
        # or a `# Taste profile:` heading), so a re-run does not re-ingest an
        # earlier run's conclusions as if they were observed signal.
        #
        # Honest limitation: this ALSO drops the skill's own dev/validation
        # sessions, because those handled the artifact (read it, edited the
        # template). There is NO content signature that separates "is a run" from
        # "is a rich session that worked on extract-taste" — the rich sessions are
        # *about* this artifact. Accepted: those carry the artifact's conclusions
        # (real feedback fuel) and their working-style is redundant across the rest
        # of the corpus; and `suggested_home:` does not false-positive on any
        # normal session. Precise exclusion (by recorded run session-id) is a v2.
        read -r m u b self < <(awk -v re="$MARKERS" '
          tolower($0) ~ re { mk++ }
          index($0, "\"type\":\"user\"") { ut++ }
          /suggested_home:|# Taste profile:/ { selfref = 1 }
          { by += length($0) + 1 }
          END { printf "%d %d %d %d\n", mk+0, ut+0, by+0, selfref+0 }' "$f")
        if [[ "${self:-0}" == "1" ]]; then
          echo "  self-excluded (contains a produced taste artifact): $(basename "$f")" >&2
          continue
        fi
        kb=$(( (b + 1023) / 1024 ))
        printf '%s\t%s\t%s\t%s\n' "$m" "$u" "$kb" "$f"
        scanned=$((scanned + 1))
        if [[ $((scanned % 25)) -eq 0 ]]; then echo "  ...scanned $scanned sessions" >&2; fi
      done
    done
  } | sort -t$'\t' -k1,1nr -k2,2nr -k3,3nr
  echo "# in-scope sessions listed above. Triage with MULTIPLE lenses, not only top markers; high user_turns / size_kb with zero markers is where efficiencies and novel workflows hide."
fi
