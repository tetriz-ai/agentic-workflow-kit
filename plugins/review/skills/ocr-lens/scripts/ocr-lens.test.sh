#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Self-contained tests for ocr-lens.sh — the /review:ocr-lens engine (also review-panel Step 2.6).
# Guards the load-bearing contract: SKIPPED is emitted ONLY for the three structural cases
# (ocr not installed / no key / no reviewable files — every changed file excluded by ocr's
# filter), every other non-zero outcome is FAILED (never a benign skip), the wall-clock cap
# contains a hang, args forward safely, and the key is redacted.
# No real ocr and no network: a stub `ocr` on PATH stands in; real `node` parses the JSON.
# Run: bash ocr-lens.test.sh   (exits non-zero on failure)
set -uo pipefail
# Every temp path this test creates goes under one directory, removed on exit (a local
# mktemp, since some mktemp builds ignore TMPDIR).
TEST_TMP="$(command mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mktemp() {
  case "${1:-}" in
    -d) command mktemp -d "$TEST_TMP/t.XXXXXX" ;;
    -u) command mktemp -u "$TEST_TMP/t.XXXXXX" ;;
    *)  command mktemp "$TEST_TMP/t.XXXXXX" ;;
  esac
}

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ocr-lens.sh"
# A fixture repo with one reviewable commit, so BASE..HEAD is HEAD~1..HEAD.
FIXREPO="$TEST_TMP/repo"; git init -q "$FIXREPO"
git -C "$FIXREPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base
echo x > "$FIXREPO/a.go"; git -C "$FIXREPO" add a.go
git -C "$FIXREPO" -c user.name=t -c user.email=t@example.com commit -q -m change
cd "$FIXREPO" || exit 1
# A key that deliberately does NOT look like the belt's `sk-<long>` shape (it is too short), so the
# redaction test proves the format-independent literal-value scrub.
TESTKEY="unittest-key-0123456789"
# Two generic gateways, in fallback order; the second is the fallback in the chain tests.
GW_PRIMARY='{"name":"primary","url":"https://primary.example.com/v1/chat/completions","model":"m-primary","key_env":"PRIMARY_KEY","key_file":"~/.config/ocr/primary_key","extra_body":{"temperature":0}}'
GW_SECONDARY='{"name":"secondary","url":"https://secondary.example.net/v1/chat/completions","model":"m-secondary","key_file":"~/.config/ocr/secondary_key"}'
export OCR_GATEWAYS_JSON="[$GW_PRIMARY,$GW_SECONDARY]"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
starts_with() { case "$1" in "$2"*) echo yes;; *) echo no;; esac; }

# Write a stub `ocr` into $1/ocr. Behaviour is driven by env at call time:
#   STUB_RC        non-zero -> `review` prints to stderr and exits RC (config always exits 0)
#   STUB_HANG      non-empty -> `review` sleeps 60s (to exercise the wall-clock cap)
#   STUB_ARGLOG    path      -> `review` appends ARG:<arg> lines (to assert forwarding)
#   STUB_JSON      override the canned success JSON
#   STUB_CONFIGLOG path      -> `config ...` appends CONFIG:<args> lines
make_stub() {
  cat > "$1/ocr" <<'STUB'
#!/bin/bash
if [ "$1" = "config" ]; then [ -n "${STUB_CONFIGLOG:-}" ] && printf 'CONFIG:%s\n' "$*" >> "$STUB_CONFIGLOG"; exit 0; fi
if [ "$1" = "review" ]; then
  if [ -n "${STUB_ARGLOG:-}" ]; then for a in "$@"; do printf 'ARG:%s\n' "$a" >> "$STUB_ARGLOG"; done; fi
  [ -n "${STUB_TOKENLOG:-}" ] && printf '%s' "${OCR_LLM_TOKEN:-}" > "$STUB_TOKENLOG"
  [ -n "${STUB_PROFILELOG:-}" ] && printf '%s|%s\n' "${OCR_LLM_MODEL:-}" "${OCR_LLM_URL:-}" >> "$STUB_PROFILELOG"
  # STUB_FAIL_MODEL: emit a PERMANENT (401) failure only for the named model — lets a test make one
  # gateway in the chain fail so the fallback to the next can be asserted.
  [ -n "${STUB_FAIL_MODEL:-}" ] && [ "${OCR_LLM_MODEL:-}" = "${STUB_FAIL_MODEL}" ] && { printf '%s\n' "${STUB_FAIL_MSG:-HTTP 401 Unauthorized: invalid api key}" >&2; exit 1; }
  if [ -n "${STUB_HANG:-}" ]; then sleep 60; fi
  if [ -n "${STUB_RC:-}" ] && [ "${STUB_RC}" != "0" ]; then printf 'auth failed [token=%s] [other=sk-live-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456]\n' "${OCR_LLM_TOKEN:-}" >&2; exit "$STUB_RC"; fi
  # Assign the default with a plain single-quoted string (NOT ${VAR:-default}) — the JSON's `}`
  # would prematurely close a ${...:-} expansion, the very bug ocr-lens.config also sidesteps.
  json="${STUB_JSON:-}"
  [ -n "$json" ] || json='{"status":"success","comments":[{"path":"a.go","start_line":5,"end_line":7,"severity":"critical","category":"bug","content":"nil deref","suggestion_code":"if x==nil"}],"summary":{"files_reviewed":1,"total_tokens":123,"elapsed":"1s"}}'
  printf '%s' "$json"
  exit 0
fi
exit 0
STUB
  chmod +x "$1/ocr"
}

