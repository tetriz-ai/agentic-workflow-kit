#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -euo pipefail

kit_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# kit_script <plugin> <script>: the path of an agentic-workflow-kit plugin script.
# AGENTIC_KIT_HOME (a clone of the kit) wins; otherwise the newest installed copy of
# the plugin in the Claude Code plugin cache. Prints nothing when none is found, so a
# caller's `-x` check skips the hook.
kit_script() {
  local plugin="$1" script="$2" cand newest=0 found="" m
  if [ -n "${AGENTIC_KIT_HOME:-}" ]; then
    printf '%s' "$AGENTIC_KIT_HOME/plugins/$plugin/scripts/$script"
    return 0
  fi
  for cand in "$HOME"/.claude/plugins/cache/*/"$plugin"/*/scripts/"$script"; do
    [ -f "$cand" ] || continue
    m=$(stat -c %Y "$cand" 2>/dev/null || stat -f %m "$cand" 2>/dev/null || echo 0)
    if [ "$m" -gt "$newest" ]; then newest="$m"; found="$cand"; fi
  done
  printf '%s' "$found"
}

# kit_claim <plugin> <script>: reads the hook payload on stdin. Succeeds when this hook should
# run the script; fails when the kit's Codex plugin, which delivers the same script, has already
# claimed this event (see the plugin's scripts/hook-once.sh), so the script runs once. A kit copy
# without hook-once.sh always runs.
kit_claim() {
  local script wrapper
  script="$(kit_script "$1" "$2")"
  wrapper="$(dirname "$script")/hook-once.sh"
  if [ -z "$script" ] || [ ! -x "$wrapper" ]; then
    cat >/dev/null
    return 0
  fi
  AGENTIC_KIT_HOOK_ONCE=1 "$wrapper" --claim "$2"
}

kit_export_compat_env() {
  local root
  root="$(kit_repo_root)"
  export CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$root}"
  export AGENTIC_KIT_AGENT_RUNTIME="${AGENTIC_KIT_AGENT_RUNTIME:-codex}"
}

kit_read_stdin() {
  cat 2>/dev/null || true
}

kit_debug_hook_payload() {
  local hook_name="$1"
  local payload="$2"
  if [ -z "${AGENTIC_KIT_CODEX_HOOK_DEBUG:-}" ]; then
    return 0
  fi
  local log_dir="${TMPDIR:-/tmp}/agentic-kit-codex-hook-debug"
  mkdir -p "$log_dir" 2>/dev/null || return 0
  {
    printf 'hook=%s\n' "$hook_name"
    printf 'cwd=%s\n' "$(pwd)"
    printf 'payload=%s\n' "$payload"
  } >>"$log_dir/${hook_name}.log" 2>/dev/null || true
}

kit_command_from_payload() {
  local payload="$1"
  printf '%s' "$payload" | jq -r '.tool_input.command // .input.command // .command // empty' 2>/dev/null || true
}

# Normalizes delegated advisory hooks: many Claude hooks may emit additional
# context, but Codex accepts one JSON envelope per hook invocation.
kit_merge_hook_outputs() {
  local event_name="$1"
  python3 -c '
import json
import sys

event_name = sys.argv[1]
raw = sys.stdin.read()
decoder = json.JSONDecoder()
contexts = []
system_messages = []
idx = 0

while idx < len(raw):
    start = raw.find("{", idx)
    if start == -1:
        break
    try:
        obj, end = decoder.raw_decode(raw[start:])
    except json.JSONDecodeError:
        idx = start + 1
        continue
    idx = start + end
    if not isinstance(obj, dict):
        continue
    system_message = obj.get("systemMessage")
    if isinstance(system_message, str) and system_message:
        system_messages.append(system_message)
    hook_specific = obj.get("hookSpecificOutput")
    if not isinstance(hook_specific, dict):
        continue
    context = hook_specific.get("additionalContext")
    if isinstance(context, str) and context:
        contexts.append(context)

if contexts or system_messages:
    output = {
        "hookSpecificOutput": {
            "hookEventName": event_name,
        },
    }
    if contexts:
        output["hookSpecificOutput"]["additionalContext"] = "\n\n".join(contexts)
    if system_messages:
        output["systemMessage"] = "\n\n".join(system_messages)
    print(json.dumps(output, separators=(",", ":")))
' "$event_name"
}

kit_edit_payloads_from_payload() {
  local payload="$1"
  local path content command
  path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .input.file_path // .file_path // empty' 2>/dev/null || true)"
  content="$(printf '%s' "$payload" | jq -r '.tool_input.new_string // .tool_input.content // .input.new_string // .input.content // .content // empty' 2>/dev/null || true)"

  if [ -n "$path" ]; then
    jq -nc --arg file_path "$path" --arg content "$content" \
      '{hook_event_name:"PostToolUse",tool_input:{file_path:$file_path,content:$content}}'
    return 0
  fi

  command="$(kit_command_from_payload "$payload")"
  if [ -z "$command" ]; then
    printf '%s\n' "$payload"
    return 0
  fi

  printf '%s' "$command" | python3 -c '
import json
import sys

files = {}
current = None

def note_file(path, deleted=False):
    global current
    if not path or path == "/dev/null":
        current = None
        return
    files.setdefault(path, [])
    current = None if deleted else path

for line in sys.stdin.read().splitlines():
    if line.startswith("*** Add File: "):
        note_file(line.removeprefix("*** Add File: "))
        continue
    if line.startswith("*** Update File: "):
        note_file(line.removeprefix("*** Update File: "))
        continue
    if line.startswith("*** Delete File: "):
        note_file(line.removeprefix("*** Delete File: "), deleted=True)
        continue
    if line.startswith("+++ b/"):
        note_file(line.removeprefix("+++ b/"))
        continue
    if line == "+++ /dev/null":
        current = None
        continue
    if current and line.startswith("+") and not line.startswith("+++"):
        files[current].append(line[1:])

for path, added in files.items():
    print(json.dumps({
        "hook_event_name": "PostToolUse",
        "tool_input": {
            "file_path": path,
            "content": "\n".join(added),
        },
    }, separators=(",", ":")))
'
}
