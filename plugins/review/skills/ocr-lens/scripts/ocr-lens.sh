#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# ocr-lens.sh — the 0-token engine for the /review:ocr-lens skill and review-panel
# Step 2.6's OCR cross-model lens, the sibling of codex-lens.sh. Runs open-code-review
# (`ocr`) pointed at an ordered CHAIN of OpenAI-compatible gateways over the committed
# BASE..HEAD range, and prints one leading status token so the caller reads a verdict. The
# lens falls back along the chain when a gateway cannot serve, so switching gateways or
# models needs no change to this script or the panel.
#
# Why a different MODEL is the point: the automatic Codex/Claude counterpart and this lens use
# lineages distinct from the active-runtime panel, so each catches blind spots the others miss.
# Why `ocr` and not a raw API call: ocr is an agentic reviewer. It reads full files and
# searches the repo for context (not just the diff), and it is deterministic where it must be
# (file selection, positioning), which a one-shot prompt is not.
#
# The gateways are the review plugin's ocr_gateways setting: a JSON array, in fallback order,
# passed by the skill as OCR_GATEWAYS_JSON and resolved through kit-config.sh. Each entry:
#   {"name": "primary",                        a label for messages and OCR_GATEWAY
#    "url": "https://host/v1/chat/completions", the OpenAI-compatible endpoint
#    "model": "model-id",                       must make native tool calls
#    "key_env": "MY_GATEWAY_KEY",               optional: env var holding the key
#    "key_file": "~/.config/ocr/primary_key",   optional: file holding the key
#    "extra_body": {"temperature": 0}}         optional request body merged by ocr
# OCR_API_KEY, when set, is used for every gateway. The caps (tool rounds, token budget,
# wall-clock) are in ../ocr-lens.config. The load-bearing setting, learned by debugging:
#   - llm.extra_body carries the gateway's body that turns reasoning output off or excludes it;
#     without it the reasoning stream can stall the agentic tool loop. It is written to the ocr
#     user config each run (ocr reads no env var for it). The per-review bounds are
#     OCR_LENS_TOKEN_BUDGET + OCR_LENS_TIMEOUT (ocr's --max-tools can only RAISE its default).
#
# Classification (mirrors codex-lens.sh — same contract, so both fold into the panel the same):
#   FINDINGS — the review completed; graded findings (or an explicit 0-findings note) follow.
#   SKIPPED  — `ocr` is not installed, no gateway is configured, no API key for any gateway in
#              the chain is available, OR the
#              diff selected no reviewable files (every changed file excluded by ocr's own filter). The
#              proof is printed. The first two are structural and unspoofable; the third is content-
#              determined, but all three mean the engine contributed no review — never a clean pass.
#   FAILED   — any other non-zero exit (bad --base, network/crash), a missing config, a permanent
#              gateway failure with no fallback left, OR a self-imposed wall-clock timeout. No verdict;
#              the (key-redacted) output is printed. NOT a skip — never treat it as a clean pass.
# Exits 0 on every self-determined outcome (soft lens: never blocks the panel or the gate); it
# propagates 143/130 only when the CALLER signals TERM/INT.
#
# Usage: ocr-lens.sh --base <ref> [focus text ...]
#   --base <ref>   REQUIRED, must precede any focus text. Reviews committed BASE..HEAD (run
#                  once the reviewed work is committed). Use Step 1's BASE.
#   focus text     OPTIONAL. Extra targeting, passed to ocr as review background context.
set -u

BASE=""
FOCUS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;   # 2nd shift only if the operand is present (a bare trailing --base must not hang)
    --base=*) BASE="${1#--base=}"; shift ;;
    *) FOCUS="$*"; break ;;   # first positional -> the rest is opaque focus, so a --base inside it cannot hijack the range
  esac
done

if [ -z "$BASE" ]; then
  echo "OCR-LENS: FAILED --base <ref> is required (reviews committed BASE..HEAD)"
  exit 0
fi
case "$BASE" in
  -*) echo "OCR-LENS: FAILED --base must not start with '-' (got '$BASE'); pass a ref"; exit 0 ;;
