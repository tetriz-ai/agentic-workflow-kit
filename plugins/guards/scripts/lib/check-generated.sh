# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# shellcheck shell=bash
# Library: generated-file guard.
#
# Sourced by post-edit-dispatcher.sh. Appends a warning to the global WARNINGS
# array when the edited file's header says it is generated: the Go convention
# ("Code generated ... DO NOT EDIT."), an "@generated" marker, or a line that
# pairs "generated" with "do not edit" in either order. Only the first 10 lines
# (at most 4 KB) are read. Returns 0 always.
#
# Inputs:
#   $1 = REL     project-relative path of the edited file (for the message)
#   $2 = FULL    path to read
# Globals written: WARNINGS (array)

_lib_check_generated() {
  local rel="$1" full="$2" marker
  [ -f "$full" ] || return 0
  marker=$(head -c 4096 "$full" 2>/dev/null | head -n 10 \
    | grep -iE -m1 'generated.{0,80}do not edit|do not edit.{0,80}generated|@generated' || true)
  [ -n "$marker" ] || return 0
  marker=$(printf '%s' "$marker" | tr -d '\r' | sed 's/^[[:space:]]*//' | cut -c1-120)
  WARNINGS+=("GENERATED FILE: You just edited $rel, whose header marks it as generated (\"$marker\"). The change will be lost on the next regeneration. Revert the edit and change the generator's input instead; the header usually names the generator.")
}
