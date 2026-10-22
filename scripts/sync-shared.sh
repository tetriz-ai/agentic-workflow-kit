#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# A plugin is installed into its own folder and cannot reach a sibling plugin, so the shared
# libraries are copied byte for byte into each plugin that uses them. shared/ is the source.
#
# Usage: scripts/sync-shared.sh          copy shared/ into every listed place
#        scripts/sync-shared.sh --check  exit 1, listing each copy that differs (CI runs this)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# source file | the paths under plugins/ that carry a copy (../bridge/... for the Codex bridge)
COPIES=(
  "kit-config.sh|guards/scripts learn/scripts plan/scripts queue/scripts review/scripts review-lenses/scripts ship/scripts"
  "cwd-resolve.sh|guards/scripts/lib review/scripts/lib ship/scripts/lib ../bridge/codex/hooks/lib"
  "hook-once.sh|guards/scripts queue/scripts review/scripts ship/scripts"
  "path-contained.sh|starter/scripts worktrees/scripts ../bridge/agent-harness"
)
check=0; [ "${1:-}" = "--check" ] && check=1
drift=0
for row in "${COPIES[@]}"; do
  src="$ROOT/shared/${row%%|*}"
  for dir in ${row#*|}; do
    dst="$ROOT/plugins/$dir/$(basename "$src")"
    if cmp -s "$src" "$dst"; then continue; fi
    if [ "$check" -eq 1 ]; then echo "drift: plugins/$dir/$(basename "$src") differs from shared/$(basename "$src")"; drift=1
    else mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; echo "copied shared/$(basename "$src") -> plugins/$dir/"; fi
  done
done
# Every copy in the tree is listed above, so a new copy cannot drift unwatched.
while IFS= read -r f; do
  case "$f" in "$ROOT"/plugins/*) rel="${f#"$ROOT"/plugins/}" ;; *) rel="../${f#"$ROOT"/}" ;; esac
  name="$(basename "$f")"; dir="$(dirname "$rel")"
  listed=0
  for row in "${COPIES[@]}"; do [ "${row%%|*}" = "$name" ] && case " ${row#*|} " in *" $dir "*) listed=1 ;; esac; done
  [ "$listed" -eq 1 ] || { echo "unlisted copy: plugins/$rel (add it to COPIES in scripts/sync-shared.sh)"; drift=1; }
done < <(find "$ROOT/plugins" "$ROOT/bridge" \( -name kit-config.sh -o -name cwd-resolve.sh -o -name hook-once.sh -o -name path-contained.sh \) -type f | sort)
[ "$drift" -eq 0 ] && { [ "$check" -eq 1 ] && echo "shared libraries: every copy matches shared/"; exit 0; }
exit 1
