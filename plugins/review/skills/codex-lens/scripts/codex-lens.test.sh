#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Self-contained tests for codex-lens.sh — the /review:codex-lens engine (also review-panel
# Step 2.6). Guards the load-bearing contract:
#   - SKIPPED is emitted ONLY for the structural codex-not-installed case; every other
#     non-zero exit (and a timeout) is FAILED, never relabelled a benign skip.
#   - the run forwards the model and reasoning effort from the settings and always the
#     read-only sandbox (the whole point of the direct-`codex exec` design), regardless of
#     the local Codex config; a blank model leaves Codex on its own default.
#   - the wall-clock watchdog degrades a wedged run to FAILED, never hangs.
# No real Codex needed: a stubbed `codex` on PATH stands in for the CLI; git runs for real
# against this repo, so tests use real refs (HEAD / a bogus ref).
# Run: bash codex-lens.test.sh  (exits non-zero on failure)
set -uo pipefail

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/codex-lens.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
starts_with() { case "$1" in "$2"*) echo yes;; *) echo no;; esac; }  # stdout begins with token?

echo "codex-lens.sh tests:"

# A fixture repo with a real, non-empty range: B is the base commit, HEAD adds one file
# whose text carries an `&` (bash 5.2's patsub_replacement would turn an unquoted
# replacement's `&` into the matched token). An untracked .env sits in the checkout.
FIX=$(cd "$(mktemp -d)" && pwd -P)
git init -q "$FIX"; git -C "$FIX" config user.email test@example.com; git -C "$FIX" config user.name t
echo base > "$FIX/base.txt"; git -C "$FIX" add base.txt; git -C "$FIX" commit -qm base
B=$(git -C "$FIX" rev-parse HEAD)
printf 'x & y\n' > "$FIX/change.txt"; git -C "$FIX" add change.txt; git -C "$FIX" commit -qm "add change"
echo "SECRET=1" > "$FIX/.env"
cd "$FIX" || exit 1

# 1. no args -> FAILED (base required), exit 0
out=$(bash "$ENGINE"); rc=$?
if [ "$(starts_with "$out" 'CODEX-LENS: FAILED')" = yes ] && [ "$rc" -eq 0 ]; then
  ok "no args -> FAILED, exit 0"; else bad "no args (out=[$out] rc=$rc)"; fi

# 2. bare trailing --base -> FAILED, exit 0 (the guarded 2nd shift: must not hang)
out=$(bash "$ENGINE" --base); rc=$?
if [ "$(starts_with "$out" 'CODEX-LENS: FAILED')" = yes ] && [ "$rc" -eq 0 ]; then
  ok "bare --base -> FAILED, no hang"; else bad "bare --base (out=[$out] rc=$rc)"; fi

# 3. --base= (empty) -> FAILED
out=$(bash "$ENGINE" --base=)
if [ "$(starts_with "$out" 'CODEX-LENS: FAILED')" = yes ]; then
  ok "--base= empty -> FAILED"; else bad "--base= (out=[$out])"; fi

# 4. codex off PATH -> SKIPPED (not installed), exit 0. Minimal PATH lacks codex but keeps
#    the builtins the skip path needs.
out=$(PATH="/usr/bin:/bin" bash "$ENGINE" --base "$B"); rc=$?
if [ "$(starts_with "$out" 'CODEX-LENS: SKIPPED')" = yes ] && [ "$rc" -eq 0 ]; then
  ok "codex off PATH -> SKIPPED (not installed)"; else bad "not-installed (out=[$out] rc=$rc)"; fi

# --- stub codex on PATH for the run/classify/pin tests ---
BIN=$(mktemp -d)
# The stub logs its argv + stdin to $ARGS_LOG and writes stub findings JSON to the -o file, so
# the engine's exit-0 path reads a non-empty final message. Single-quoted heredoc: $@/$ARGS_LOG
# must expand when the STUB runs, not when this file is written.
# shellcheck disable=SC2016
cat > "$BIN/codex" <<'STUB'
#!/bin/bash
LOG="${ARGS_LOG:-/dev/null}"
: > "$LOG"
lastmsg=""; prev=""
for a in "$@"; do
  printf 'ARG:%s\n' "$a" >> "$LOG"
  [ "$prev" = "-o" ] && lastmsg="$a"
  prev="$a"
