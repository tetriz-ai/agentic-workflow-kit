#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# extract-taste / scrub.sh
# ---------------------------------------------------------------------------
# Privacy gate for a taste-collection artifact. Two tiers:
#
#   HARD  — structured credential signatures. A hit BLOCKS the push (exit 1).
#           These are unambiguous secrets; an artifact must never carry them.
#   SOFT  — review aids (emails, internal hostnames, URLs, long blobs). Printed
#           as warnings for the human to eyeball; does NOT block (exit stays 0).
#
# IMPORTANT — what this is NOT: this is a signature matcher, not a completeness
# check. It CANNOT detect customer/client names, ticket text, or free-form PII.
# Those rest entirely on the model abstracting and the human reviewing. Do not
# treat a clean exit as proof the artifact is safe — only that it carries no
# *recognised credential shape*.
#
# Usage: scrub.sh <artifact.md>
# Exit:  0 clean (warnings may have printed) | 1 hard hit (do NOT push) | 2 usage
# gate: blocks an artifact carrying any recognised HARD credential signature.
#       Fixture: scrub.test.sh (block-the-bad + pass-the-good).
# ---------------------------------------------------------------------------
set -uo pipefail

f="${1:-}"
[[ -n "$f" ]] || { echo "usage: scrub.sh <artifact.md>" >&2; exit 2; }
[[ -f "$f" ]] || { echo "scrub: file not found: $f" >&2; exit 2; }

# regex=label — HARD tier (blocks push).
hard=(
  'AKIA[0-9A-Z]{16}=AWS access key id'
  'gh[pousr]_[0-9A-Za-z]{36}=GitHub token (ghp_, gho_, ghu_, ghs_, ghr_)'
  'npm_[0-9A-Za-z]{36}=npm token'
  '[sr]k_(live|test)_[0-9A-Za-z]{16,}=Stripe secret or restricted key'
  'github_pat_[0-9A-Za-z_]{50,}=GitHub fine-grained PAT'
  'glpat-[0-9A-Za-z_-]{20}=GitLab PAT'
  'xox[baprs]-[0-9A-Za-z-]{10,}=Slack token'
  '(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}=secret key (sk-, including sk-ant- and sk-proj-)'
  'AIza[0-9A-Za-z_-]{35}=GCP API key'
  'ya29\.[0-9A-Za-z_-]{20,}=Google OAuth access token'
  '1//[0-9A-Za-z_-]{20,}=Google OAuth refresh token'
  '(Bearer|bearer)[[:space:]]+[A-Za-z0-9._~+/-]{20,}=bearer token'
  '(postgres|postgresql|mysql|mongodb(\+srv)?|redis|amqps?)://[^[:space:]/]*:[^[:space:]/]*@=DB/queue connection string with credentials'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----=private key block'
  '"private_key_id"[[:space:]]*:=GCP service-account JSON'
  '"type"[[:space:]]*:[[:space:]]*"service_account"=GCP service-account JSON'
  'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}=JWT'
)

# regex=label — SOFT tier (warn, do not block).
soft=(
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}=email address'
  '[a-z0-9-]+\.(internal|svc\.cluster\.local|corp|lan|intranet)=internal hostname'
  'https?://[^[:space:])"]+=URL'
)

hard_hits=0
for p in "${hard[@]}"; do
  re="${p%%=*}"; label="${p#*=}"
  m="$(LC_ALL=C grep -naEo -e "$re" "$f" 2>/dev/null | head -5 || true)"
  if [[ -n "$m" ]]; then
    echo "SCRUB HARD HIT ($label):" >&2
    printf '%s\n' "$m" | sed 's/^/  /' >&2
    hard_hits=$((hard_hits + 1))
  fi
done

soft_hits=0
for p in "${soft[@]}"; do
  re="${p%%=*}"; label="${p#*=}"
  m="$(LC_ALL=C grep -naEo -e "$re" "$f" 2>/dev/null | head -5 || true)"
  if [[ -n "$m" ]]; then
    echo "scrub warn ($label) — eyeball, may be benign:" >&2
    printf '%s\n' "$m" | sed 's/^/  /' >&2
    soft_hits=$((soft_hits + 1))
  fi
done

if [[ $hard_hits -gt 0 ]]; then
  echo "scrub: $hard_hits credential class(es) matched — abstract these out, then re-run. Push is BLOCKED." >&2
  exit 1
fi
echo "scrub: clean (no credential signatures; $soft_hits soft warning class(es) — review them, and remember names/PII are NOT machine-checked)"
