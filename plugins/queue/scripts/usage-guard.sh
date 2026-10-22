#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# usage-guard — reads the 5h usage signal captured by statusline-capture.sh and
# tells /queue:ship-queue whether to pause before the limit, and when the window resets.
#
# Signal source: .claude/triage/usage.json = {pct, resets_at, captured_at},
# written by the project statusline wrapper (the ONLY place Claude Code exposes
# rate_limits — see statusline-capture.sh). No transcript math, no learned cap:
# the harness gives the real percentage and the real reset epoch.
#
# Subcommands:
#   should-pause [threshold]  -> prints "pause <reason>" or "ok <detail>" (exit 0)
#   resets-at                 -> prints the reset epoch (for cron scheduling), or ""
#   status                    -> human-readable pct / reset / age line
#
# Pause policy: pause when pct >= threshold (default 85). Missing/stale signal is
# NOT a pause — we have no evidence of high usage, and the dead-man cron (armed
# at run start for resets_at) backstops the rare blow-past. Pausing on "no
# signal" would deadlock a healthy run, so proceed-with-warning instead.

set -uo pipefail

THRESHOLD="${2:-${USAGE_PAUSE_THRESHOLD:-85}}"
# A threshold must be a number (85, 85.5); anything else (`85%`, `abc`) would never compare as
# reached, so it is reported and the default is used.
if ! [[ "$THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "usage-guard: threshold '$THRESHOLD' is not a number; using 85" >&2
  THRESHOLD=85
fi
STALE_SECS="${USAGE_STALE_SECS:-180}"   # statusline refreshes ~30s; >3min = no fresh signal

# Anchor to the MAIN checkout (shared across worktrees) — .claude/triage is
# gitignored and does NOT cross worktree boundaries, so --show-toplevel (the
# worktree root) would read the wrong file. --git-common-dir resolves to main.
gcd=$(git rev-parse --git-common-dir 2>/dev/null || true)
if [ -n "$gcd" ]; then
  case "$gcd" in /*) ;; *) gcd="$PWD/$gcd";; esac
  proj=$(cd "$(dirname "$gcd")" 2>/dev/null && pwd)
fi
proj="${proj:-${CLAUDE_PROJECT_DIR:-$PWD}}"
f="$proj/.claude/triage/usage.json"

read_field() { jq -r "$1 // empty" "$f" 2>/dev/null; }

cmd="${1:-status}"

if [ ! -f "$f" ]; then
  case "$cmd" in
    should-pause) echo "ok no-signal (usage.json absent — statusline wrapper not wired or no API response yet)";;
    resets-at)    echo "";;
    *)            echo "no usage signal (.claude/triage/usage.json absent)";;
  esac
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  case "$cmd" in
    should-pause) echo "ok no-signal (jq is not installed, so usage.json cannot be read; install jq for pacing)";;
    resets-at)    echo "";;
    *)            echo "no usage signal: jq is not installed";;
  esac
  exit 0
fi
pct=$(read_field '.pct')
resets_at=$(read_field '.resets_at')
captured_at=$(read_field '.captured_at')
# Sanitize before arithmetic: set -u + $(( )) abort on a non-integer (corrupt/
# partial usage.json, a float). Non-digits -> 0 -> huge age -> judged stale -> safe.
case "$captured_at" in ''|*[!0-9]*) captured_at=0;; esac
now=$(date +%s)
age=$(( now - captured_at ))

case "$cmd" in
  resets-at)
    echo "${resets_at}"
    ;;
  should-pause)
    # A corrupt/partial usage.json could carry a non-numeric pct — treat as no
    # signal rather than feed it to awk (interpolating it would be a crash/inject
    # surface; values go in via -v, never as program text).
    case "$pct" in *[!0-9.]*|*.*.*) pct="";; esac
    if [ -z "$pct" ]; then
      echo "ok no-signal (rate_limits absent / non-numeric — non-subscriber, pre-first-response, or corrupt signal)"
    elif [ "$age" -gt "$STALE_SECS" ]; then
      echo "ok stale (signal ${age}s old > ${STALE_SECS}s; proceeding — dead-man cron backstops)"
    elif awk -v p="$pct" -v t="$THRESHOLD" 'BEGIN{exit !(p >= t)}'; then
      echo "pause pct=${pct}% >= ${THRESHOLD}% resets_at=${resets_at}"
    else
      echo "ok pct=${pct}% < ${THRESHOLD}%"
    fi
    ;;
  *)
    echo "pct=${pct:-?}% threshold=${THRESHOLD}% resets_at=${resets_at:-?} age=${age}s"
    ;;
esac