esac
# A bad revision is the caller's error, not a gateway's: fail once here rather than let ocr's
# "revision not found" walk the whole gateway chain.
if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
  echo "OCR-LENS: FAILED --base '$BASE' is not a commit in this repository (bad --base?)"
  exit 0
fi
# An empty range has nothing to review: SKIPPED, never a clean FINDINGS.
if [ "$(git rev-list --count "$BASE..HEAD" 2>/dev/null)" = 0 ]; then
  echo "OCR-LENS: SKIPPED empty range: no commits in $BASE..HEAD (nothing committed to review; not a clean review)"
  exit 0
fi

# Skip 1: ocr not installed. Structural — the proof (both resolvers) is printed alongside.
# Resolve robustly: PATH first, then npm's global bin. `npm install -g` lands ocr in the active
# node's versioned bin (~/.nvm/versions/node/<ver>/bin under nvm), which is not always on the
# minimal PATH a tool harness runs with even though `npm` itself is — so `command -v ocr` can miss
# a correctly-installed ocr. `npm prefix -g`/bin is where npm actually put it, independent of node
# version or PATH exposure, with no manual symlink (a version-pinned symlink would dangle on the
# next `nvm install`).
OCR="$(command -v ocr 2>/dev/null || true)"
if [ -z "$OCR" ]; then
  npm_prefix="$(npm prefix -g 2>/dev/null || true)"
  [ -n "$npm_prefix" ] && [ -x "$npm_prefix/bin/ocr" ] && OCR="$npm_prefix/bin/ocr"
fi
if [ -z "$OCR" ]; then
  # $npm_prefix is already set here: this branch is reached only after the block above ran (OCR empty).
  echo "OCR-LENS: SKIPPED ocr unavailable (not installed): not on PATH, and not at npm global bin ('${npm_prefix:-<no npm>}/bin/ocr')"
  exit 0
fi

# Load the caps. A missing config is a broken install, not a skip: fail loudly rather than run
# with silent inline defaults.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${OCR_LENS_CONFIG:-$SCRIPT_DIR/../ocr-lens.config}"
if [ ! -r "$CONFIG" ]; then
  echo "OCR-LENS: FAILED config not found at $CONFIG (broken install?)"
  exit 0
fi
# shellcheck disable=SC1090
. "$CONFIG"
if ! command -v jq >/dev/null 2>&1; then
  echo "OCR-LENS: FAILED jq is required to read the ocr_gateways setting"
  exit 0
fi
KIT_CONFIG="$SCRIPT_DIR/../../../scripts/kit-config.sh"
if [ ! -r "$KIT_CONFIG" ]; then
  echo "OCR-LENS: FAILED settings resolver not found at $KIT_CONFIG"
  exit 0
fi
# shellcheck source=../../../scripts/kit-config.sh
. "$KIT_CONFIG"
GATEWAYS_JSON="$(kit_config ocr_gateways "${OCR_GATEWAYS_JSON:-}")"
: "${GATEWAYS_JSON:=[]}"
if ! printf '%s' "$GATEWAYS_JSON" | jq -e 'type == "array" and all(.[]; type == "object" and (.name | type) == "string" and .name != "")' >/dev/null 2>&1; then
  echo "OCR-LENS: FAILED the ocr_gateways setting is not a JSON array of objects with a name (got: $(printf '%s' "$GATEWAYS_JSON" | head -c 200))"
  exit 0
fi

