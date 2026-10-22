#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Deterministic test for usage-guard.sh (run by scripts/test-all.sh, or on its own).
# Isolates state via a temp CLAUDE_PROJECT_DIR so it never touches the real signal.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/usage-guard.sh"
fail=0
check() { # desc | expected-substring | actual
  if [[ "$3" == *"$2"* ]]; then echo "ok: $1"; else echo "FAIL: $1 — want '*$2*', got '$3'"; fail=1; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PROJECT_DIR="$TMP"
mkdir -p "$TMP/.claude/triage"
U="$TMP/.claude/triage/usage.json"
now() { date +%s; }
# Run from a NON-git dir so the guard's --git-common-dir anchor falls back to
# CLAUDE_PROJECT_DIR=$TMP (else it would resolve to the real repo and read the
# live usage.json instead of our fixtures).
cd "$TMP" || exit 1

# missing file -> proceed (no-signal), no pause
check "missing -> ok" "ok no-signal" "$(bash "$GUARD" should-pause)"

# fresh, below threshold -> ok
echo "{\"pct\":40,\"resets_at\":111,\"captured_at\":$(now)}" > "$U"
check "40% -> ok" "ok pct=40" "$(bash "$GUARD" should-pause)"

# fresh, at/over threshold -> pause + carries resets_at
echo "{\"pct\":86,\"resets_at\":222,\"captured_at\":$(now)}" > "$U"
out="$(bash "$GUARD" should-pause)"
check "86% -> pause" "pause pct=86" "$out"
check "86% -> resets_at in msg" "resets_at=222" "$out"
check "resets-at subcmd" "222" "$(bash "$GUARD" resets-at)"

# custom threshold via arg
check "thr=90, 86% -> ok" "ok pct=86" "$(bash "$GUARD" should-pause 90)"

# a malformed threshold warns and falls back to the default 85 (86% pauses)
for thr in "85%" "abc"; do
  out="$(bash "$GUARD" should-pause "$thr" 2>"$TMP/err")"
  check "thr=$thr -> default 85, 86% pauses" "pause pct=86% >= 85%" "$out"
  check "thr=$thr -> warning on stderr" "is not a number" "$(cat "$TMP/err")"
done

# exactly at the threshold pauses
echo "{\"pct\":85,\"resets_at\":222,\"captured_at\":$(now)}" > "$U"
check "85% at the default threshold -> pause" "pause pct=85" "$(bash "$GUARD" should-pause)"

# stale signal -> proceed (not pause), even at high pct
echo "{\"pct\":99,\"resets_at\":333,\"captured_at\":1}" > "$U"
check "stale -> ok" "ok stale" "$(bash "$GUARD" should-pause)"

# null pct (non-subscriber) -> proceed
echo "{\"pct\":null,\"resets_at\":null,\"captured_at\":$(now)}" > "$U"
check "null pct -> ok no-signal" "ok no-signal" "$(bash "$GUARD" should-pause)"

# float pct just over threshold -> pause (awk -v numeric compare)
echo "{\"pct\":85.4,\"resets_at\":7,\"captured_at\":$(now)}" > "$U"
check "85.4% -> pause" "pause pct=85.4" "$(bash "$GUARD" should-pause)"
# float just under -> ok
echo "{\"pct\":84.9,\"resets_at\":7,\"captured_at\":$(now)}" > "$U"
check "84.9% -> ok" "ok pct=84.9" "$(bash "$GUARD" should-pause)"
# corrupt non-numeric pct -> treated as no-signal, must NOT crash
echo "{\"pct\":\"1;system('x')\",\"resets_at\":7,\"captured_at\":$(now)}" > "$U"
out="$(bash "$GUARD" should-pause)"; rc=$?
check "corrupt pct -> ok no-signal" "ok no-signal" "$out"
check "corrupt pct -> exit 0 (no crash)" "0" "$rc"

# no jq on PATH: the reason names jq, not a missing signal
echo "{\"pct\":86,\"resets_at\":222,\"captured_at\":$(now)}" > "$U"
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for t in bash git date cat dirname; do p=$(command -v "$t") && ln -sf "$p" "$NOJQ/$t"; done
check "no jq -> reason names jq" "jq is not installed" "$(PATH="$NOJQ" "$(command -v bash)" "$GUARD" should-pause)"

[ "$fail" -eq 0 ] && echo "PASS usage-guard.test.sh" || { echo "usage-guard.test.sh FAILED"; exit 1; }
