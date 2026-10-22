#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Deterministic tests for claude-lens.sh. No real Claude call is made.
set -uo pipefail

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-lens.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
starts_with() { case "$1" in "$2"*) echo yes;; *) echo no;; esac; }

echo "claude-lens.sh tests:"

# A fixture repo with a real, non-empty range: B is the base commit, HEAD adds one file.
FIX=$(cd "$(mktemp -d)" && pwd -P)
git init -q "$FIX"; git -C "$FIX" config user.email test@example.com; git -C "$FIX" config user.name t
echo base > "$FIX/base.txt"; git -C "$FIX" add base.txt; git -C "$FIX" commit -qm base
B=$(git -C "$FIX" rev-parse HEAD)
echo change > "$FIX/change.txt"; git -C "$FIX" add change.txt; git -C "$FIX" commit -qm "add change"
cd "$FIX" || exit 1

out=$(bash "$ENGINE"); rc=$?
if [ "$(starts_with "$out" 'CLAUDE-LENS: FAILED')" = yes ] && [ "$rc" -eq 0 ]; then
  ok "no args -> FAILED, exit 0"; else bad "no args (out=[$out] rc=$rc)"; fi

out=$(PATH="/usr/bin:/bin" bash "$ENGINE" --base "$B"); rc=$?
if [ "$(starts_with "$out" 'CLAUDE-LENS: SKIPPED')" = yes ] && [ "$rc" -eq 0 ]; then
  ok "claude off PATH -> SKIPPED"; else bad "missing claude (out=[$out] rc=$rc)"; fi

BIN=$(mktemp -d); trap 'rm -rf "$BIN"' EXIT
apply_stub() {
  cat > "$BIN/claude" <<'STUB'
#!/bin/bash
LOG="${ARGS_LOG:-/dev/null}"
: > "$LOG"
for a in "$@"; do printf 'ARG:%s\n' "$a" >> "$LOG"; done
printf 'STDIN<<\n' >> "$LOG"; cat >> "$LOG"; printf '\n>>STDIN\n' >> "$LOG"
printf 'PWD:%s\n' "$PWD" >> "$LOG"
[ -f tracked.txt ] && printf 'TRACKED:%s\n' "$(cat tracked.txt)" >> "$LOG"
if [ -e secret.env ]; then printf 'UNTRACKED:yes\n' >> "$LOG"; else printf 'UNTRACKED:no\n' >> "$LOG"; fi
[ -n "${CLAUDE_STDERR:-}" ] && printf '%s\n' "$CLAUDE_STDERR" >&2
if [ "${CLAUDE_BAD_JSON:-0}" = 1 ]; then
  printf '%s\n' '{"type":"result","result":"not-json"}'
elif [ "${CLAUDE_OFF_SCHEMA:-0}" = 1 ]; then
  printf '%s\n' '{"type":"result","structured_output":{"verdict":"maybe","summary":"stub"}}'
else
  printf '%s\n' '{"type":"result","structured_output":{"verdict":"approve","summary":"stub","findings":[],"next_steps":[]}}'
fi
exit ${CLAUDE_RC:-0}
STUB
  chmod +x "$BIN/claude"
}
apply_stub

