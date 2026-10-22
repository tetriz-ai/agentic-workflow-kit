#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Adversarial fixture for scrub.sh — the credential gate.
#
# A gate is only a gate if a known-bad input makes it fire. This suite feeds
# scrub.sh a real credential of every HARD class and asserts it BLOCKS (exit 1),
# and feeds it a clean artifact and asserts it PASSES (exit 0). Deterministic
# shell, no LLM. scripts/test-all.sh runs it, or run it alone:
# bash scrub.test.sh
#
# The private-key signature starts with `-----`. A bare `grep -nEo "$re"` would parse those
# dashes as grep FLAGS, error, and `|| true` would swallow it, so the artifact would return
# CLEAN. The "private key block" row below is that input; scrub.sh passes each pattern with
# `grep ... -e "$re"`, and the row checks that the key is blocked.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/scrub.sh"
pass=0; fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# run <file> -> echoes the gate's exit code (never aborts this suite)
run() { bash "$GATE" "$1" >/dev/null 2>&1; printf '%s' "$?"; }

# Rows: want (block|allow) | name | artifact content (printf format, so \n is a newline).
# A signature that starts with dashes first.
CASES=(
  "block|private key block, a pattern that starts with dashes|-----BEGIN PRIVATE KEY-----"  # fake private key header, test fixture. gitleaks:allow
  "block|RSA private key header|-----BEGIN RSA PRIVATE KEY-----"  # gitleaks:allow
  "block|AWS access key id|aws_key = AKIAIOSFODNN7EXAMPLE here"  # gitleaks:allow
  "block|GitHub PAT (ghp_)|token ghp_0123456789abcdefghijklmnopqrstuvwxyz"  # gitleaks:allow
  "block|GitHub OAuth token (gho_)|gho_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"  # gitleaks:allow
  "block|GitHub user-to-server token (ghu_)|ghu_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"  # gitleaks:allow
  "block|GitHub server-to-server token (ghs_)|ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"  # gitleaks:allow
  "block|GitHub refresh token (ghr_)|ghr_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"  # gitleaks:allow
  "block|npm token (npm_)|npm_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"  # gitleaks:allow
  "block|Stripe live secret key (sk_live_)|sk_live_ABCDEFGHIJKLMNOPQRSTUVWX"  # gitleaks:allow
  "block|Stripe restricted key (rk_live_)|rk_live_ABCDEFGHIJKLMNOPQRSTUVWX"  # gitleaks:allow
  "block|Anthropic key with hyphens (sk-ant-)|sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"  # gitleaks:allow
  "block|project key with hyphens (sk-proj-)|key: sk-proj-ABCDEFGHIJKL-MNOPQRSTUVWX"  # gitleaks:allow
  "block|Slack token (xoxb)|slack xoxb-1234567890-abcdefABCDEF"  # gitleaks:allow
  "block|bearer token|Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123"  # gitleaks:allow
  "block|DB conn string w/ creds|postgres://user:s3cr3tpass@db.internal:5432/app"  # gitleaks:allow
  "block|GCP service-account JSON|  \"type\": \"service_account\","
  "block|JWT|eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJVadQssw5c"  # fake JWT, test fixture. gitleaks:allow
  "block|GCP api key (AIza)|key=AIzaSyA1234567890abcdefghijklmnopqrstuv"  # fake API key, test fixture. gitleaks:allow
  "block|GitHub fine-grained PAT|github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123"  # gitleaks:allow
  "block|GitLab PAT (glpat-)|glpat-ABCDEFGHIJ0123456789"  # fake access token, test fixture. gitleaks:allow
  "block|generic secret key (sk-)|sk-ABCDEFGHIJKLMNOPQRSTUVWX"  # gitleaks:allow
  "block|Google OAuth access tok|ya29.0AABBCCDDEEFFGGHHIIJJ"  # gitleaks:allow
  "block|Google OAuth refresh tok|1//0AABBCCDDEEFFGGHHIIJJ"  # gitleaks:allow
  "block|hard hit buried in prose|normal abstracted line\nsee https://example.com\n-----BEGIN PRIVATE KEY-----\nmore notes"  # gitleaks:allow
  "block|a key in a file with a NUL byte|bin\\0000data\\ntoken ghp_0123456789abcdefghijklmnopqrstuvwxyz"  # gitleaks:allow
  "block|a key on a line with an invalid UTF-8 byte|token \\377 ghp_0123456789abcdefghijklmnopqrstuvwxyz"  # gitleaks:allow
  "block|a key in Latin-1 text|caf\\351 notes\\ntoken ghp_0123456789abcdefghijklmnopqrstuvwxyz"  # gitleaks:allow
  "allow|fully abstracted artifact|# taste\nUser prefers table-driven tests.\nNo secrets here."
  "allow|soft hits only (email+url)|contact dev@example.com\ndocs at https://example.com/x"
  "allow|near-miss, not a real key|the string AKIA is mentioned but no 16-char key follows"
  "allow|kebab-case word ending in sk-|run the task-breakdown-and-planning-skill-flow first"
  "allow|short gh-prefixed word|use ghp_short and npm_ci in the docs"
)
for row in "${CASES[@]}"; do
  want=${row%%|*}; rest=${row#*|}; name=${rest%%|*}; content=${rest#*|}
  f="$TMP/artifact.md"; printf -- "$content\n" > "$f"
  rc="$(run "$f")"
  if [ "$want" = block ]; then
    if [ "$rc" = "1" ]; then echo "PASS: blocks $name"; pass=$((pass + 1))
    else echo "FAIL: $name NOT blocked (exit $rc, expected 1) — DEAD GATE"; fail=$((fail + 1)); fi
  else
    if [ "$rc" = "0" ]; then echo "PASS: allows $name"; pass=$((pass + 1))
    else echo "FAIL: $name wrongly blocked (exit $rc, expected 0)"; fail=$((fail + 1)); fi
  fi
done

# --- usage contract: missing / absent file is exit 2, not a false clean -----
rc_missing="$(bash "$GATE" 2>/dev/null; printf '%s' "$?")"
[ "$rc_missing" = "2" ] && { echo "PASS: no-arg is usage exit 2"; pass=$((pass+1)); } || { echo "FAIL: no-arg exit $rc_missing (expected 2)"; fail=$((fail+1)); }
rc_nofile="$(bash "$GATE" "$TMP/does-not-exist.md" 2>/dev/null; printf '%s' "$?")"
[ "$rc_nofile" = "2" ] && { echo "PASS: absent file is exit 2"; pass=$((pass+1)); } || { echo "FAIL: absent file exit $rc_nofile (expected 2)"; fail=$((fail+1)); }

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
