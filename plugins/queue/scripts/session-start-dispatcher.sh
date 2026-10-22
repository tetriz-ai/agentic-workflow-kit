#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# SessionStart dispatcher: the queue plugin's single SessionStart hook, with two
# independent jobs:
#
#  1. Surface staged context. Any *.md a handler drops in
#     .claude/triage/session-context/ is concatenated and emitted as SessionStart
#     additionalContext — the ONLY channel that injects text into the session.
#     Handlers run detached with their stdout swallowed, so a handler cannot emit
#     context itself: it writes a file here and the NEXT session's dispatcher
#     surfaces it. Eventually-consistent by one session, and that async property
#     is deliberate — a fresh gh/network pull must never block or slow session
#     start, so it refreshes the cache in the background for next time instead.
#  2. Fan out handlers. Every executable in session-start.d/ runs as a
#     fire-and-forget, detached background job. A new concern is added by
#     dropping an executable there, not by adding another hook entry. These
#     handlers are what refresh the staged context for next time.
#
# Handler contract: best-effort and quick or self-detaching — the dispatcher
# backgrounds it and never waits, so a handler can neither slow down nor fail a
# session. The SessionStart stdin payload is piped to each; handler output is
# swallowed. The dispatcher's OWN stdout carries only the additionalContext JSON.
#
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0

# Repo root: prefer the harness env; else the git toplevel of the cwd (the hook
# runs in the project directory; this script lives in the plugin, not the repo).
ROOT="${CLAUDE_PROJECT_DIR:-}"
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || ROOT=""
# Staging dir override exists so the test can point it at a temp dir.
STAGE="${SESSION_CONTEXT_DIR:-${ROOT:+$ROOT/.claude/triage/session-context}}"

# Capture the payload once so every handler receives it on stdin.
PAYLOAD="$(cat 2>/dev/null || true)"