done
printf 'STDIN<<\n' >> "$LOG"; cat >> "$LOG"; printf '\n>>STDIN\n' >> "$LOG"
[ -n "$lastmsg" ] && printf '{"verdict":"approve","summary":"stub","findings":[],"next_steps":[]}\n' > "$lastmsg"
exit ${CODEX_RC:-0}
STUB
chmod +x "$BIN/codex"

# 5. missing config -> FAILED (a committed artifact; its absence is broken, not a skip)
out=$(PATH="$BIN:$PATH" CODEX_LENS_CONFIG=/nonexistent/codex-lens.config bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CODEX-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'config not found'; then
  ok "missing config -> FAILED"; else bad "missing config (out=[$out])"; fi

# 6. missing prompt -> FAILED
out=$(PATH="$BIN:$PATH" CODEX_LENS_PROMPT=/nonexistent/codex-lens.prompt.md bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CODEX-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'prompt not found'; then
  ok "missing prompt -> FAILED"; else bad "missing prompt (out=[$out])"; fi

# 7. Settings reach `codex exec`: the model and effort the skill passes (CODEX_LENS_MODEL /
#    CODEX_LENS_EFFORT, the substituted plugin settings) are forwarded as -c overrides, with the
#    read-only sandbox, and exit 0 -> FINDINGS.
AL=$(mktemp)
out=$(PATH="$BIN:$PATH" ARGS_LOG="$AL" CODEX_LENS_MODEL=model-under-test CODEX_LENS_EFFORT=medium bash "$ENGINE" --base "$B")
model_set=$(grep -c '^ARG:model=model-under-test$' "$AL")
effort_set=$(grep -c '^ARG:model_reasoning_effort=medium$' "$AL")
sandbox_set=$(grep -A1 '^ARG:-s$' "$AL" | grep -c '^ARG:read-only$')
exec_sub=$(grep -c '^ARG:exec$' "$AL")
if [ "$(starts_with "$out" 'CODEX-LENS: FINDINGS')" = yes ] \
  && [ "$model_set" = 1 ] && [ "$effort_set" = 1 ] && [ "$sandbox_set" = 1 ] && [ "$exec_sub" = 1 ]; then
  ok "settings reach codex exec: model + effort + read-only sandbox -> FINDINGS"
else bad "settings assertion (findings=$(starts_with "$out" 'CODEX-LENS: FINDINGS') model=$model_set effort=$effort_set sandbox=$sandbox_set exec=$exec_sub)"; fi
rm -f "$AL"

# 7a. A blank model (setting left empty, or an unsubstituted placeholder) passes no model
#     override, so Codex uses its own default; effort falls back to the default "high".
AL=$(mktemp)
# shellcheck disable=SC2016
out=$(PATH="$BIN:$PATH" ARGS_LOG="$AL" CODEX_LENS_MODEL='${user_config.codex_model}' CODEX_LENS_EFFORT='' bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CODEX-LENS: FINDINGS')" = yes ] \
  && [ "$(grep -c '^ARG:model=' "$AL")" = 0 ] \
  && [ "$(grep -c '^ARG:model_reasoning_effort=high$' "$AL")" = 1 ]; then
  ok "blank model -> no model override; effort defaults to high"
else bad "blank model (out=[$out])"; fi
rm -f "$AL"

# 7b. ENFORCEMENT: a pre-set env var must NOT weaken the sandbox. Even with a hostile
#     CODEX_LENS_SANDBOX in the environment, the config's HARD assignment wins.
AL=$(mktemp)
out=$(PATH="$BIN:$PATH" ARGS_LOG="$AL" CODEX_LENS_SANDBOX="workspace-write" bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CODEX-LENS: FINDINGS')" = yes ] \
  && [ "$(grep -A1 '^ARG:-s$' "$AL" | grep -c '^ARG:read-only$')" = 1 ] && [ "$(grep -c '^ARG:workspace-write$' "$AL")" = 0 ]; then
  ok "env var cannot weaken the sandbox (config hard-assign wins)"
else bad "sandbox env enforcement (ww=$(grep -c '^ARG:workspace-write$' "$AL"))"; fi
rm -f "$AL"

# 7c. a config that (mis-)sets sandbox to anything but read-only is REJECTED -> FAILED: the
#     read-only contract is enforced in code, not merely by the committed config's value.
BADCFG=$(mktemp)
printf 'CODEX_LENS_SANDBOX=workspace-write\n' > "$BADCFG"
out=$(PATH="$BIN:$PATH" CODEX_LENS_CONFIG="$BADCFG" bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CODEX-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'sandbox must be read-only'; then
  ok "non-read-only sandbox in config -> FAILED (read-only enforced in code)"; else bad "sandbox validation (out=[$out])"; fi
rm -f "$BADCFG"

# 7d. A Claude Code authoring environment must not change direct codex-lens behavior. Runtime
# selection belongs to review-panel's counterpart dispatcher; the engine itself stays Codex-only.
AL=$(mktemp)
out=$(PATH="$BIN:$PATH" ARGS_LOG="$AL" CLAUDE_CODE_SESSION_ID="claude-author" bash "$ENGINE" --base "$B" "claude author focus")
if [ "$(starts_with "$out" 'CODEX-LENS: FINDINGS')" = yes ] \
  && [ "$(grep -c '^ARG:exec$' "$AL")" = 1 ] \
  && [ "$(grep -A1 '^ARG:-s$' "$AL" | grep -c '^ARG:read-only$')" = 1 ] \
  && grep -q 'User focus: claude author focus' "$AL"; then
  ok "Claude authoring env leaves direct Codex lens behavior unchanged"
else bad "Claude author routing (out=[$out])"; fi
rm -f "$AL"

# 8. codex exec non-zero -> FAILED (never a skip, whatever the output says)
out=$(PATH="$BIN:$PATH" CODEX_RC=3 bash "$ENGINE" --base "$B")
if [ "$(starts_with "$out" 'CODEX-LENS: FAILED')" = yes ]; then
  ok "codex exec non-zero -> FAILED"; else bad "non-zero class (out=[$out])"; fi

# 9. focus rides as one opaque User-focus value and cannot hijack the review range: a stray
#    "--base OTHER" inside the focus text stays in the prompt's User focus, and the target label
#    (hence the git range) still uses the real base, never OTHER.
AL=$(mktemp)
out=$(PATH="$BIN:$PATH" ARGS_LOG="$AL" bash "$ENGINE" --base "$B" "myfocus --base OTHER")
if grep -q 'User focus: myfocus --base OTHER' "$AL" \
  && grep -q "Target: branch diff against $B" "$AL" \
  && ! grep -q 'Target: branch diff against OTHER' "$AL"; then
  ok "focus is opaque and cannot hijack the base"; else bad "focus hijack (stdin=[$(sed -n '/STDIN<</,/>>STDIN/p' "$AL" | grep -E 'Target|User focus')])"; fi
rm -f "$AL"

# 9b. a --base as the FIRST separate focus word must NOT hijack the range: `--base B --base OTHER`
#     keeps BASE=B (only the first arg is parsed as --base) and rides "--base OTHER" as focus.
AL=$(mktemp)
out=$(PATH="$BIN:$PATH" ARGS_LOG="$AL" bash "$ENGINE" --base "$B" --base OTHER)
if grep -q "Target: branch diff against $B" "$AL" && ! grep -q 'Target: branch diff against OTHER' "$AL" \
  && grep -q 'User focus: --base OTHER' "$AL"; then
  ok "a second --base token cannot hijack the range (stays in focus)"; else bad "split --base hijack (target=[$(grep 'Target:' "$AL")])"; fi
rm -f "$AL"

# 10. a bogus --base (no merge-base with HEAD) -> FAILED, not a skip
out=$(PATH="$BIN:$PATH" bash "$ENGINE" --base definitely-not-a-real-ref-xyz)
if [ "$(starts_with "$out" 'CODEX-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'merge-base'; then
  ok "bogus --base -> FAILED (bad base)"; else bad "bad base (out=[$out])"; fi

# --- Input and failure handling, one row each: an & in the text survives, a flag-shaped base,
#     a git collection error, an empty range, Codex runs in a snapshot of the committed files,
#     the tip is pinned, a missing schema, stderr kept apart, an empty final message.
# A git wrapper for the git-error and pinned-tip rows: GIT_FAIL_ON=<subcommand> fails that subcommand; GIT_COMMIT_ON_MERGE_BASE=1
# lands a new commit right after the merge-base is computed (a commit mid-run).
GBIN=$(mktemp -d); REAL_GIT=$(command -v git)
cat > "$GBIN/git" <<STUB
#!/bin/bash
sub=""; for a in "\$@"; do case "\$a" in -*) ;; *) sub=\$a; break ;; esac; done
if [ -n "\${GIT_FAIL_ON:-}" ] && [ "\$sub" = "\$GIT_FAIL_ON" ]; then echo "fatal: injected failure" >&2; exit 128; fi
"$REAL_GIT" "\$@"; rc=\$?
if [ "\$sub" = merge-base ] && [ -n "\${GIT_COMMIT_ON_MERGE_BASE:-}" ] && [ ! -e "$FIX/.git/midrun-done" ]; then
  : > "$FIX/.git/midrun-done"
  printf 'MIDRUN-CONTENT\\n' > "$FIX/midrun.txt"; "$REAL_GIT" -C "$FIX" add midrun.txt; "$REAL_GIT" -C "$FIX" commit -qm midrun
fi
exit \$rc
STUB
chmod +x "$GBIN/git"
# A codex stub that records its cwd and whether .env is visible there; CODEX_STDERR adds
# stderr noise; CODEX_NO_FINAL=1 exits 0 without writing the final message; CODEX_FINAL replaces it.
cat > "$BIN/codex" <<'STUB'
#!/bin/bash
LOG="${ARGS_LOG:-/dev/null}"
: > "$LOG"
lastmsg=""; prev=""; cdir=""
for a in "$@"; do
  printf 'ARG:%s\n' "$a" >> "$LOG"
  [ "$prev" = "-o" ] && lastmsg="$a"
  [ "$prev" = "-C" ] && cdir="$a"
  prev="$a"
done
[ -n "$cdir" ] && cd "$cdir"
printf 'CWD:%s\n' "$(pwd -P)" >> "$LOG"
[ -e .env ] && printf 'ENV-VISIBLE\n' >> "$LOG"
printf 'STDIN<<\n' >> "$LOG"; cat >> "$LOG"; printf '\n>>STDIN\n' >> "$LOG"
[ -n "${CODEX_STDERR:-}" ] && printf '%s\n' "$CODEX_STDERR" >&2
final='{"verdict":"approve","summary":"stub","findings":[],"next_steps":[]}'
[ -n "${CODEX_FINAL:-}" ] && final=$CODEX_FINAL
[ -z "${CODEX_NO_FINAL:-}" ] && [ -n "$lastmsg" ] && printf '%s\n' "$final" > "$lastmsg"
exit ${CODEX_RC:-0}
STUB
chmod +x "$BIN/codex"

# Rows: name | args (B = base) | extra env | want leading token | grep that must match the
#       output or the codex log (O:<re> = output, L:<re> = log, !L:<re> = log must NOT match)
CASES=(
  "an & in the focus text survives|--base B check a && b||CODEX-LENS: FINDINGS|L:User focus: check a && b"
  "an & in the diff survives|--base B||CODEX-LENS: FINDINGS|L:^\+x & y"
  "a flag-shaped base is rejected|--base --octopus||CODEX-LENS: FAILED|O:must not start with"
  "a flag-shaped --base= is rejected|--base=--all||CODEX-LENS: FAILED|O:must not start with"
  "a failing git diff is FAILED, not a review|--base B|GIT_FAIL_ON=diff|CODEX-LENS: FAILED|O:injected failure"
  "a failing git log is FAILED, not a review|--base B|GIT_FAIL_ON=log|CODEX-LENS: FAILED|O:injected failure"
  "an empty range is SKIPPED without a model call|--base HEAD||CODEX-LENS: SKIPPED|!L:ARG:exec"
  "codex runs in a snapshot without untracked files|--base B||CODEX-LENS: FINDINGS|!L:ENV-VISIBLE"
  "codex does not run in the live checkout|--base B||CODEX-LENS: FINDINGS|!L:CWD:$FIX\$"
  "a commit landing mid-run is not reviewed|--base B|GIT_COMMIT_ON_MERGE_BASE=1|CODEX-LENS: FINDINGS|!L:MIDRUN-CONTENT"
  "a missing schema is FAILED|--base B|CODEX_LENS_SCHEMA=/nonexistent/schema.json|CODEX-LENS: FAILED|O:schema not found"
  "stderr is not part of the findings|--base B|CODEX_STDERR=noise-on-stderr|CODEX-LENS: FINDINGS|!O:noise-on-stderr"
  "an empty final message is FAILED|--base B|CODEX_NO_FINAL=1|CODEX-LENS: FAILED|O:no final message"
  "a final message that is not JSON is FAILED|--base B|CODEX_FINAL=plain-text|CODEX-LENS: FAILED|O:not JSON"
  "a final message off the schema is FAILED|--base B|CODEX_FINAL={\"verdict\":\"maybe\"}|CODEX-LENS: FAILED|O:verdict: not one of"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name args extra want check <<<"$row"
  AL=$(mktemp); rm -f "$FIX/.git/midrun-done"
  args=${args//B/$B}
  # shellcheck disable=SC2086
  if [ -n "$extra" ]; then
    out=$(env PATH="$GBIN:$BIN:$PATH" ARGS_LOG="$AL" "$extra" bash "$ENGINE" $args 2>/dev/null)
  else
    out=$(env PATH="$GBIN:$BIN:$PATH" ARGS_LOG="$AL" bash "$ENGINE" $args 2>/dev/null)
  fi
  verdict=no
  if [ "$(starts_with "$out" "$want")" = yes ]; then
    case "$check" in
      O:*)  printf '%s\n' "$out" | grep -qE -- "${check#O:}" && verdict=yes ;;
      !O:*) printf '%s\n' "$out" | grep -qE -- "${check#!O:}" || verdict=yes ;;
      L:*)  grep -qE -- "${check#L:}" "$AL" && verdict=yes ;;
      !L:*) grep -qE -- "${check#!L:}" "$AL" || verdict=yes ;;
    esac
  fi
  [ "$verdict" = yes ] && ok "$name" || bad "$name (out=[$(printf '%s' "$out" | head -3)])"
  rm -f "$AL"
done
rm -rf "$GBIN"

rm -rf "$BIN"

# --- watchdog: a hung / TERM-deaf run degrades to FAILED, never hangs; a garbage cap falls back ---
HBIN=$(mktemp -d)

# 11. a run whose exec never returns must hit the wall-clock cap and degrade to FAILED. cap=2s; an
#     uncapped wrapper would `wait` for the stub's full sleep (~1000s).
printf '#!/bin/bash\necho starting\nsleep 30\n' > "$HBIN/codex"; chmod +x "$HBIN/codex"
SECONDS=0
out=$(PATH="$HBIN:$PATH" CODEX_LENS_TIMEOUT=2 bash "$ENGINE" --base "$B" 2>&1); el=$SECONDS
if [ "$(starts_with "$out" 'CODEX-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'timed out after 2s' && [ "$el" -lt 15 ]; then
  ok "hung run hits the wall-clock cap -> FAILED (${el}s)"; else bad "wall-clock cap (out=[$out] elapsed=${el}s)"; fi

# 12. a TERM-deaf run (ignores SIGTERM) must still die via the SIGKILL escalation -> FAILED. cap=2s
#     + ~3s grace.
printf '#!/bin/bash\ntrap "" TERM\necho starting\nsleep 30\n' > "$HBIN/codex"; chmod +x "$HBIN/codex"
SECONDS=0
out=$(PATH="$HBIN:$PATH" CODEX_LENS_TIMEOUT=2 bash "$ENGINE" --base "$B" 2>&1); el=$SECONDS
if [ "$(starts_with "$out" 'CODEX-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'timed out after 2s' && [ "$el" -lt 15 ]; then
  ok "TERM-deaf run hits the SIGKILL escalation -> FAILED (${el}s)"; else bad "SIGKILL escalation (out=[$out] elapsed=${el}s)"; fi

# 13. a garbage CODEX_LENS_TIMEOUT (non-integer) must fall back to the default, NOT instant-FAIL a
#     healthy fast run. Fast stub writes the -o file so exit-0 reads FINDINGS.
# shellcheck disable=SC2016
cat > "$HBIN/codex" <<'STUB'
#!/bin/bash
prev=""; for a in "$@"; do [ "$prev" = "-o" ] && printf '{"verdict":"approve","summary":"x","findings":[],"next_steps":[]}\n' > "$a"; prev="$a"; done
exit 0
STUB
chmod +x "$HBIN/codex"
SECONDS=0
out=$(PATH="$HBIN:$PATH" CODEX_LENS_TIMEOUT=abc bash "$ENGINE" --base "$B" 2>&1); el=$SECONDS
if [ "$(starts_with "$out" 'CODEX-LENS: FINDINGS')" = yes ] && [ "$el" -lt 15 ]; then
  ok "garbage CODEX_LENS_TIMEOUT falls back to default, no instant-FAIL"; else bad "invalid-timeout guard (out=[$out] elapsed=${el}s)"; fi

# 13b. CODEX_LENS_TIMEOUT=0 means the default, not "time out at once": a run that takes a second
#      still reads FINDINGS. The run lasts past the watchdog's 3-second SIGKILL grace, so a cap of
#      zero would end it (TERM is ignored by the background run; the SIGKILL is not).
cat > "$HBIN/codex" <<'STUB'
#!/bin/bash
prev=""; for a in "$@"; do [ "$prev" = "-o" ] && printf '{"verdict":"approve","summary":"x","findings":[],"next_steps":[]}\n' > "$a"; prev="$a"; done
exec sleep 5
STUB
chmod +x "$HBIN/codex"
out=$(PATH="$HBIN:$PATH" CODEX_LENS_TIMEOUT=0 bash "$ENGINE" --base "$B" 2>&1)
if [ "$(starts_with "$out" 'CODEX-LENS: FINDINGS')" = yes ]; then
  ok "CODEX_LENS_TIMEOUT=0 falls back to the default, no instant-FAIL"; else bad "zero-timeout guard (out=[$(printf '%s' "$out" | head -2)])"; fi

# 14. an all-digits but INT64-overflowing CODEX_LENS_TIMEOUT (>8 digits) must be clamped to default.
SECONDS=0
out=$(PATH="$HBIN:$PATH" CODEX_LENS_TIMEOUT=99999999999999999999999 bash "$ENGINE" --base "$B" 2>&1); el=$SECONDS
if [ "$(starts_with "$out" 'CODEX-LENS: FINDINGS')" = yes ] && [ "$el" -lt 15 ]; then
  ok "overflowing CODEX_LENS_TIMEOUT is clamped to default, no instant-FAIL"; else bad "overflow-timeout guard (out=[$out] elapsed=${el}s)"; fi

rm -rf "$HBIN"

cd / && rm -rf "$FIX"
echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
