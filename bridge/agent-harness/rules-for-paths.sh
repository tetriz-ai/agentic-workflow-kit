#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RULE_DIR="$ROOT/.claude/rules"

# List output is the default used by the harness validators. `--print` emits the matched rule bodies so Codex can load them in one
# tool call instead of listing paths and reading each file separately.
PRINT_BODIES=0
PRINT_MAX_BYTES="${AGENTIC_KIT_RULE_BODY_MAX_BYTES:-24576}"
ALWAYS_ONLY=0
SCOPED_ONLY=0
EXPLICIT_SCOPE=0

usage() {
  cat >&2 <<EOF
usage:
  $0 [--always]
  $0 <paths...>
  $0 --print --always
  $0 --print --scoped-only <paths...>
EOF
  exit 2
}

case "$PRINT_MAX_BYTES" in
  ''|*[!0-9]*) usage ;;
esac
[ "$PRINT_MAX_BYTES" -gt 0 ] || usage

while [ "$#" -gt 0 ]; do
  case "$1" in
    --print)
      PRINT_BODIES=1
      shift
      ;;
    --always)
      ALWAYS_ONLY=1
      EXPLICIT_SCOPE=1
      shift
      ;;
    --scoped-only)
      SCOPED_ONLY=1
      EXPLICIT_SCOPE=1
      shift
      ;;
    --)
      shift
      break
      ;;
    --*) usage ;;
    *) break ;;
  esac
done

if [ "$ALWAYS_ONLY" -eq 1 ] && [ "$SCOPED_ONLY" -eq 1 ]; then
  usage
fi
if [ "$ALWAYS_ONLY" -eq 1 ] && [ "$#" -ne 0 ]; then
  usage
fi
if [ "$SCOPED_ONLY" -eq 1 ] && [ "$#" -eq 0 ]; then
  usage
fi
if [ "$SCOPED_ONLY" -eq 1 ] && [ "$PRINT_BODIES" -eq 0 ]; then
  usage
fi
if [ "$PRINT_BODIES" -eq 1 ] && [ "$EXPLICIT_SCOPE" -eq 0 ]; then
  usage
fi
if [ "$#" -eq 0 ] && [ "$EXPLICIT_SCOPE" -eq 0 ]; then
  ALWAYS_ONLY=1
fi

if [ ! -d "$RULE_DIR" ]; then
  echo "missing $RULE_DIR" >&2
  exit 1
fi

python3 - "$ROOT" "$ALWAYS_ONLY" "$SCOPED_ONLY" "$PRINT_BODIES" "$PRINT_MAX_BYTES" "$@" <<'PY'
import fnmatch
import sys
from functools import lru_cache
from pathlib import Path

root = Path(sys.argv[1])
always_only = sys.argv[2] == "1"
scoped_only = sys.argv[3] == "1"
print_bodies = sys.argv[4] == "1"
print_max_bytes = int(sys.argv[5])
def relative_input(value: str) -> str:
    """An absolute path under the repo root is matched relative to it."""
    if value.startswith("/"):
        try:
            return Path(value).resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            return value
    return value[2:] if value.startswith("./") else value

inputs = sys.argv[6:]

def expand_braces(pattern: str) -> list[str]:
    """Expand the first {a,b,...} group, recursively; no braces -> the pattern itself."""
    start = pattern.find("{")
    end = pattern.find("}", start + 1) if start != -1 else -1
    if start == -1 or end == -1:
        return [pattern]
    head, body, tail = pattern[:start], pattern[start + 1:end], pattern[end + 1:]
    return [expanded for alt in body.split(",") for expanded in expand_braces(head + alt + tail)]

def path_patterns(rule: Path) -> list[str]:
    """Parse the paths-frontmatter subset used by shared rules: a `paths:` key followed by a
    block list at any indentation, items optionally single- or double-quoted, comment lines
    allowed, `{a,b}` alternatives expanded."""
    lines = rule.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        return []

    patterns = []
    in_paths = False
    for line in lines[1:]:
        if line == "---":
            break
        if line.rstrip() == "paths:":
            in_paths = True
            continue
        if not in_paths:
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("- "):
            value = stripped[2:].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            patterns.extend(expand_braces(value))
            continue
        in_paths = False
    return patterns

def matches_glob(path: str, pattern: str) -> bool:
    path_parts = tuple(path.strip("/").split("/"))
    pattern_parts = tuple(pattern.strip("/").split("/"))

    @lru_cache(maxsize=None)
    def match(pattern_index: int, path_index: int) -> bool:
        if pattern_index == len(pattern_parts):
            return path_index == len(path_parts)
        part = pattern_parts[pattern_index]
        if part == "**":
            return any(match(pattern_index + 1, next_index) for next_index in range(path_index, len(path_parts) + 1))
        return (
            path_index < len(path_parts)
            and fnmatch.fnmatchcase(path_parts[path_index], part)
            and match(pattern_index + 1, path_index + 1)
        )

    return match(0, 0)

results = set()
for rule in sorted((root / ".claude/rules").glob("*.md")):
    patterns = path_patterns(rule)
    relative_rule = rule.relative_to(root).as_posix()
    if not patterns:
        if not scoped_only:
            results.add((relative_rule, "always"))
        continue
    if always_only:
        continue
    for input_path in inputs:
        if any(matches_glob(relative_input(input_path), pattern) for pattern in patterns):
            results.add((relative_rule, input_path))
            break

if print_bodies:
    blocks = []
    for rule, _ in sorted(results):
        body = (root / rule).read_text(encoding="utf-8")
        blocks.append(f"===== {rule} =====\n{body}" + ("" if body.endswith("\n") else "\n"))
    output = "\n".join(blocks)
    output_bytes = len(output.encode("utf-8"))
    if output_bytes > print_max_bytes:
        print(
            f"RULES_FOR_PATHS_BODY_LIMIT_EXCEEDED: {output_bytes} bytes exceeds {print_max_bytes}; "
            "run without --print for the path listing and read each listed file",
            file=sys.stderr,
        )
        for rule, matched_path in sorted(results):
            print(f"{rule}\t{matched_path}", file=sys.stderr)
        raise SystemExit(3)
    print(output, end="")
else:
    for rule, matched_path in sorted(results):
        print(f"{rule}\t{matched_path}")
PY

exit 0
