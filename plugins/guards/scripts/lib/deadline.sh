# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# shellcheck shell=bash
# The guards' gate deadline. The guards hooks time out at 600 seconds, and a hook that times out
# does not block, so a gate stops its command first and blocks with a reason.

# DEADLINE_MAX: the longest deadline, 30 seconds below the hook timeout, so the TERM-to-KILL
# grace and the hook's own start-up fit inside it.
DEADLINE_MAX=570

# deadline_cap <commit_gate_timeout value>: prints the seconds to wait. A blank value is the
# default (570). A value that is not a whole number of seconds is the default, and one above 570
# is 570, each with a warning on stderr.
deadline_cap() {
  local v="${1:-}"
  [ -n "$v" ] || { echo "$DEADLINE_MAX"; return 0; }
  case "$v" in
    *[!0-9]*) _deadline_not_seconds "$v"; return 0 ;;
  esac
  if [ "${#v}" -gt 6 ] || [ "$((10#$v))" -gt "$DEADLINE_MAX" ]; then
    echo "guards: commit_gate_timeout $v is above $DEADLINE_MAX (the hook times out at 600); using $DEADLINE_MAX." >&2
    echo "$DEADLINE_MAX"; return 0
  fi
  [ "$((10#$v))" -ge 1 ] || { _deadline_not_seconds "$v"; return 0; }
  echo "$((10#$v))"
}
_deadline_not_seconds() {
  echo "guards: commit_gate_timeout '$1' is not a whole number of seconds; using $DEADLINE_MAX." >&2
  echo "$DEADLINE_MAX"
}

# run_with_deadline <seconds> <output file> <command...>: runs the command with its stdout and
# stderr in <output file>, and returns its exit status, or 124 when it is still running after
# <seconds>. The command runs in its own process group, so the deadline stops everything it
# started, grandchildren included. The watchdog polls about once a second, so it ends soon after
# the command does, and measures wall-clock time, so a slow `sleep` on a loaded machine does not
# stretch the deadline. At the deadline it sends TERM to the group, then KILL after a
# three-second grace.
run_with_deadline() {
  local cap="$1" out="$2" cpid wpid rc
  shift 2
  case "$cap" in ''|*[!0-9]*) cap=$DEADLINE_MAX ;; esac
  [ "${#cap}" -le 6 ] || cap=$DEADLINE_MAX
  [ "$((10#$cap))" -ge 1 ] || cap=$DEADLINE_MAX
  cap=$((10#$cap))
  rm -f "$out.timedout"
  if command -v perl >/dev/null 2>&1; then
    perl -e 'setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127' -- "$@" >"$out" 2>&1 &
  elif command -v setsid >/dev/null 2>&1; then
    setsid "$@" >"$out" 2>&1 &
  else
    "$@" >"$out" 2>&1 &
  fi
  cpid=$!
  ( stop() { # stop <signal>: the command's group, and its direct children if it has no group
      kill -"$1" -- "-$cpid" 2>/dev/null
      pkill -"$1" -P "$cpid" 2>/dev/null; kill -"$1" "$cpid" 2>/dev/null
    }
    end=$((SECONDS + cap))
    while [ "$SECONDS" -lt "$end" ]; do
      kill -0 "$cpid" 2>/dev/null || exit 0
      sleep 1
    done
    kill -0 "$cpid" 2>/dev/null || exit 0
    : >"$out.timedout"
    stop TERM
    end=$((SECONDS + 3))
    while [ "$SECONDS" -lt "$end" ]; do
      kill -0 "$cpid" 2>/dev/null || break
      sleep 1
    done
    stop KILL ) &
  wpid=$!
  wait "$cpid" 2>/dev/null; rc=$?
  if [ -f "$out.timedout" ]; then
    wait "$wpid" 2>/dev/null   # let the group KILL land before returning
    rm -f "$out.timedout"; return 124
  fi
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  return "$rc"
}
