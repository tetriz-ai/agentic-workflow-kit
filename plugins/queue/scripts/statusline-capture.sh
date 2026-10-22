#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Project statusline wrapper — captures the 5h usage signal, then delegates the
# DISPLAY back to each user's personal statusline so nobody loses their look.
#
# EXPERIMENTAL and opt-in: this is the capture half of /queue:ship-queue's
# usage pacing. The plugin does not wire it as a statusLine (that would override
# each person's own line); an operator who wants pacing sets it as their own
# statusLine command.
#
# Why it exists: Claude Code delivers `rate_limits.five_hour.{used_percentage,
# resets_at}` ONLY to the statusline command's stdin (confirmed against the
# binary — no hook payload carries it). usage-guard.sh reads what this writes.
#
# REQUIRES jq. Writes <main-checkout>/.claude/triage/usage.json atomically. The
# triage dir is anchored to the MAIN checkout via --git-common-dir, because
# .claude/triage is local state the repo git-ignores, and ignored files do NOT
# cross worktree boundaries.

set -uo pipefail

input=$(cat)   # JSON from Claude Code. $() strips trailing newlines; JSON body intact.

# The session's own directory, from the statusline input (a worktree when the session runs
# in one); this process's cwd when the input does not say.
here=""
command -v jq >/dev/null 2>&1 && here=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)
[ -n "$here" ] && [ -d "$here" ] || here="$PWD"

# Anchor to the MAIN checkout so the triage dir is shared across all worktrees.
gcd=$(cd "$here" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null || true)
if [ -n "$gcd" ]; then
  case "$gcd" in /*) ;; *) gcd="$here/$gcd";; esac
  proj=$(cd "$(dirname "$gcd")" 2>/dev/null && pwd)
fi
proj="${proj:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# Render a minimal fallback line (the session's branch + 5h%) from $input. Used when the
# user has no personal statusline, and as the recursion backstop below.
render_fallback() {
  local branch line pct
  branch=$(cd "$here" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null)
  line="${branch:-?}"
  if command -v jq >/dev/null 2>&1; then
    pct=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
    case "$pct" in ''|*[!0-9.]*) ;; *) line="$line · 5h:$(printf '%.0f' "$pct" 2>/dev/null)%";; esac
  fi
  printf '%s' "$line"
}

# Recursion backstop: if a user set their personal statusLine to THIS wrapper,
# the delegation below would re-exec us forever. The sentinel catches it
# regardless of how the command is spelled (`bash <path>`, a bare path, env, …) —
# a path/basename compare cannot. On recursion, render the fallback and stop.
if [ -n "${_AGENTIC_KIT_STATUSLINE_WRAP:-}" ]; then
  render_fallback
  exit 0
fi

# --- 1. capture the usage signal (needs jq; best-effort, atomic) --------------
# An input without the 5h figure (before the first API response, a non-subscriber) is not a
# signal: the last real capture is kept rather than replaced by a null.
if command -v jq >/dev/null 2>&1 \
   && printf '%s' "$input" | jq -e '.rate_limits.five_hour.used_percentage | numbers' >/dev/null 2>&1; then
  triage="$proj/.claude/triage"
  if mkdir -p "$triage" 2>/dev/null; then
    now=$(date +%s)
    tmp="$triage/.usage.json.$$"
    trap 'rm -f "$tmp" 2>/dev/null' EXIT
    if printf '%s' "$input" | jq -c --argjson now "$now" '{
        pct: (.rate_limits.five_hour.used_percentage // null),
        resets_at: (.rate_limits.five_hour.resets_at // null),
        captured_at: $now
      }' > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$triage/usage.json" 2>/dev/null || true
    fi
  fi
fi

# --- 2. delegate display to the user's personal statusline -------------------
# Look up the user-level statusLine (settings.json then settings.local.json),
# only when type is "command". It reads only the statusLine.command value. Export the sentinel so a recursive invocation is
# caught at the top, then run in a subshell (not eval).
user_cmd=""
if command -v jq >/dev/null 2>&1; then
  for s in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json"; do
    [ -f "$s" ] || continue
    c=$(jq -r 'if (.statusLine.type // "command")=="command" then (.statusLine.command // empty) else empty end' "$s" 2>/dev/null)
    [ -n "$c" ] && { user_cmd="$c"; break; }
  done
fi

if [ -n "$user_cmd" ]; then
  printf '%s' "$input" | _AGENTIC_KIT_STATUSLINE_WRAP=1 bash -c "$user_cmd"
else
  render_fallback
fi