echo "ocr-lens.sh tests:"

# 1. no args -> FAILED (base required), exit 0
out=$(bash "$ENGINE"); rc=$?
if [ "$(starts_with "$out" 'OCR-LENS: FAILED')" = yes ] && [ "$rc" -eq 0 ]; then
  ok "no args -> FAILED, exit 0"; else bad "no args (out=[$out] rc=$rc)"; fi

# 2. bare trailing --base -> FAILED, no hang (guarded 2nd shift)
out=$(bash "$ENGINE" --base); rc=$?
if [ "$(starts_with "$out" 'OCR-LENS: FAILED')" = yes ] && [ "$rc" -eq 0 ]; then
  ok "bare --base -> FAILED, no hang"; else bad "bare --base (out=[$out] rc=$rc)"; fi

# 3. --base= empty -> FAILED
out=$(bash "$ENGINE" --base=)
if [ "$(starts_with "$out" 'OCR-LENS: FAILED')" = yes ]; then
  ok "--base= empty -> FAILED"; else bad "--base= (out=[$out])"; fi

# 4. ocr off PATH -> SKIPPED (not installed). Minimal PATH lacks ocr.
out=$(PATH="/usr/bin:/bin" OCR_API_KEY="$TESTKEY" bash "$ENGINE" --base HEAD~1); rc=$?
if [ "$(starts_with "$out" 'OCR-LENS: SKIPPED')" = yes ] && echo "$out" | grep -q 'not installed' && [ "$rc" -eq 0 ]; then
  ok "ocr off PATH -> SKIPPED (not installed)"; else bad "not-installed (out=[$out] rc=$rc)"; fi

BIN=$(mktemp -d); make_stub "$BIN"

# 4a. ocr off PATH but resolvable via `npm prefix -g`/bin -> FINDINGS (the install-PATH-gap fix).
#     `npm install -g` lands ocr in the npm global bin, which may not be on the minimal tool PATH
#     even when npm is — the lens must still find it there and not false-SKIP. Clean env: node (for
#     the JSON parser) + a stub npm that reports a prefix whose bin/ holds ocr; ocr is NOT on PATH.
if command -v node >/dev/null 2>&1; then
  PREFIX=$(mktemp -d); mkdir -p "$PREFIX/bin"; make_stub "$PREFIX/bin"   # ocr lives ONLY under the npm prefix
  CLEANBIN=$(mktemp -d); ln -s "$(command -v node)" "$CLEANBIN/node"
  MARK4A=$(mktemp -u)   # written iff the lens actually calls `npm prefix -g` (i.e. took the fallback)
  cat > "$CLEANBIN/npm" <<NPMSTUB
