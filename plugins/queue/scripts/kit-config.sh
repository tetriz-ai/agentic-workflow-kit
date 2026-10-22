#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# kit-config.sh: resolve one agentic-workflow-kit setting.
#
# Every plugin carries a byte-identical copy at scripts/kit-config.sh (shared/kit-config.sh is
# the source; scripts/sync-shared.sh copies it and CI fails on drift). A plugin is installed into
# its own folder, so a script can only reach files inside its own plugin.
#
# Resolution order for setting <key> (snake_case, as declared in the plugin's userConfig):
#   1. an explicit value passed by the caller, unless it is empty or a literal, unsubstituted
#      "${user_config.<key>}" placeholder (a runtime that does not substitute leaves it as is);
#   2. CLAUDE_PLUGIN_OPTION_<KEY>   (Claude Code exports plugin options to hook processes);
#   3. AGENTIC_KIT_<KEY>            (for runtimes and shells without plugin options);
#   4. the key in .agentic-workflow-kit.json at the repo root (a flat JSON object);
#   5. the default declared for <key> in this plugin's .claude-plugin/plugin.json.
# ocr_gateways skips the repo file: credential destinations require user-controlled settings.
# The first non-empty value wins. An empty value at every step resolves to "".
#
# Use as a library:   . "$dir/kit-config.sh"; base=$(kit_config base_branch)
#                     base=$(kit_config base_branch "$value_from_skill")
# Use as a command:   kit-config.sh get <key> [explicit-value]
# Exit status of the command: 0 resolved (possibly to ""), 2 usage error or an invalid key.

_kit_config_dir() { (cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); }

# Prints the plugin manifest path for the plugin this copy lives in (scripts/ -> plugin root).
_kit_config_manifest() {
  printf '%s/.claude-plugin/plugin.json' "$(cd "$(_kit_config_dir)/.." && pwd)"
}

# kit_config <key> [explicit]: prints the resolved value; returns 2 on an invalid key.
kit_config() {
  local key="${1:-}" explicit="${2:-}" upper val root file manifest
  case "$key" in
    ''|*[!a-z0-9_]*) echo "kit-config: invalid key '$key' (want snake_case)" >&2; return 2 ;;
  esac
  upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')

  case "$explicit" in
    "\${user_config."*"}") explicit="" ;;
  esac
  if [ -n "$explicit" ]; then printf '%s' "$explicit"; return 0; fi

  local var
  for var in "CLAUDE_PLUGIN_OPTION_${upper}" "AGENTIC_KIT_${upper}"; do
    val="${!var:-}"
    if [ -n "$val" ]; then printf '%s' "$val"; return 0; fi
  done

  if command -v jq >/dev/null 2>&1; then
    root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    file="${root:-.}/.agentic-workflow-kit.json"
    if [ "$key" != ocr_gateways ] && [ -f "$file" ]; then
      jq empty "$file" >/dev/null 2>&1 || echo "kit-config: $file is not valid JSON; its settings are ignored (fix the file)" >&2
      val=$(jq -r --arg k "$key" 'if type == "object" and has($k) then .[$k] else null end | if . == null then empty elif type == "string" then . else tojson end' "$file" 2>/dev/null || true)
      if [ -n "$val" ]; then printf '%s' "$val"; return 0; fi
    fi
    manifest=$(_kit_config_manifest)
    if [ -f "$manifest" ]; then
      val=$(jq -r --arg k "$key" '.userConfig[$k] | if type == "object" and has("default") then .default else null end | if . == null then empty elif type == "string" then . else tojson end' "$manifest" 2>/dev/null || true)
      if [ -n "$val" ]; then printf '%s' "$val"; return 0; fi
    fi
  fi
  return 0
}

# kit_config_file_ok: succeeds unless the repo's .agentic-workflow-kit.json exists and is not
# valid JSON (then it prints why). A deny gate checks it so a broken file cannot switch it off.
kit_config_file_ok() {
  local root file
  command -v jq >/dev/null 2>&1 || return 0
  root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  file="${root:-.}/.agentic-workflow-kit.json"
  [ -f "$file" ] || return 0
  jq empty "$file" >/dev/null 2>&1 && return 0
  echo "kit-config: $file is not valid JSON" >&2
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    get)
      [ -n "${2:-}" ] || { echo "usage: kit-config.sh get <key> [explicit-value]" >&2; exit 2; }
      kit_config "$2" "${3:-}"
      exit $?
      ;;
    *)
      echo "usage: kit-config.sh get <key> [explicit-value]" >&2
      exit 2
      ;;
  esac
fi