out=$(PATH="$BIN:$PATH" CLAUDE_LENS_CONFIG=/nonexistent/config bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CLAUDE-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'config not found'; then
  ok "missing config -> FAILED"; else bad "missing config (out=[$out])"; fi

AL=$(mktemp)
out=$(PATH="$BIN:$PATH" ARGS_LOG="$AL" CLAUDE_LENS_MODEL=model-under-test bash "$ENGINE" --base "$B")
model=$(grep -A1 '^ARG:--model$' "$AL" | grep -c '^ARG:model-under-test$')
effort=$(grep -A1 '^ARG:--effort$' "$AL" | grep -c '^ARG:medium$')
safe=$(grep -c '^ARG:--safe-mode$' "$AL")
restricted=$(grep -c '^ARG:--restricted$' "$AL")
tools=$(grep -A1 '^ARG:--tools$' "$AL" | grep -c '^ARG:Read,Grep,Glob$')
no_write=$(grep -Ec '^ARG:(Bash|Edit|Write)$' "$AL" || true)
schema_arg=$(grep -A1 '^ARG:--json-schema$' "$AL" | tail -1 | sed 's/^ARG://')
schema_clean=$(printf '%s' "$schema_arg" | jq -e 'has("$schema") | not' >/dev/null 2>&1; echo $?)
if [ "$(starts_with "$out" 'CLAUDE-LENS: FINDINGS')" = yes ] \
  && [ "$model" = 1 ] && [ "$effort" = 1 ] && [ "$safe" = 1 ] \
  && [ "$restricted" = 1 ] && [ "$tools" = 1 ] && [ "$no_write" = 0 ] \
  && [ "$schema_clean" = 0 ] \
  && grep -q '^ARG:--system-prompt$' "$AL" \
  && grep -q 'You are Claude performing an adversarial software review' "$AL" \
  && grep -q '^<repository_context>$' "$AL"; then
  ok "run passes the model setting, default effort, and restricted read-only tools"
else bad "pin/security assertion (out=[$out] model=$model effort=$effort safe=$safe restricted=$restricted tools=$tools write=$no_write schema_clean=$schema_clean)"; fi
rm -f "$AL"

MINI=$(mktemp -d)
git -C "$MINI" init -q
printf '%s\n' one > "$MINI/tracked.txt"
git -C "$MINI" add tracked.txt
git -C "$MINI" -c user.name=test -c user.email=test@example.com commit -qm one
printf '%s\n' two > "$MINI/tracked.txt"
git -C "$MINI" add tracked.txt
git -C "$MINI" -c user.name=test -c user.email=test@example.com commit -qm two
printf '%s\n' local-secret > "$MINI/secret.env"
AL=$(mktemp)
out=$(cd "$MINI" && PATH="$BIN:$PATH" ARGS_LOG="$AL" bash "$ENGINE" --base HEAD^)
if [ "$(starts_with "$out" 'CLAUDE-LENS: FINDINGS')" = yes ] \
  && grep -q '^TRACKED:two$' "$AL" && grep -q '^UNTRACKED:no$' "$AL"; then
  ok "review snapshot contains committed context and excludes untracked files"
else bad "tracked snapshot isolation (out=[$out] log=[$(cat "$AL")])"; fi
rm -rf "$MINI"; rm -f "$AL"

AL=$(mktemp)
# shellcheck disable=SC2016
out=$(PATH="$BIN:$PATH" ARGS_LOG="$AL" CLAUDE_LENS_MODEL='${user_config.claude_model}' bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CLAUDE-LENS: FINDINGS')" = yes ] \
  && [ "$(grep -c '^ARG:--model$' "$AL")" = 0 ] \
  && [ "$(grep -c '^ARG:--restricted$' "$AL")" = 1 ]; then
  ok "blank model setting passes no --model and keeps the restricted posture"
else bad "blank model setting (out=[$out])"; fi
rm -f "$AL"

AL=$(mktemp)
repo_root=$(git rev-parse --show-toplevel)
out=$(PATH="$BIN:$PATH" ARGS_LOG="$AL" bash "$ENGINE" --base "$B")
review_pwd=$(grep '^PWD:' "$AL" | tail -1 | sed 's/^PWD://')
if [ "$(starts_with "$out" 'CLAUDE-LENS: FINDINGS')" = yes ] \
  && [ -n "$review_pwd" ] && [ "$review_pwd" != "$repo_root" ]; then
  ok "Claude runs from an isolated temporary root, not the live checkout"
else bad "isolated cwd (out=[$out] pwd=[$review_pwd] repo=[$repo_root])"; fi
rm -f "$AL"

AL=$(mktemp)
out=$(PATH="$BIN:$PATH" ARGS_LOG="$AL" CLAUDE_LENS_MAX_INLINE_FILES=-1 bash "$ENGINE" --base "$B")
large_dir=$(grep -A1 '^ARG:--add-dir$' "$AL" | tail -1 | sed 's/^ARG://')
if [ "$(starts_with "$out" 'CLAUDE-LENS: FINDINGS')" = yes ] \
  && [ -n "$large_dir" ] && grep -q '## Complete Patch' "$AL" \
  && [ ! -e "$large_dir" ]; then
  ok "large diff uses a private readable artifact and cleans it afterward"
else bad "large-diff artifact path (out=[$out] dir=[$large_dir])"; fi
rm -f "$AL"

out=$(PATH="$BIN:$PATH" CLAUDE_RC=3 bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CLAUDE-LENS: FAILED')" = yes ]; then
  ok "non-zero Claude exit -> FAILED"; else bad "non-zero exit (out=[$out])"; fi

out=$(PATH="$BIN:$PATH" CLAUDE_BAD_JSON=1 bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CLAUDE-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'structured output missing'; then
  ok "malformed structured output -> FAILED"; else bad "malformed output (out=[$out])"; fi

out=$(PATH="$BIN:$PATH" CLAUDE_OFF_SCHEMA=1 bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CLAUDE-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'findings: missing'; then
  ok "structured output off the schema -> FAILED"; else bad "off-schema output (out=[$out])"; fi

out=$(PATH="$BIN:$PATH" CLAUDE_STDERR='benign CLI warning' bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CLAUDE-LENS: FINDINGS')" = yes ]; then
  ok "benign Claude stderr does not corrupt structured stdout"
else bad "stderr/stdout separation (out=[$out])"; fi

DRIFT_PROMPT=$(mktemp)
sed '/{{USER_FOCUS}}/d' "$(dirname "$ENGINE")/../../codex-lens/codex-lens.prompt.md" > "$DRIFT_PROMPT"
out=$(PATH="$BIN:$PATH" CLAUDE_LENS_PROMPT="$DRIFT_PROMPT" bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CLAUDE-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'template drift'; then
  ok "shared prompt token drift fails closed"
else bad "prompt drift (out=[$out])"; fi
rm -f "$DRIFT_PROMPT"

AL=$(mktemp)
out=$(PATH="$BIN:$PATH" ARGS_LOG="$AL" bash "$ENGINE" --base "$B" "myfocus && --base OTHER")
if grep -q 'User focus: myfocus && --base OTHER' "$AL" \
  && grep -q "Target: branch diff against $B" "$AL" \
  && ! grep -q 'Target: branch diff against OTHER' "$AL"; then
  ok "focus is byte-preserved and cannot hijack the base"
else bad "focus/base forwarding"; fi
rm -f "$AL"

out=$(PATH="$BIN:$PATH" bash "$ENGINE" --base definitely-not-a-real-ref-xyz)
if [ "$(starts_with "$out" 'CLAUDE-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'merge-base'; then
  ok "bogus base -> FAILED"; else bad "bogus base (out=[$out])"; fi

out=$(PATH="$BIN:$PATH" bash "$ENGINE" --base --octopus)
if [ "$(starts_with "$out" 'CLAUDE-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'not a Git option'; then
  ok "flag-shaped base is rejected before Git option parsing"
else bad "flag-shaped base (out=[$out])"; fi

REAL_GIT=$(command -v git)
cat > "$BIN/git" <<STUB
#!/bin/bash
if [ "\${1:-}" = diff ] && printf '%s\n' "\$@" | grep -q -- '--submodule=diff'; then
  echo 'planted diff collection failure' >&2
  exit 3
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$BIN/git"
out=$(PATH="$BIN:$PATH" bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CLAUDE-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'planted diff collection failure'; then
  ok "diff collection failure cannot become a clean verdict"
else bad "diff collection failure (out=[$out])"; fi
rm -f "$BIN/git"

GIT_LOG=$(mktemp)
cat > "$BIN/git" <<STUB
#!/bin/bash
printf 'CALL' >> "$GIT_LOG"
printf ' <%s>' "\$@" >> "$GIT_LOG"
printf '\n' >> "$GIT_LOG"
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$BIN/git"
out=$(PATH="$BIN:$PATH" bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CLAUDE-LENS: FINDINGS')" = yes ] \
  && grep -q 'CALL <rev-parse> <--verify> <HEAD' "$GIT_LOG" \
  && ! grep -q '\.\.HEAD>' "$GIT_LOG"; then
  ok "evidence range pins HEAD to one immutable commit"
else bad "immutable range (out=[$out] git=[$(cat "$GIT_LOG")])"; fi
rm -f "$BIN/git" "$GIT_LOG"

printf '%s\n' '#!/bin/bash' 'echo starting' 'sleep 30' > "$BIN/claude"; chmod +x "$BIN/claude"
SECONDS=0
out=$(PATH="$BIN:$PATH" CLAUDE_LENS_TIMEOUT=2 bash "$ENGINE" --base "$B" 2>&1); elapsed=$SECONDS
if [ "$(starts_with "$out" 'CLAUDE-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'timed out after 2s' && [ "$elapsed" -lt 15 ]; then
  ok "hung run hits watchdog -> FAILED (${elapsed}s)"; else bad "watchdog (out=[$out] elapsed=$elapsed)"; fi

# An empty BASE..HEAD range is SKIPPED, and the model is never called.
printf '#!/bin/bash\necho called >> "${ARGS_LOG:-/dev/null}"\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
AL=$(mktemp)
out=$(PATH="$BIN:$PATH" ARGS_LOG="$AL" bash "$ENGINE" --base HEAD)
if [ "$(starts_with "$out" 'CLAUDE-LENS: SKIPPED')" = yes ] && echo "$out" | grep -q 'empty range' && [ ! -s "$AL" ]; then
  ok "empty range -> SKIPPED, no model call"
else bad "empty range (out=[$out] calls=[$(cat "$AL")])"; fi
rm -f "$AL"

cd / && rm -rf "$FIX"
echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