#!/bin/bash
[ "\$1" = "prefix" ] && [ "\$2" = "-g" ] && { : > "$MARK4A"; echo "$PREFIX"; exit 0; }
exit 0
NPMSTUB
  chmod +x "$CLEANBIN/npm"
  out=$(PATH="$CLEANBIN:/usr/bin:/bin" OCR_API_KEY="$TESTKEY" bash "$ENGINE" --base HEAD~1); rc=$?
  # Require the marker too: a stray `ocr` on the system PATH (/usr/bin, /bin) could satisfy
  # `command -v ocr` so the fallback never runs — then FINDINGS alone would pass without testing it.
  if [ "$(starts_with "$out" 'OCR-LENS: FINDINGS')" = yes ] && [ "$rc" -eq 0 ] && [ -f "$MARK4A" ]; then
    ok "ocr off PATH but at npm prefix -> resolved (FINDINGS, fallback exercised)"
  else bad "npm-prefix resolver (out=[$out] rc=$rc fallback-taken=$([ -f "$MARK4A" ] && echo yes || echo NO))"; fi
  rm -f "$MARK4A"

  # 4b. npm present and `npm prefix -g` resolves, but ocr is NOT under prefix/bin -> SKIPPED
  #     (not installed). The other half of the resolver: the fallback must not false-resolve, and the
  #     skip message must name the npm-bin path it looked at (proof), not degenerate to "/bin/ocr".
  EMPTYPREFIX=$(mktemp -d); mkdir -p "$EMPTYPREFIX/bin"   # prefix exists, but no ocr in it
  MISSBIN=$(mktemp -d); ln -s "$(command -v node)" "$MISSBIN/node"
  cat > "$MISSBIN/npm" <<NPMSTUB
#!/bin/bash
[ "\$1" = "prefix" ] && [ "\$2" = "-g" ] && { echo "$EMPTYPREFIX"; exit 0; }
exit 0
NPMSTUB
  chmod +x "$MISSBIN/npm"
  out=$(PATH="$MISSBIN:/usr/bin:/bin" OCR_API_KEY="$TESTKEY" bash "$ENGINE" --base HEAD~1); rc=$?
  if [ "$(starts_with "$out" 'OCR-LENS: SKIPPED')" = yes ] && echo "$out" | grep -q 'not installed' \
     && echo "$out" | grep -qF "$EMPTYPREFIX/bin/ocr" && [ "$rc" -eq 0 ]; then
    ok "npm present, ocr not at prefix/bin -> SKIPPED (names npm-bin path)"; else bad "npm-prefix miss (out=[$out] rc=$rc)"; fi
  rm -rf "$PREFIX" "$CLEANBIN" "$EMPTYPREFIX" "$MISSBIN"
else
  echo "SKIP: node not installed; the npm-prefix resolver rows did not run"
fi

# 5. ocr present but no key for ANY gateway in the chain -> SKIPPED (chain exhausted). HOME-redirect so
#    neither gateway's key file exists, and unset the direct-token envs. Keep the full PATH (node parses).
EMPTYHOME=$(mktemp -d)
out=$(env -u PRIMARY_KEY -u OCR_API_KEY HOME="$EMPTYHOME" PATH="$BIN:$PATH" bash "$ENGINE" --base HEAD~1); rc=$?
if [ "$(starts_with "$out" 'OCR-LENS: SKIPPED')" = yes ] && echo "$out" | grep -q 'no API key' && [ "$rc" -eq 0 ]; then
  ok "no key for any gateway -> SKIPPED (chain exhausted)"; else bad "no-key skip (out=[$out] rc=$rc)"; fi
rm -rf "$EMPTYHOME"

