#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for runtime routing. Exercises the real lens scripts with stubbed CLIs.
set -uo pipefail

ROUTER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/counterpart-lens.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
starts_with() { case "$1" in "$2"*) echo yes;; *) echo no;; esac; }

echo "counterpart-lens.sh tests:"

# A fixture repo with a real, non-empty range (an empty range is SKIPPED by both lenses).
FIX=$(cd "$(mktemp -d)" && pwd -P)
git init -q "$FIX"; git -C "$FIX" config user.email test@example.com; git -C "$FIX" config user.name t
echo base > "$FIX/base.txt"; git -C "$FIX" add base.txt; git -C "$FIX" commit -qm base
B=$(git -C "$FIX" rev-parse HEAD)
echo change > "$FIX/change.txt"; git -C "$FIX" add change.txt; git -C "$FIX" commit -qm "add change"
cd "$FIX" || exit 1

BIN=$(mktemp -d); trap 'rm -rf "$BIN"' EXIT
cat > "$BIN/codex" <<'STUB'
#!/bin/bash
LOG="${CODEX_ARGS_LOG:-/dev/null}"; : > "$LOG"
last=""; prev=""
for a in "$@"; do
  printf 'ARG:%s\n' "$a" >> "$LOG"
  [ "$prev" = "-o" ] && last="$a"
  prev="$a"
done
printf 'STDIN<<\n' >> "$LOG"; cat >> "$LOG"; printf '\n>>STDIN\n' >> "$LOG"
[ -n "$last" ] && printf '%s\n' '{"verdict":"approve","summary":"codex stub","findings":[],"next_steps":[]}' > "$last"
exit ${CODEX_RC:-0}
STUB
cat > "$BIN/claude" <<'STUB'
#!/bin/bash
LOG="${CLAUDE_ARGS_LOG:-/dev/null}"; : > "$LOG"
for a in "$@"; do printf 'ARG:%s\n' "$a" >> "$LOG"; done
printf 'STDIN<<\n' >> "$LOG"; cat >> "$LOG"; printf '\n>>STDIN\n' >> "$LOG"
printf '%s\n' '{"type":"result","structured_output":{"verdict":"approve","summary":"claude stub","findings":[],"next_steps":[]}}'
exit ${CLAUDE_RC:-0}
STUB
chmod +x "$BIN/codex" "$BIN/claude"

CL=$(mktemp); CX=$(mktemp); ER=$(mktemp)
out=$(unset CLAUDE_CODE_SESSION_ID REVIEW_AUTHOR_RUNTIME; CODEX_SESSION_ID=codex-session PATH="$BIN:$PATH" CLAUDE_ARGS_LOG="$CL" CODEX_ARGS_LOG="$CX" bash "$ROUTER" --base "$B" "tenant focus")
if [ "$(starts_with "$out" 'CLAUDE-LENS: FINDINGS')" = yes ] \
  && grep -q 'User focus: tenant focus' "$CL" && [ ! -s "$CX" ]; then
  ok "Codex author -> Claude lens only, with focus forwarded"
else bad "Codex author routing (out=[$out] claude=[$(wc -c < "$CL")] codex=[$(wc -c < "$CX")])"; fi

: > "$CL"; : > "$CX"
out=$(unset CODEX_SESSION_ID REVIEW_AUTHOR_RUNTIME; CLAUDE_CODE_SESSION_ID=claude-session CODEX_LENS_MODEL=model-under-test PATH="$BIN:$PATH" CLAUDE_ARGS_LOG="$CL" CODEX_ARGS_LOG="$CX" bash "$ROUTER" --base "$B" "auth focus")
codex_model=$(grep -c '^ARG:model=model-under-test$' "$CX" || true)
codex_effort=$(grep -c '^ARG:model_reasoning_effort=high$' "$CX" || true)
codex_sandbox=$(grep -A1 '^ARG:-s$' "$CX" | grep -c '^ARG:read-only$' || true)
if [ "$(starts_with "$out" 'CODEX-LENS: FINDINGS')" = yes ] \
  && grep -q 'User focus: auth focus' "$CX" && [ ! -s "$CL" ] \
  && [ "$codex_model" = 1 ] && [ "$codex_effort" = 1 ] && [ "$codex_sandbox" = 1 ]; then
  ok "Claude author -> unchanged Codex lens contract"
else bad "Claude author routing (out=[$out] model=$codex_model effort=$codex_effort sandbox=$codex_sandbox)"; fi

: > "$CL"; : > "$CX"
out=$(unset CODEX_SESSION_ID CLAUDE_CODE_SESSION_ID REVIEW_AUTHOR_RUNTIME; PATH="$BIN:$PATH" CLAUDE_ARGS_LOG="$CL" CODEX_ARGS_LOG="$CX" bash "$ROUTER" --base "$B" 2>"$ER")
if [ "$(starts_with "$out" 'CODEX-LENS: FINDINGS')" = yes ] && [ -s "$CX" ] && [ ! -s "$CL" ] \
  && grep -q 'source=default engine=codex' "$ER"; then
  ok "no Codex marker -> Codex lens"
else bad "default non-Codex routing (out=[$out])"; fi

: > "$CL"; : > "$CX"
out=$(CODEX_SESSION_ID=codex CLAUDE_CODE_SESSION_ID=claude REVIEW_AUTHOR_RUNTIME='' PATH="$BIN:$PATH" CLAUDE_ARGS_LOG="$CL" CODEX_ARGS_LOG="$CX" bash "$ROUTER" --base "$B")
if [ "$(starts_with "$out" 'COUNTERPART-LENS: FAILED')" = yes ] && [ ! -s "$CL" ] && [ ! -s "$CX" ]; then
  ok "conflicting runtime markers -> FAILED"
