#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for check-identifiers.sh: each rule fails on a planted hit, look-alikes pass, a
# `gitleaks:allow` fixture line passes, and the kit itself is clean.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/check-identifiers.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Rows: name | want exit | file content (printf %b) | output must contain (- = nothing)
CASES=(
  "a macOS home path fails|1|cd /Users/alice/src/app\n|home-path"
  "a Linux home path fails|1|see /home/bob/.config\n|home-path"
  "a Go workspace path fails|1|cd ~/go/src/github.com/x/y\n|home-path"
  "an .internal host fails|1|curl https://db.internal:5432/x\n|private-host"
  "a .corp host fails|1|ssh build.corp\n|private-host"
  "a .local host in a URL fails|1|open http://wiki.local/page\n|private-host"
  "a monorepo path fails|1|run dev/agent-harness/sync.sh\n|monorepo-path"
  "a chat session link fails|1|see https://claude.ai/code/session_x\n|chat-link"
  "a hit names its file and line|1|ok\ncd /Users/alice/x\n|doc.md:2:"
  "a settings.local.json file name passes|0|.claude/settings.local.json and .env.local\n|-"
  "a home folder under a temp dir passes|0|\$DIR/home/.claude/settings.json\n|-"
  "the kit's bridge path passes|0|bridge/agent-harness/sync-codex-harness.sh\n|-"
  "a gitleaks:allow fixture line passes|0|postgres://u:p@db.internal:5432/app  # gitleaks:allow\n|-"
  "a clean file passes|0|nothing to see here\n|identifiers: no"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name want content expect <<< "$row"
  rm -rf "$TMP/kit"; mkdir -p "$TMP/kit"; printf '%b' "$content" > "$TMP/kit/doc.md"
  out="$(bash "$SUT" "$TMP/kit" 2>&1)"; rc=$?
  if [ "$rc" != "$want" ]; then bad "$name (exit $rc, want $want): $out"; continue; fi
  if [ "$expect" != "-" ] && ! printf '%s' "$out" | grep -qF "$expect"; then bad "$name: output lacks [$expect]: $out"; continue; fi
  ok "$name"
done

out="$(bash "$SUT" "$HERE/.." 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "the kit has no machine- or organisation-specific identifier" || bad "the kit has hits: $out"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