# 6. ocr present + key + config present -> FINDINGS with graded critical + summary + fix
out=$(PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" bash "$ENGINE" --base HEAD~1); rc=$?
if [ "$(starts_with "$out" 'OCR-LENS: FINDINGS')" = yes ] \
   && echo "$out" | grep -q '\[CRITICAL\] a.go:5-7 (bug)' \
   && echo "$out" | grep -q 'nil deref' \
   && echo "$out" | grep -q 'suggested fix' && [ "$rc" -eq 0 ]; then
  ok "run success -> FINDINGS (graded, located, with fix)"; else bad "findings (out=[$out] rc=$rc)"; fi

# 7. ocr review non-zero -> FAILED (never a skip), and the key in the error is REDACTED. Assert the
#    literal $KEY scrub AND the secondary belt for a long `sk-` token.
out=$(PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" STUB_RC=2 bash "$ENGINE" --base HEAD~1)
if [ "$(starts_with "$out" 'OCR-LENS: FAILED')" = yes ] \
   && echo "$out" | grep -q 'REDACTED-KEY' \
   && ! echo "$out" | grep -qF "$TESTKEY" \
   && ! echo "$out" | grep -q 'sk-live-ABCDEFGHIJKLMNOPQRSTUVWXYZ'; then
  ok "run non-zero -> FAILED, literal key and a long sk- token both redacted"; else bad "fail+redact (out=[$out])"; fi

# 8. clean review (no comments) -> FINDINGS with an explicit 0-findings note (not FAILED)
out=$(PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" STUB_JSON='{"status":"success","comments":[],"summary":{}}' bash "$ENGINE" --base HEAD~1)
if [ "$(starts_with "$out" 'OCR-LENS: FINDINGS')" = yes ] && echo "$out" | grep -q '0 findings'; then
  ok "clean review -> FINDINGS (0 findings), not FAILED"; else bad "clean verdict (out=[$out])"; fi

# 9. ocr selected no files (status=skipped) -> SKIPPED (no reviewable files), never a FINDINGS
#    0-findings that reads as a clean cross-model pass. Structural: the engine ran but every
#    changed file was excluded by ocr's filter (test files ARE re-included via .opencodereview/
#    rule.json, so this is a genuinely unreviewable diff — unsupported ext / all-deleted).
out=$(PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" STUB_JSON='{"status":"skipped","comments":[],"summary":{}}' bash "$ENGINE" --base HEAD~1)
if [ "$(starts_with "$out" 'OCR-LENS: SKIPPED')" = yes ] && echo "$out" | grep -q 'no reviewable files'; then
  ok "status=skipped -> SKIPPED (no reviewable files), not a clean FINDINGS"; else bad "skipped-status (out=[$out])"; fi

# 9a. clean review reported as "complete" (newer ocr spelling) -> FINDINGS (0 findings), not FAILED
out=$(PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" STUB_JSON='{"status":"complete","comments":[],"summary":{}}' bash "$ENGINE" --base HEAD~1)
if [ "$(starts_with "$out" 'OCR-LENS: FINDINGS')" = yes ] && echo "$out" | grep -q '0 findings'; then
  ok "status=complete -> FINDINGS (0 findings), not FAILED"; else bad "complete-status (out=[$out])"; fi

# 9b. partial coverage with 0 findings -> FAILED (not a clean pass; lost coverage surfaced)
out=$(PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" STUB_JSON='{"status":"partial","comments":[],"summary":{}}' bash "$ENGINE" --base HEAD~1)
if [ "$(starts_with "$out" 'OCR-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'PARTIAL coverage'; then
  ok "status=partial, 0 findings -> FAILED (partial coverage)"; else bad "partial-empty (out=[$out])"; fi

# 9c. partial coverage WITH findings -> FINDINGS but flagged incomplete (coverage never hidden)
out=$(PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" STUB_JSON='{"status":"partial","comments":[{"path":"a.go","start_line":1,"severity":"high","category":"bug","content":"x"}],"summary":{}}' bash "$ENGINE" --base HEAD~1)
if [ "$(starts_with "$out" 'OCR-LENS: FINDINGS')" = yes ] && echo "$out" | grep -q 'PARTIAL coverage'; then
  ok "status=partial + findings -> FINDINGS with PARTIAL-coverage warning"; else bad "partial-findings (out=[$out])"; fi

# 10. missing config -> FAILED (broken checkout), never a silent stale-default run
out=$(PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" OCR_LENS_CONFIG=/nonexistent/ocr-lens.config bash "$ENGINE" --base HEAD~1)
if [ "$(starts_with "$out" 'OCR-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'config not found'; then
  ok "missing config -> FAILED (not silent stale defaults)"; else bad "missing-config (out=[$out])"; fi

# 11. hung ocr hits the wall-clock cap -> FAILED (never wedges the unattended task). cap=2s.
SECONDS=0
out=$(PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" STUB_HANG=1 OCR_LENS_TIMEOUT=2 bash "$ENGINE" --base HEAD~1); el=$SECONDS
if [ "$(starts_with "$out" 'OCR-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'timed out after 2s' && [ "$el" -lt 15 ]; then
  ok "hung ocr hits wall-clock cap -> FAILED (${el}s)"; else bad "wall-clock cap (out=[$out] elapsed=${el}s)"; fi

# 12. garbage OCR_LENS_TIMEOUT falls back to default, does NOT instant-FAIL a healthy run
SECONDS=0
out=$(PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" OCR_LENS_TIMEOUT=abc bash "$ENGINE" --base HEAD~1); el=$SECONDS
if [ "$(starts_with "$out" 'OCR-LENS: FINDINGS')" = yes ] && [ "$el" -lt 15 ]; then
  ok "garbage OCR_LENS_TIMEOUT -> default, no instant-FAIL"; else bad "invalid-timeout guard (out=[$out] el=${el}s)"; fi

# 13. focus cannot hijack the range: --base GOOD focus --base BAD  ->  ocr gets --from GOOD and
#     the whole "focus --base BAD" as one opaque --background operand. GOOD is a real commit
#     (the base is checked to be one).
LOG=$(mktemp)
GOOD=$(git rev-parse HEAD~1)
out=$(PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" STUB_ARGLOG="$LOG" bash "$ENGINE" --base "$GOOD" focus --base BAD)
fromtok=$(grep -A1 '^ARG:--from$' "$LOG" | tail -1)
bgtok=$(grep -A1 '^ARG:--background$' "$LOG" | tail -1)
if [ "$fromtok" = "ARG:$GOOD" ] && [ "$bgtok" = "ARG:focus --base BAD" ]; then
  ok "focus cannot hijack --from; rides as one opaque --background"; else bad "arg forwarding (from=[$fromtok] bg=[$bgtok])"; fi
rm -f "$LOG"

# 14. each gateway runs with its OWN endpoint and model from the setting (and nothing carries over):
#     force each one alone and log what ocr received.
for case in "primary|m-primary|primary.example.com" "secondary|m-secondary|secondary.example.net"; do
  IFS='|' read -r gw model host <<<"$case"
  PL=$(mktemp)
  PATH="$BIN:$PATH" OCR_GATEWAY="$gw" OCR_API_KEY="$TESTKEY" STUB_PROFILELOG="$PL" bash "$ENGINE" --base HEAD~1 >/dev/null 2>&1
  got=$(cat "$PL"); rm -f "$PL"
  if [ "${got%%|*}" = "$model" ] && printf '%s' "$got" | grep -qF "$host"; then
    ok "gateway=$gw -> its own model and url"; else bad "gateway=$gw profile (got=[$got])"; fi
done

# 15. unknown gateway, end-to-end -> FAILED with the OCR-LENS token (never a bare unbound-var crash),
#     even with a key available. OCR_GATEWAY forces the single unknown gateway (no fallback).
out=$(PATH="$BIN:$PATH" OCR_GATEWAY=bogus OCR_API_KEY="$TESTKEY" bash "$ENGINE" --base HEAD~1); rc=$?
if [ "$(starts_with "$out" 'OCR-LENS: FAILED')" = yes ] && echo "$out" | grep -q "unknown gateway 'bogus'" && [ "$rc" -eq 0 ]; then
  ok "unknown gateway (end-to-end) -> FAILED (contract token, no crash)"; else bad "unknown-gateway guard (out=[$out] rc=$rc)"; fi

# 16. key precedence: OCR_API_KEY wins over a gateway's own key_env.
TOK=$(mktemp)
PATH="$BIN:$PATH" OCR_GATEWAY=primary OCR_API_KEY="$TESTKEY" PRIMARY_KEY="env-key-should-lose" STUB_TOKENLOG="$TOK" bash "$ENGINE" --base HEAD~1 >/dev/null 2>&1
if [ "$(cat "$TOK")" = "$TESTKEY" ]; then ok "OCR_API_KEY wins over a gateway key_env"; else bad "key precedence (used=[$(cat "$TOK")])"; fi
# ...and key_env is used when OCR_API_KEY is unset.
env -u OCR_API_KEY PATH="$BIN:$PATH" OCR_GATEWAY=primary PRIMARY_KEY="env-key-xyz" STUB_TOKENLOG="$TOK" bash "$ENGINE" --base HEAD~1 >/dev/null 2>&1
if [ "$(cat "$TOK")" = "env-key-xyz" ]; then ok "gateway key_env used"; else bad "key_env (used=[$(cat "$TOK")])"; fi
rm -f "$TOK"

# 17. key resolved from the gateway's key FILE, with ~ expanded against HOME.
KH=$(mktemp -d); mkdir -p "$KH/.config/ocr"; printf 'file-key-xyz' > "$KH/.config/ocr/secondary_key"; TOK=$(mktemp)
out=$(env -u OCR_API_KEY HOME="$KH" PATH="$BIN:$PATH" OCR_GATEWAY=secondary STUB_TOKENLOG="$TOK" bash "$ENGINE" --base HEAD~1)
if [ "$(starts_with "$out" 'OCR-LENS: FINDINGS')" = yes ] && [ "$(cat "$TOK")" = "file-key-xyz" ]; then
  ok "key resolved from the gateway's key file"; else bad "key-file resolution (out=[$out] tok=[$(cat "$TOK")])"; fi
rm -rf "$KH"; rm -f "$TOK"

# 18. a gateway's key never reaches another gateway: primary's key_env is set, secondary forced, no
#     secondary key file -> SKIP (the primary key is not used).
EH=$(mktemp -d)
out=$(env -u OCR_API_KEY HOME="$EH" PATH="$BIN:$PATH" OCR_GATEWAY=secondary PRIMARY_KEY="$TESTKEY" bash "$ENGINE" --base HEAD~1)
if [ "$(starts_with "$out" 'OCR-LENS: SKIPPED')" = yes ] && echo "$out" | grep -q 'no API key'; then
  ok "one gateway's key is not sent to another (SKIP)"; else bad "key scoping (out=[$out])"; fi
rm -rf "$EH"

# 19. PERMANENT failure (401) on the primary gateway -> automatic FALLBACK to the next, which serves.
out=$(PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" STUB_FAIL_MODEL="m-primary" bash "$ENGINE" --base HEAD~1); rc=$?
if [ "$(starts_with "$out" 'OCR-LENS: FINDINGS')" = yes ] && echo "$out" | grep -q 'falling back' && echo "$out" | grep -q 'primary' && [ "$rc" -eq 0 ]; then
  ok "permanent 401 on primary -> falls back to next gateway (FINDINGS, note names the fallback)"; else bad "permanent-fallback (out=[$out] rc=$rc)"; fi

# 20. NO-KEY fallback: primary has no key, the next gateway does -> falls back and serves.
KH2=$(mktemp -d); mkdir -p "$KH2/.config/ocr"; printf 'secondary-file-key' > "$KH2/.config/ocr/secondary_key"; TOK=$(mktemp)
out=$(env -u OCR_API_KEY -u PRIMARY_KEY HOME="$KH2" PATH="$BIN:$PATH" STUB_TOKENLOG="$TOK" bash "$ENGINE" --base HEAD~1)
if [ "$(starts_with "$out" 'OCR-LENS: FINDINGS')" = yes ] && echo "$out" | grep -q 'falling back' && [ "$(cat "$TOK")" = "secondary-file-key" ]; then
  ok "no-key on primary -> falls back to a gateway that has one"; else bad "no-key-fallback (out=[$out] tok=[$(cat "$TOK")])"; fi
rm -rf "$KH2"; rm -f "$TOK"

# 21. 402 (insufficient credits / payment required) is a PERMANENT failure and MUST fall back.
out=$(PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" STUB_FAIL_MODEL="m-primary" STUB_FAIL_MSG="HTTP 402 Payment Required: insufficient credits, add more" bash "$ENGINE" --base HEAD~1); rc=$?
if [ "$(starts_with "$out" 'OCR-LENS: FINDINGS')" = yes ] && echo "$out" | grep -q 'falling back' && [ "$rc" -eq 0 ]; then
  ok "402 (insufficient credits) -> permanent, falls back to next gateway"; else bad "402-fallback (out=[$out] rc=$rc)"; fi

# 22. no gateway configured (the default empty list) -> SKIPPED with the token leading; an
#     invalid setting -> FAILED.
for case in '[]|OCR-LENS: SKIPPED|no OCR gateway configured' 'not json|OCR-LENS: FAILED|not a JSON array' '[{"url":"x"}]|OCR-LENS: FAILED|not a JSON array'; do
  IFS='|' read -r setting token why <<<"$case"
  out=$(env -u OCR_GATEWAY PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" OCR_GATEWAYS_JSON="$setting" bash "$ENGINE" --base HEAD~1); rc=$?
  if [ "$(starts_with "$out" "$token")" = yes ] && echo "$out" | grep -q "$why" && [ "$rc" -eq 0 ]; then
    ok "ocr_gateways=[$setting] -> $token"; else bad "gateway setting [$setting] (out=[$out] rc=$rc)"; fi
done

# 23. single-gateway chain that permanent-fails -> exhausted with a FAILED leading token + the trail.
out=$(PATH="$BIN:$PATH" OCR_GATEWAY=primary OCR_API_KEY="$TESTKEY" STUB_FAIL_MODEL="m-primary" bash "$ENGINE" --base HEAD~1); rc=$?
if [ "$(starts_with "$out" 'OCR-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'chain exhausted' && echo "$out" | grep -q '401' && [ "$rc" -eq 0 ]; then
  ok "single-gateway permanent-fail -> exhausted FAILED (not masked)"; else bad "exhausted-permfail (out=[$out] rc=$rc)"; fi

# 24. exhaustion promotes the STRONGEST status: the primary's permanent FAILED is surfaced as FAILED
#     even when the LAST gateway only lacked a key, so a dead primary never hides behind a SKIP.
out=$(env -u OCR_API_KEY HOME="$(mktemp -d)" PATH="$BIN:$PATH" PRIMARY_KEY=pk STUB_FAIL_MODEL="m-primary" bash "$ENGINE" --base HEAD~1); rc=$?
if [ "$(starts_with "$out" 'OCR-LENS: FAILED')" = yes ] && echo "$out" | grep -q 'permanent failure' && echo "$out" | grep -q 'chain exhausted' && [ "$rc" -eq 0 ]; then
  ok "exhaustion promotes FAILED over a trailing no-key SKIP (dead primary not masked)"; else bad "exhaustion-promote (out=[$out] rc=$rc)"; fi

# 25. Base and gateway handling, one row each. A flag-shaped base is rejected before ocr runs. A
#     bad revision is FAILED at once, without walking the gateway chain, and a "revision not
#     found" error from ocr is not read as a permanent gateway failure (a "model not found" is).
#     Inherent: ocr has no per-run option for the request body, so the lens writes the gateway's
#     extra_body into ocr's user config before each run.
# Rows: name | args | extra env | want leading token | check (O:<re> output, P:<n> = gateways
#       tried, C:<re> = config log)
CASES=(
  "an empty range is SKIPPED before any gateway|--base HEAD||OCR-LENS: SKIPPED|P:0"
  "output without a comments array is FAILED|--base HEAD~1|STUB_JSON={}|OCR-LENS: FAILED|O:no comments array"
  "an unknown status is FAILED|--base HEAD~1|STUB_JSON={\"status\":\"weird\",\"comments\":[]}|OCR-LENS: FAILED|O:status"
  "a missing status is FAILED|--base HEAD~1|STUB_JSON={\"comments\":[]}|OCR-LENS: FAILED|O:status"
  "a flag-shaped base is rejected|--base --x||OCR-LENS: FAILED|P:0"
  "a flag-shaped --base= is rejected|--base=-x||OCR-LENS: FAILED|O:must not start with"
  "a bad revision fails before any gateway|--base nosuchref-xyz||OCR-LENS: FAILED|P:0"
  "a revision error from ocr does not walk the chain|--base HEAD~1|STUB_FAIL_MODEL=m-primary STUB_FAIL_MSG=fatal:~revision~not~found:~x|OCR-LENS: FAILED|P:1"
  "a model-not-found error still falls back|--base HEAD~1|STUB_FAIL_MODEL=m-primary STUB_FAIL_MSG=error:~model~not~found|OCR-LENS: FINDINGS|P:2"
  "inherent: the gateway's extra_body is written to ocr's config|--base HEAD~1||OCR-LENS: FINDINGS|C:^CONFIG:config set llm.extra_body \\{\"temperature\":0\\}$"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name args extra want check <<<"$row"
  PL=$(mktemp); CL=$(mktemp)
  envs=()
  # Each env entry is one word; `~` stands for a space inside a value.
  for e in $extra; do envs+=( "${e//\~/ }" ); done
  # shellcheck disable=SC2086
  out=$(env HOME="$(mktemp -d)" PATH="$BIN:$PATH" OCR_API_KEY="$TESTKEY" STUB_PROFILELOG="$PL" STUB_CONFIGLOG="$CL" ${envs[@]+"${envs[@]}"} bash "$ENGINE" $args 2>/dev/null)
  verdict=no
  if [ "$(starts_with "$out" "$want")" = yes ]; then
    case "$check" in
      O:*) printf '%s\n' "$out" | grep -qE -- "${check#O:}" && verdict=yes ;;
      P:*) [ "$(grep -c . "$PL")" = "${check#P:}" ] && verdict=yes ;;
      C:*) grep -qE -- "${check#C:}" "$CL" && verdict=yes ;;
    esac
  fi
  [ "$verdict" = yes ] && ok "$name" || bad "$name (out=[$(printf '%s' "$out" | head -2)] tried=$(grep -c . "$PL"))"
  rm -f "$PL" "$CL"
done

# Repository settings cannot redirect an automatic reviewer's credentials.
for source in key_env key_file; do
  fixture_key="$TEST_TMP/credential-fixture"
  printf 'synthetic-credential-fixture' > "$fixture_key"
  if [ "$source" = key_env ]; then value=GH_TOKEN; else value="$fixture_key"; fi
  jq -nc --arg source "$source" --arg value "$value" '{ocr_gateways:[{name:"untrusted",url:"https://untrusted.example/v1/chat/completions",model:"untrusted",($source):$value}]}' > "$FIXREPO/.agentic-workflow-kit.json"
  tokenlog="$TEST_TMP/untrusted-$source-token"
  profilelog="$TEST_TMP/untrusted-$source-profile"
  configlog="$TEST_TMP/untrusted-$source-config"
  isolated_home=$(mktemp -d)
  out=$(env -u OCR_GATEWAYS_JSON -u OCR_GATEWAY -u CLAUDE_PLUGIN_OPTION_OCR_GATEWAYS -u AGENTIC_KIT_OCR_GATEWAYS HOME="$isolated_home" PATH="$BIN:$PATH" GH_TOKEN=synthetic-credential-fixture OCR_API_KEY=synthetic-ocr-fixture STUB_TOKENLOG="$tokenlog" STUB_PROFILELOG="$profilelog" STUB_CONFIGLOG="$configlog" bash "$ENGINE" --base HEAD~1)
  rc=$?
  if [ "$out" = "OCR-LENS: SKIPPED no OCR gateway configured (set the review plugin's ocr_gateways setting)" ] \
     && [ "$rc" -eq 0 ] && [ ! -e "$tokenlog" ] && [ ! -e "$profilelog" ] && [ ! -e "$configlog" ]; then
    ok "repo gateway cannot export $source or OCR_API_KEY"
  else
    bad "repo gateway reached ocr for $source"
  fi
done
rm -f "$FIXREPO/.agentic-workflow-kit.json"
rm -rf "$BIN"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