# 1. Emit staged context. Two channels, because Claude Code renders them
#    differently: a staged `*.md` becomes `additionalContext` (nested, SILENT —
#    model-only context the user never sees), and a staged `*.msg` becomes
#    `systemMessage` (TOP-LEVEL — the line Claude Code renders VISIBLY to the
#    user). A handler that wants the user to actually see a nudge must stage a
#    `.msg`; the `.md` alone is invisible. Needs jq for safe JSON escaping; skip
#    silently if jq is missing so a session is never broken. The byte budget is
#    shared across both channels: both become startup prompt content.
if [ -n "$STAGE" ] && [ -d "$STAGE" ] && command -v jq >/dev/null 2>&1; then
  snapshot_link="$STAGE/ship-queue-nudge-current"
  snapshot=""
  # Resolve the pointer once. A concurrent refresh may change the symlink, but
  # this session continues reading the immutable directory it opened here.
  [ -d "$snapshot_link" ] && snapshot="$(cd "$snapshot_link" 2>/dev/null && pwd -P)"
  md_files=()
  msg_files=()
  for f in "$STAGE"/*.md; do
    [ -f "$f" ] || continue
    md_files+=("$f")
  done
  [ -n "$snapshot" ] && [ -f "$snapshot/context.md" ] && md_files+=("$snapshot/context.md")
  for f in "$STAGE"/*.msg; do
    [ -f "$f" ] || continue
    msg_files+=("$f")
  done
  [ -n "$snapshot" ] && [ -f "$snapshot/message.msg" ] && msg_files+=("$snapshot/message.msg")
  ctx=""
  ctx_bytes=0
  ctx_omitted=0
  ctx_max_bytes="${SESSION_CONTEXT_MAX_BYTES:-8192}"
  case "$ctx_max_bytes" in ''|*[!0-9]*) ctx_max_bytes=8192 ;; esac  # not an integer -> default
  ctx_reserve_bytes=256
  # Reserve retrieval-marker space only when the staged set cannot fit as-is.
  # Otherwise a valid payload close to the configured ceiling must not be
  # suppressed merely for a marker that will never be needed.
  staged_total_bytes=0
  staged_md_count=0
  staged_msg_count=0
  for f in "${md_files[@]:-}"; do
    [ -f "$f" ] || continue
    [ "$staged_md_count" -gt 0 ] && staged_total_bytes=$((staged_total_bytes + 2))
    staged_total_bytes=$((staged_total_bytes + $(wc -c < "$f" | tr -d '[:space:]')))
    staged_md_count=$((staged_md_count + 1))
  done
  for f in "${msg_files[@]:-}"; do
    [ -f "$f" ] || continue
    [ "$staged_msg_count" -gt 0 ] && staged_total_bytes=$((staged_total_bytes + 1))
    staged_total_bytes=$((staged_total_bytes + $(wc -c < "$f" | tr -d '[:space:]')))
    staged_msg_count=$((staged_msg_count + 1))
  done
  ctx_limit_bytes="$ctx_max_bytes"
  [ "$staged_total_bytes" -le "$ctx_max_bytes" ] || ctx_limit_bytes=$((ctx_max_bytes - ctx_reserve_bytes))
  for f in "${md_files[@]:-}"; do
    [ -f "$f" ] || continue
    file_content="$(cat "$f" 2>/dev/null)"
    file_bytes="$(printf '%s' "$file_content" | wc -c | tr -d '[:space:]')"
    separator_bytes=0
    [ -n "$ctx" ] && separator_bytes=2
    if [ $((ctx_bytes + separator_bytes + file_bytes)) -le "$ctx_limit_bytes" ]; then
      [ -n "$ctx" ] && ctx="$ctx"$'\n\n'       # blank line between concerns
      ctx="$ctx$file_content"
      ctx_bytes=$((ctx_bytes + separator_bytes + file_bytes))
    else
      ctx_omitted=$((ctx_omitted + 1))
    fi
  done
  msg=""
  for f in "${msg_files[@]:-}"; do
    [ -f "$f" ] || continue
    file_content="$(cat "$f" 2>/dev/null)"
    file_bytes="$(printf '%s' "$file_content" | wc -c | tr -d '[:space:]')"
    separator_bytes=0
    [ -n "$msg" ] && separator_bytes=1
    if [ $((ctx_bytes + separator_bytes + file_bytes)) -le "$ctx_limit_bytes" ]; then
      [ -n "$msg" ] && msg="$msg"$'\n'
      msg="$msg$file_content"
      ctx_bytes=$((ctx_bytes + separator_bytes + file_bytes))
    else
      ctx_omitted=$((ctx_omitted + 1))
    fi
  done
  if [ "$ctx_omitted" -gt 0 ]; then
    omission="[$ctx_omitted staged context file(s) omitted to respect the ${ctx_max_bytes}-byte session budget. Read ${STAGE} on request.]"
    [ -n "$ctx" ] && ctx="$ctx"$'\n\n'
    ctx="$ctx$omission"
  fi
  if [ -n "$ctx" ] || [ -n "$msg" ]; then
    jq -n --arg ctx "$ctx" --arg msg "$msg" '
      (if $ctx != "" then {hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}} else {} end)
      + (if $msg != "" then {systemMessage:$msg} else {} end)
    ' 2>/dev/null || true
  fi
fi

# 2. Fan out drop-in handlers (detached, output swallowed). They refresh the
#    staged context read above on the next session.
HANDLERS="$DIR/session-start.d"
if [ -d "$HANDLERS" ]; then
  for h in "$HANDLERS"/*; do
    case "$h" in *.test.sh) continue ;; esac   # tests live beside handlers; never run them
    [ -f "$h" ] && [ -x "$h" ] || continue     # require an executable handler (skip READMEs etc.)
    printf '%s' "$PAYLOAD" | "$h" >/dev/null 2>&1 &
  done
fi

exit 0