# _ocr_load_gateway_profile <name>: set this gateway's endpoint, model, key env, key file and
# extra body from the setting. Hard-sets every value, so nothing carries over from the gateway
# tried before it. Returns non-zero for a name that is not in the setting.
_ocr_load_gateway_profile() {
  local gw="$1" entry
  entry="$(printf '%s' "$GATEWAYS_JSON" | jq -c --arg n "$gw" 'map(select(.name == $n)) | first // empty')"
  [ -n "$entry" ] || return 1
  OCR_LLM_URL="$(printf '%s' "$entry" | jq -r '.url // ""')"
  OCR_LLM_MODEL="$(printf '%s' "$entry" | jq -r '.model // ""')"
  OCR_LLM_KEY_ENV="$(printf '%s' "$entry" | jq -r '.key_env // ""')"
  OCR_LLM_KEY_FILE="$(printf '%s' "$entry" | jq -r '.key_file // ""')"
  case "$OCR_LLM_KEY_FILE" in \~/*) OCR_LLM_KEY_FILE="$HOME/${OCR_LLM_KEY_FILE#\~/}" ;; esac
  OCR_LENS_EXTRA_BODY="$(printf '%s' "$entry" | jq -c '.extra_body // {}')"
}

# --- Gateway chain with automatic fallback ---
# OCR_GATEWAY (singular), if set, FORCES one gateway by name with no fallback (a single-gateway
# trial); otherwise walk the setting's gateways in order. On a gateway that CANNOT serve — no key,
# or a PERMANENT API failure (401/403 auth, 402 insufficient credits, 404/model not found,
# 429/quota) — fall back to the next gateway. TERMINAL outcomes (findings, clean,
# no-reviewable-files, partial coverage, unparseable) and TRANSIENT failures (timeout, network) do
# NOT fall back; they are surfaced as this gateway's real verdict.
if [ -n "${OCR_GATEWAY:-}" ]; then
  CHAIN="$OCR_GATEWAY"
else
  CHAIN="$(printf '%s' "$GATEWAYS_JSON" | jq -r '.[].name' | tr '\n' ' ')"
fi
# Reject empty AND whitespace-only: the latter word-splits to ZERO loop iterations, which would
# leave VERDICT unset and print a blank first line, defeating the caller's leading-token check.
# shellcheck disable=SC2086
set -- $CHAIN
if [ "$#" -eq 0 ]; then
  echo "OCR-LENS: SKIPPED no OCR gateway configured (set the review plugin's ocr_gateways setting)"
  exit 0
fi

# A PERMANENT, gateway-specific failure in ocr's (already key-redacted) output — the class where
# retrying the SAME gateway is futile but ANOTHER may serve. Deliberately broad, because ocr's exact
# error text is provider-dependent: HTTP 401/402/403/404/429 plus the common auth / billing / quota /
# model-not-found phrasings ("not found" only next to model, endpoint or deployment, so ocr's own
# "revision not found" is not read as a gateway failure). 402 and the credit/payment terms matter for a gateway that returns
# "402 Payment Required / insufficient credits" when a free or prepaid allowance is used up: a
# permanent failure that MUST fall back, not read as transient and strand the dead primary. Tune the
# alternation here if a gateway surfaces a permanent failure this misses (erring toward fallback is
# safe: the chain still ends in FAILED if every gateway is genuinely down).
is_permanent_failure() {
  printf '%s' "$1" | grep -Eqi '(^|[^0-9])(401|402|403|404|429)([^0-9]|$)|unauthor|forbidden|invalid[^a-z]*(api[^a-z]*)?key|authenticat|(model|endpoint|deployment)[^a-z]*not[- ]?found|not[- ]?found[^a-z]*(model|endpoint|deployment)|no such model|quota|rate[- ]?limit|insufficient|credit|payment[- ]?required|billing'
}

# Redact a gateway's key before printing any ocr output (defence in depth: ocr should never echo the
# token, but a verbose auth error must not leak it). The *literal* $KEY scrub is format-independent (it
# holds whatever the active gateway's key looks like); the belt covers the common `sk-` key prefix.
# $KEY is attempt_gateway's local, visible here via bash dynamic scope. The `${1//"$KEY"/…}`
# substitution is literal (quoting $KEY disables globbing), so it needs no regex escaping.
redact() { local s="${1//"$KEY"/[REDACTED-KEY]}"; printf '%s' "$s" | sed -E 's/sk-[A-Za-z0-9._-]{20,}/[REDACTED-KEY]/g'; }

VERDICT=""     # set by attempt_gateway — the text to print
FELL_OVER=""   # trail of gateways that fell back, for the final note

# attempt_gateway <gw>: load the profile, resolve the key, run ocr, classify. Sets VERDICT.
# Returns 0 = TERMINAL (print VERDICT, stop the chain); 1 = FALL BACK (try the next gateway).
attempt_gateway() {
  local gw="$1" KEY KEY_FILE cout cerr out err timedout cap rc findings body cpid wpid argv
  if ! _ocr_load_gateway_profile "$gw"; then
    VERDICT="OCR-LENS: FAILED unknown gateway '$gw' (not in the ocr_gateways setting)"
    return 1
  fi

  # Key resolution (per gateway): OCR_API_KEY for every gateway, else this gateway's own key_env,
  # else its own key_file. A gateway's key never reaches another gateway's endpoint.
  KEY="${OCR_API_KEY:-}"
  if [ -z "$KEY" ] && [ -n "$OCR_LLM_KEY_ENV" ]; then KEY="${!OCR_LLM_KEY_ENV:-}"; fi
  KEY_FILE="$OCR_LLM_KEY_FILE"
  if [ -z "$KEY" ] && [ -n "$KEY_FILE" ] && [ -r "$KEY_FILE" ]; then KEY="$(cat "$KEY_FILE" 2>/dev/null)"; fi
  if [ -z "$KEY" ]; then
    VERDICT="OCR-LENS: SKIPPED no API key for gateway '$gw' (set ${OCR_LLM_KEY_ENV:-its key_env}, put the key in ${KEY_FILE:-its key_file}, or set OCR_API_KEY)"
    return 1   # fall back — another gateway may have a key
  fi

  # Provider — ocr reads these from the environment.
  export OCR_NO_UPDATE=1
  export OCR_LLM_URL OCR_LLM_MODEL OCR_USE_ANTHROPIC
  export OCR_LLM_TOKEN="$KEY"
  # The gateway's extra body (see the header). Idempotent; a failure here is non-fatal: the run just
  # risks the reasoning stall, which the wall-clock cap below still contains.
  "$OCR" config set llm.extra_body "$OCR_LENS_EXTRA_BODY" >/dev/null 2>&1 || true

  # Run ocr in the BACKGROUND and `wait` on it (not foreground) so a hung run can be interrupted two
  # ways: a caller's TERM/INT and the self-imposed watchdog. stdout (the JSON) and stderr are kept
  # separate so stray progress can never corrupt the JSON we parse.
  cout=$(mktemp); cerr=$(mktemp)
  argv=( review --from "$BASE" --to HEAD --format json --audience agent --max-tools "$OCR_LENS_MAX_TOOLS" --max-tokens-budget "$OCR_LENS_TOKEN_BUDGET" )
  [ -n "$FOCUS" ] && argv+=( --background "$FOCUS" )
  "$OCR" "${argv[@]}" >"$cout" 2>"$cerr" &
  cpid=$!; wpid=""
  # Clean temp files + kill children on a caller signal, then propagate it (whole-script exit).
  trap 'kill "$cpid" "${wpid:-}" 2>/dev/null; rm -f "$cout" "$cerr" "$cout.timedout"; exit 143' TERM
  trap 'kill "$cpid" "${wpid:-}" 2>/dev/null; rm -f "$cout" "$cerr" "$cout.timedout"; exit 130' INT

  # Self-imposed wall-clock cap. The documented invocation is an unattended background task that
  # nothing signals, so a wedged ocr (a dead endpoint, a runaway agent loop) would `wait` forever.
  # Polls (not one long sleep) so it self-exits the instant ocr finishes.
  cap="${OCR_LENS_TIMEOUT:-900}"
  case "$cap" in ''|*[!0-9]*) cap=900 ;; esac    # non-integer/empty -> default (else `[ -lt ]` errors -> instant FAIL)
  [ "${#cap}" -gt 8 ] && cap=900                  # >8 digits overflows int64 -> clamp by LENGTH before any numeric compare
  [ "$cap" -lt 1 ] && cap=900                     # 0 -> default
  ( waited=0
    while [ "$waited" -lt "$cap" ]; do
      kill -0 "$cpid" 2>/dev/null || exit 0     # ocr finished -> nothing to cap
      sleep 1; waited=$((waited + 1))
    done
    kill -0 "$cpid" 2>/dev/null || exit 0       # finished during the final sleep -> don't mislabel/kill
    : >"$cout.timedout"                          # marker: written only past the liveness re-check
    kill "$cpid" 2>/dev/null                     # TERM the wedged run
    grace=0                                      # escalate to SIGKILL only if it survives a short grace
    while [ "$grace" -lt 3 ]; do
      kill -0 "$cpid" 2>/dev/null || exit 0
      sleep 1; grace=$((grace + 1))
    done
    kill -9 "$cpid" 2>/dev/null ) &
  wpid=$!
  wait "$cpid" 2>/dev/null; rc=$?
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null   # stop the watchdog if the run won the race
  trap - TERM INT
  out=$(cat "$cout" 2>/dev/null); err=$(cat "$cerr" 2>/dev/null)
  timedout=""; [ -f "$cout.timedout" ] && timedout=1
  rm -f "$cout" "$cerr" "$cout.timedout"

  if [ -n "$timedout" ]; then
    VERDICT="$(printf 'OCR-LENS: FAILED (non-blocking, investigate — not a clean verdict): gateway %s timed out after %ss (OCR_LENS_TIMEOUT); partial output follows:\n%s' "$gw" "$cap" "$(redact "$out$err")")"
    return 0   # transient -> terminal (do NOT fall back)
  fi
  if [ "$rc" -ne 0 ]; then
    body="$(redact "$out$err")"
    if is_permanent_failure "$body"; then
      VERDICT="$(printf 'OCR-LENS: FAILED (permanent gateway failure on %s — falling back) ocr exit %s:\n%s' "$gw" "$rc" "$body")"
      return 1   # permanent -> fall back
    fi
    VERDICT="$(printf 'OCR-LENS: FAILED (non-blocking, investigate — not a clean verdict): gateway %s ocr exit %s:\n%s' "$gw" "$rc" "$body")"
    return 0   # transient/unknown -> terminal
  fi

  # Parse ocr's JSON into graded prose. ocr itself runs on node, so node is present; if it is somehow
  # absent, degrade to FAILED (never silently pass). The parser emits sentinels the case below turns into a verdict.
  findings=$(printf '%s' "$out" | node -e '
let s=""; process.stdin.on("data",d=>s+=d); process.stdin.on("end",()=>{
  let d; try { d=JSON.parse(s); } catch(e){ process.stdout.write("PARSE_ERROR"); return; }
  // ocr terminal state: clean is "complete" (older builds emit "success"); "partial" = the run did
  // not cover all selected files (token budget hit / file failures); "skipped" = no reviewable
  // files. Top-level status mirrors manifest.terminal_state — read whichever is present, and accept
  // BOTH clean spellings so a pinned-version bump cannot turn a clean review into a false FAILED.
  // Output without a comments array or a known status is not a review: FAILED.
  const status = String(d.status || (d.manifest && d.manifest.terminal_state) || "");
  if (!Array.isArray(d.comments) || !["success", "complete", "partial", "skipped"].includes(status)) {
    process.stdout.write("SHAPE:" + (Array.isArray(d.comments) ? "status \"" + status + "\"" : "no comments array")); return;
  }
  const c = d.comments;
  const clean = status === "success" || status === "complete";
  const partial = status === "partial";
  if (c.length === 0) {
    process.stdout.write(status === "skipped" ? "STATUS:skipped"
                       : partial             ? "STATUS:partial"
                       : clean               ? "NONE"
                       :                       "STATUS:" + status);
    return;
  }
  const rank = {critical:0, high:1, medium:2, low:3};
  c.sort((a,b)=>(rank[a.severity] ?? 9) - (rank[b.severity] ?? 9));
  const body = c.map(x => {
    const end = (x.end_line && x.end_line !== x.start_line) ? "-" + x.end_line : "";
    const loc = (x.path || x.file || "?") + ":" + (x.start_line || x.line || "?") + end;
    let t = "- [" + String(x.severity || "?").toUpperCase() + "] " + loc + " (" + (x.category || "review") + ")\n  "
          + String(x.content || x.message || "").replace(/\n/g, "\n  ");
    if (x.suggestion_code) t += "\n  suggested fix:\n  ```\n  " + String(x.suggestion_code).replace(/\n/g, "\n  ") + "\n  ```";
    return t;
  }).join("\n\n");
  const su = d.summary || {};
  // A partial run WITH findings must not read as a normal clean completion — flag the lost coverage
  // inline so the panel/author sees some files went unreviewed, rather than silently under-covering.
  const warn = partial ? "⚠ PARTIAL coverage: ocr did not review all selected files (token budget hit or file failures) — findings below are incomplete; raise OCR_LENS_TOKEN_BUDGET or investigate.\n\n" : "";
  process.stdout.write(warn + "(" + c.length + " findings across " + (su.files_reviewed ?? "?") + " files, "
    + (su.total_tokens ?? "?") + " tokens, " + (su.elapsed ?? "?") + ")\n\n" + body);
});
' 2>/dev/null)

  case "$findings" in
    ""|PARSE_ERROR)
      VERDICT="$(printf 'OCR-LENS: FAILED (non-blocking, investigate — not a clean verdict): gateway %s unparseable ocr output:\n%s' "$gw" "$(redact "$out$err")")"; return 0 ;;
    SHAPE:*)
      VERDICT="$(printf 'OCR-LENS: FAILED (non-blocking, investigate — not a clean verdict): gateway %s ocr output is not a review (%s):\n%s' "$gw" "${findings#SHAPE:}" "$(redact "$out$err")")"; return 0 ;;
    STATUS:skipped)
      # ocr ran but selected no files — emit SKIPPED, never FINDINGS: a bare "0 findings" here would
      # read as a clean cross-model pass when in fact nothing was looked at. Diff-determined (same for
      # every gateway), so it is TERMINAL — do not fall back.
      VERDICT="OCR-LENS: SKIPPED no reviewable files in BASE..HEAD (every changed file excluded by ocr's filter — unsupported ext, all-deleted, or a non-re-included path; not a clean review)"; return 0 ;;
    STATUS:partial)
      VERDICT="$(printf 'OCR-LENS: FAILED (non-blocking, investigate — not a clean verdict): gateway %s reported PARTIAL coverage with 0 findings (token budget hit or file failures) — some files went unreviewed:\n%s' "$gw" "$(redact "$out$err")")"; return 0 ;;
    STATUS:*)
      VERDICT="$(printf 'OCR-LENS: FAILED (non-blocking, investigate — not a clean verdict): gateway %s ocr status "%s":\n%s' "$gw" "${findings#STATUS:}" "$(redact "$out$err")")"; return 0 ;;
    NONE)
      VERDICT="OCR-LENS: FINDINGS (0 findings — clean review by ${OCR_LLM_MODEL} via ${gw})"; return 0 ;;
    *)
      VERDICT="$(printf 'OCR-LENS: FINDINGS\n%s' "$findings")"; return 0 ;;
  esac
}

# Walk the chain — the first gateway that serves a TERMINAL verdict wins; the rest are fallen back through.
ANY_FAILED=""   # did ANY gateway permanent-FAIL (vs merely lack a key)? decides the exhausted leading token
# shellcheck disable=SC2086  # CHAIN is a space-separated gateway list; word-splitting is intended.
for gw in $CHAIN; do
  if attempt_gateway "$gw"; then
    printf '%s\n' "$VERDICT"
    [ -n "$FELL_OVER" ] && printf '(note: gateway "%s" served this after falling back through — %s)\n' "$gw" "$FELL_OVER"
    exit 0
  fi
  case "$VERDICT" in "OCR-LENS: FAILED"*) ANY_FAILED=1 ;; esac
  FELL_OVER="${FELL_OVER}${gw} [$(printf '%s' "$VERDICT" | head -1 | sed 's/^OCR-LENS: //')]; "
done

# Every gateway in the chain fell back. Lead with the STRONGEST status seen (FAILED > SKIPPED): if any
# gateway permanently FAILED, surface FAILED for investigation even when the LAST gateway only lacked a
# key — otherwise a dead shared primary (bad key / retired model) would be masked as a benign SKIPPED
# (which the panel reads as "no action"). The FELL_OVER trail carries each gateway's own reason.
if [ -n "$ANY_FAILED" ]; then
  case "$VERDICT" in
    "OCR-LENS: FAILED"*) printf '%s\n' "$VERDICT" ;;
    *) printf 'OCR-LENS: FAILED gateway chain exhausted with a permanent failure (see trail); last gateway also could not serve:\n%s\n' "$VERDICT" ;;
  esac
else
  printf '%s\n' "$VERDICT"
fi
printf '(gateway chain exhausted — fell back through: %s)\n' "$FELL_OVER"
exit 0