else bad "conflicting runtime markers (out=[$out])"; fi

: > "$CL"; : > "$CX"
out=$(CODEX_SESSION_ID=codex CLAUDE_CODE_SESSION_ID=claude REVIEW_AUTHOR_RUNTIME=cursor PATH="$BIN:$PATH" CLAUDE_ARGS_LOG="$CL" CODEX_ARGS_LOG="$CX" bash "$ROUTER" --base "$B")
if [ "$(starts_with "$out" 'CODEX-LENS: FINDINGS')" = yes ] && [ -s "$CX" ] && [ ! -s "$CL" ]; then
  ok "arbitrary non-Codex override -> Codex lens"
else bad "open-ended runtime override (out=[$out])"; fi

: > "$CL"; : > "$CX"
out=$(CLAUDE_CODE_SESSION_ID=claude REVIEW_AUTHOR_RUNTIME=codex PATH="$BIN:$PATH" CLAUDE_ARGS_LOG="$CL" CODEX_ARGS_LOG="$CX" bash "$ROUTER" --base "$B")
if [ "$(starts_with "$out" 'CLAUDE-LENS: FINDINGS')" = yes ] && [ -s "$CL" ] && [ ! -s "$CX" ]; then
  ok "explicit Codex override -> Claude lens"
else bad "explicit Codex override (out=[$out])"; fi

out=$(unset CODEX_SESSION_ID REVIEW_AUTHOR_RUNTIME; CLAUDE_CODE_SESSION_ID=claude CODEX_RC=3 PATH="$BIN:$PATH" bash "$ROUTER" --base "$B")
if [ "$(starts_with "$out" 'CODEX-LENS: FAILED')" = yes ]; then
  ok "Claude author preserves Codex engine failures"
else bad "Codex failure classification through dispatcher (out=[$out])"; fi

out=$(unset CLAUDE_CODE_SESSION_ID REVIEW_AUTHOR_RUNTIME; CODEX_SESSION_ID=codex CLAUDE_RC=3 PATH="$BIN:$PATH" bash "$ROUTER" --base "$B")
if [ "$(starts_with "$out" 'CLAUDE-LENS: FAILED')" = yes ]; then
  ok "Codex author preserves Claude engine failures"
else bad "Claude failure classification through dispatcher (out=[$out])"; fi

# Missing Codex must retain Codex's own SKIPPED grammar after successful routing.
NO_CODEX=$(mktemp -d)
for cmd in bash git grep wc tr mktemp chmod cat rm kill sleep jq dirname; do
  p=$(command -v "$cmd" 2>/dev/null || true); [ -n "$p" ] && ln -s "$p" "$NO_CODEX/$cmd"
done
out=$(unset CODEX_SESSION_ID REVIEW_AUTHOR_RUNTIME; CLAUDE_CODE_SESSION_ID=claude PATH="$NO_CODEX" /bin/bash "$ROUTER" --base "$B")
if [ "$(starts_with "$out" 'CODEX-LENS: SKIPPED')" = yes ]; then
  ok "Claude author + missing Codex preserves CODEX-LENS: SKIPPED"
else bad "missing Codex classification (out=[$out])"; fi
out=$(unset CLAUDE_CODE_SESSION_ID REVIEW_AUTHOR_RUNTIME; CODEX_SESSION_ID=codex PATH="$NO_CODEX" /bin/bash "$ROUTER" --base "$B")
if [ "$(starts_with "$out" 'CLAUDE-LENS: SKIPPED')" = yes ]; then
  ok "Codex author + missing Claude preserves CLAUDE-LENS: SKIPPED"
else bad "missing Claude classification (out=[$out])"; fi
rm -rf "$NO_CODEX"

BROKEN_ROOT=$(mktemp -d)
mkdir -p "$BROKEN_ROOT/review-panel/scripts"
cp "$ROUTER" "$BROKEN_ROOT/review-panel/scripts/counterpart-lens.sh"
out=$(REVIEW_AUTHOR_RUNTIME=codex PATH="$BIN:$PATH" bash "$BROKEN_ROOT/review-panel/scripts/counterpart-lens.sh" --base "$B")
if [ "$(starts_with "$out" 'COUNTERPART-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'missing or unreadable'; then
  ok "missing selected engine preserves leading failure token"
else bad "missing engine classification (out=[$out])"; fi
rm -rf "$BROKEN_ROOT"

# The runtime name is matched case-insensitively, so "Codex" routes to the Claude lens.
for name in Codex CODEX " codex"; do
  : > "$CL"; : > "$CX"
  out=$(unset CODEX_SESSION_ID CLAUDE_CODE_SESSION_ID; REVIEW_AUTHOR_RUNTIME="$name" PATH="$BIN:$PATH" CLAUDE_ARGS_LOG="$CL" CODEX_ARGS_LOG="$CX" bash "$ROUTER" --base "$B" 2>/dev/null)
  if [ "$(starts_with "$out" 'CLAUDE-LENS: FINDINGS')" = yes ] && [ -s "$CL" ] && [ ! -s "$CX" ]; then
    ok "REVIEW_AUTHOR_RUNTIME=[$name] -> Claude lens"
  else bad "REVIEW_AUTHOR_RUNTIME=[$name] (out=[$(printf '%s' "$out" | head -1)])"; fi
done

cd / && rm -rf "$FIX"
rm -f "$CL" "$CX" "$ER"
echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
