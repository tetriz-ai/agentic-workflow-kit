#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# hook-once.sh: run a kit hook script once per event when two installs deliver it. On Codex, the
# kit's Codex plugins and the bridge's .codex/hooks.json both fire for the same tool call, and
# both would run the same plugin script. Each side claims the event first; the side that loses
# the claim skips the script, and the side that wins runs it and decides.
#
#   hook-once.sh <script> [args...]   claim, then run the sibling <script> with the payload on
#                                     stdin and exit with its status; exit 0 when the claim is lost
#   hook-once.sh --claim <script>     claim only: exit 0 to run, 1 to skip (the bridge calls this)
#
# The claim is active when Codex runs this as a plugin hook (it sets PLUGIN_ROOT) or when the
# bridge asks (AGENTIC_KIT_HOOK_ONCE=1); otherwise the script just runs. An event is a tool call
# (session_id and tool_use_id in the payload) or a SessionStart (session_id, source and the UTC
# minute, so a later compact runs again; two starts in one minute run once, and one start whose two
# deliveries straddle a minute runs twice). Anything else, a payload jq cannot read, or a claim
# folder that is not this user's own runs the script: a missed claim runs it twice, never zero times.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claim_only=0; [ "${1:-}" = "--claim" ] && { claim_only=1; shift; }
name="${1:-}"; [ -n "$name" ] || { echo "usage: hook-once.sh [--claim] <script> [args...]" >&2; exit 2; }
shift
run() { [ "$claim_only" = 1 ] && exit 0; exec "$here/$name" "$@"; }

[ -n "${PLUGIN_ROOT:-}${AGENTIC_KIT_HOOK_ONCE:-}" ] && command -v jq >/dev/null 2>&1 || run "$@"
payload="$(cat)"
replay() { [ "$claim_only" = 1 ] && exit 0; printf '%s' "$payload" | "$here/$name" "$@"; exit $?; }
skip() { exit "$claim_only"; }

# Each id is hex-encoded into the key, so two different events never share one (`a.b`+`c` and
# `a`+`b.c` stay apart) and the key is always a safe file name.
field() { printf '%s' "$payload" | jq -r "($1) // \"\" | if type == \"string\" then . else tojson end" 2>/dev/null; }
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
sid=$(field .session_id); tid=$(field .tool_use_id); event=$(field .hook_event_name)
key=""
if [ -n "$sid" ] && [ -n "$tid" ]; then key="call.$(hex "$sid").$(hex "$tid")"
elif [ -n "$sid" ] && [ "$event" = SessionStart ]; then key="start.$(hex "$sid").$(hex "$(field .source)").$(date -u +%Y%m%d%H%M)"
fi
[ -n "$key" ] || replay "$@"

dir="${TMPDIR:-/tmp}"; dir="${dir%/}/agentic-kit-hook-once-$(id -u)"
mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null
[ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || replay "$@"
claim="$dir/$key.$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
if ( set -o noclobber; : > "$claim" ) 2>/dev/null; then
  find "$dir" -type f -mmin +1440 -delete 2>/dev/null   # claims older than a day
  replay "$@"
fi
skip
