#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# PostToolUse Edit|Write|MultiEdit: reformat the just-edited file with the repo's OWN
# formatter, so on-edit output matches what the repo's CI formatting check expects and
# never creates format-then-reflag churn.
#
# Which formatter:
#   - the format_command setting, when set: run from the repo root with {file}
#     replaced by the edited file's path (passed as an argument, never spliced into
#     the shell text);
#   - otherwise detected from the file type AND the project's own config, looking
#     from the file's folder up to the repo root:
#       .go                         golangci-lint fmt when a .golangci.* config is at
#                                   the repo root, else gofmt -w
#       .js .jsx .ts .tsx .mjs .cjs prettier, only when a prettier config resolves
#       .css .scss .json .md .yaml  (.prettierrc*, prettier.config.*, or a "prettier"
#       .yml                        key in package.json); the nearest
#                                   node_modules/.bin/prettier wins over a global one
#       .py                         ruff format when ruff is configured (ruff.toml,
#                                   .ruff.toml, or [tool.ruff] in pyproject.toml),
#                                   else black when [tool.black] is configured
#       .rs                         rustfmt when a Cargo.toml is found
#   A formatter that is not installed, or a file type with no configured formatter,
#   is skipped. Running a formatter the repo did not adopt would fight its style.
#
# Best-effort and advisory: absorbs any formatter failure (for example a mid-edit
# syntax error), prints nothing, and always exits 0. It never blocks. Kept as a
# separate hook rather than folded into post-edit-dispatcher.sh because it mutates
# files and shells out to heavier tools.
set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
# file_path is top-level for Edit, Write, AND MultiEdit; one field covers all.
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)
[ -n "$FILE" ] && [ -f "$FILE" ] || exit 0

have() { command -v "$1" >/dev/null 2>&1; }

# Repo root of the edited file's OWN worktree. No root: not in a git repo, nothing to
# format.
DIR=$(cd "$(dirname "$FILE")" 2>/dev/null && pwd -P) || exit 0
ROOT=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$ROOT" ] || exit 0
ROOT=$(cd "$ROOT" && pwd -P)
FILE="$DIR/$(basename "$FILE")"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kit-config.sh
. "$HERE/kit-config.sh" 2>/dev/null || kit_config() { :; }

# find_up <name>...: print the first path named <name> found in the file's folder or an
# ancestor, stopping at the repo root. Empty when none.
find_up() {
  local d="$DIR" n
  while :; do
    for n in "$@"; do
      if [ -e "$d/$n" ]; then printf '%s' "$d/$n"; return 0; fi
    done
    [ "$d" = "$ROOT" ] && return 0
    d=$(dirname "$d")
    case "$d" in "$ROOT"*) ;; *) return 0 ;; esac
  done
}

# Runs a formatter from the repo root, discarding its output and status.
run() { ( cd "$ROOT" && "$@" ) >/dev/null 2>&1 || true; }

# The setting is read in the edited file's repo, not the session's working directory: an edit in
# another repo or worktree follows that repo's .agentic-workflow-kit.json.
CUSTOM=$(cd "$ROOT" && kit_config format_command)
if [ -n "$CUSTOM" ]; then
  # shellcheck disable=SC2016 # $1 is expanded by the inner bash, not here
  ( cd "$ROOT" && bash -c "${CUSTOM//\{file\}/\"\$1\"}" _ "$FILE" ) >/dev/null 2>&1 || true
  exit 0
fi

prettier_config() {
  local pkg
  [ -n "$(find_up .prettierrc .prettierrc.json .prettierrc.yaml .prettierrc.yml .prettierrc.json5 \
    .prettierrc.js .prettierrc.cjs .prettierrc.mjs .prettierrc.toml prettier.config.js \
    prettier.config.cjs prettier.config.mjs prettier.config.ts)" ] && return 0
  pkg=$(find_up package.json)
  [ -n "$pkg" ] && jq -e 'has("prettier")' "$pkg" >/dev/null 2>&1
}

case "$FILE" in
  *.go)
    if [ -n "$(ls "$ROOT"/.golangci.yml "$ROOT"/.golangci.yaml "$ROOT"/.golangci.toml "$ROOT"/.golangci.json 2>/dev/null)" ] \
       && have golangci-lint; then
      run golangci-lint fmt -- "$FILE"
    elif have gofmt; then
      run gofmt -w -- "$FILE"
    fi
    ;;
  *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.css|*.scss|*.json|*.md|*.yaml|*.yml)
    prettier_config || exit 0
    bin=$(find_up node_modules/.bin/prettier)
    [ -n "$bin" ] && [ -x "$bin" ] || { have prettier && bin=prettier; }
    [ -n "${bin:-}" ] && run "$bin" --write --log-level=silent -- "$FILE"
    ;;
  *.py)
    pyproject=$(find_up pyproject.toml)
    if { [ -n "$(find_up ruff.toml .ruff.toml)" ] || { [ -n "$pyproject" ] && grep -q '^\[tool\.ruff' "$pyproject"; }; } \
       && have ruff; then
      run ruff format -- "$FILE"
    elif [ -n "$pyproject" ] && grep -q '^\[tool\.black\]' "$pyproject" && have black; then
      run black -q -- "$FILE"
    fi
    ;;
  *.rs)
    [ -n "$(find_up Cargo.toml)" ] && have rustfmt && run rustfmt -- "$FILE"
    ;;
esac

exit 0
