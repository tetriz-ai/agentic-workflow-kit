#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for format-on-edit.sh. Run: bash format-on-edit.test.sh
#
# The hook is best-effort and non-blocking, so the contract is: always exit 0, never
# print, and run only the formatter the repo adopted. Every formatter here is a stub on
# PATH (or in node_modules/.bin) that writes its own name into the file, so each case
# proves WHICH formatter ran, or that none did. Table-driven: one row per case.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/format-on-edit.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
pass=0; fail=0
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

# Stub formatters: each writes its name into the last argument (the file).
STUBS="$TMP/bin"; mkdir -p "$STUBS"
for f in golangci-lint gofmt prettier ruff black rustfmt; do
  printf '#!/bin/bash\nf="${@: -1}"; printf %s > "$f"\n' "$f" > "$STUBS/$f"
  chmod +x "$STUBS/$f"
done
# A PATH with the stubs and the system tools the hook needs, and no real formatter.
SYS="$TMP/sys"; mkdir -p "$SYS"
for t in bash jq git dirname basename grep ls cat sed tr printf; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$SYS/$t"
done
BASEPATH="$STUBS:$SYS"

# new_repo <name>: an empty git repo; prints its path.
new_repo() { local r="$TMP/$1"; mkdir -p "$r"; git -C "$r" init -q; printf '%s' "$r"; }

# run_hook <file> [PATH] [extra env...]: feeds the hook an Edit payload.
run_hook() {
  local file="$1" path="${2:-$BASEPATH}"; shift 2 2>/dev/null || shift
  jq -nc --arg f "$file" '{tool_input:{file_path:$f}}' | env PATH="$path" "$@" bash "$HOOK"
}

# Each row: name | setup (shell run in the repo) | file | expected content after
# ("orig" means untouched) | env (optional).
CASES=(
  "go with golangci config|touch .golangci.yml|main.go|golangci-lint|"
  "go without golangci config -> gofmt|:|main.go|gofmt|"
  "ts with .prettierrc|echo {} > .prettierrc|app.ts|prettier|"
  "ts with prettier key in package.json|echo '{\"prettier\":{}}' > package.json|app.ts|prettier|"
  "ts without prettier config -> untouched|:|app.ts|orig|"
  "ts: nested config found walking up|mkdir -p web && echo {} > web/.prettierrc && mkdir -p web/src|web/src/app.ts|prettier|"
  "py with ruff.toml|touch ruff.toml|x.py|ruff|"
  "py with [tool.ruff] in pyproject|printf '[tool.ruff]\nline-length = 100\n' > pyproject.toml|x.py|ruff|"
  "py with only [tool.black]|printf '[tool.black]\n' > pyproject.toml|x.py|black|"
  "py without config -> untouched|:|x.py|orig|"
  "rs with Cargo.toml|touch Cargo.toml|src.rs|rustfmt|"
  "rs without Cargo.toml -> untouched|:|src.rs|orig|"
  "unrecognised extension -> untouched|touch .golangci.yml|run.sh|orig|"
  "format_command setting wins|touch .golangci.yml|main.go|custom|CLAUDE_PLUGIN_OPTION_FORMAT_COMMAND=printf custom > {file}"
)

i=0
for row in "${CASES[@]}"; do
  i=$((i + 1))
  IFS='|' read -r name setup file want envv <<<"$row"
  repo=$(new_repo "case$i")
  ( cd "$repo" && eval "$setup" )
  mkdir -p "$(dirname "$repo/$file")"
  printf orig > "$repo/$file"
  if [ -n "$envv" ]; then
    out=$(run_hook "$repo/$file" "$BASEPATH" "$envv" 2>&1); rc=$?
  else
    out=$(run_hook "$repo/$file" "$BASEPATH" 2>&1); rc=$?
  fi
  got=$(cat "$repo/$file")
  if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$got" = "$want" ]; then
    echo "PASS: $name"; pass=$((pass + 1))
  else
    echo "FAIL: $name (rc=$rc out=[$out] content=[$got] want=[$want])"; fail=$((fail + 1))
  fi
done

# Local prettier binary wins over a global one.
repo=$(new_repo local-prettier)
echo '{}' > "$repo/.prettierrc"; mkdir -p "$repo/node_modules/.bin"
printf '#!/bin/bash\nf="${@: -1}"; printf LOCAL > "$f"\n' > "$repo/node_modules/.bin/prettier"
chmod +x "$repo/node_modules/.bin/prettier"; printf orig > "$repo/app.ts"
run_hook "$repo/app.ts" >/dev/null 2>&1
[ "$(cat "$repo/app.ts")" = LOCAL ] && { echo "PASS: workspace prettier over global"; pass=$((pass + 1)); } \
  || { echo "FAIL: workspace prettier over global (got $(cat "$repo/app.ts"))"; fail=$((fail + 1)); }

# A file name with shell metacharacters reaches the custom command as one argument.
repo=$(new_repo meta); f="$repo/a b;\$(touch pwned).go"; printf orig > "$f"
run_hook "$f" "$BASEPATH" 'CLAUDE_PLUGIN_OPTION_FORMAT_COMMAND=printf custom > {file}' >/dev/null 2>&1
{ [ "$(cat "$f")" = custom ] && [ ! -e "$repo/pwned" ]; } \
  && { echo "PASS: file name is an argument, not shell text"; pass=$((pass + 1)); } \
  || { echo "FAIL: file name handling (content=$(cat "$f") pwned=$([ -e "$repo/pwned" ] && echo yes || echo no))"; fail=$((fail + 1)); }

# The format_command in the edited file's own repo applies, though the session runs elsewhere.
own=$(new_repo own-setting); other=$(new_repo session-cwd)
printf '{"format_command":"printf from-own-repo > {file}"}\n' > "$own/.agentic-workflow-kit.json"
printf orig > "$own/main.go"
( cd "$other" && run_hook "$own/main.go" ) >/dev/null 2>&1
[ "$(cat "$own/main.go")" = from-own-repo ] && { echo "PASS: format_command is read from the edited file's repo"; pass=$((pass + 1)); } \
  || { echo "FAIL: format_command from the edited file's repo (got $(cat "$own/main.go"))"; fail=$((fail + 1)); }

# Robustness: no formatter installed, empty or malformed input, a file outside git.
repo=$(new_repo none); echo '{}' > "$repo/.prettierrc"; printf orig > "$repo/app.ts"
run_hook "$repo/app.ts" "$SYS" >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(cat "$repo/app.ts")" = orig ]; } && { echo "PASS: no formatter installed -> untouched, exit 0"; pass=$((pass + 1)); } \
  || { echo "FAIL: no formatter installed"; fail=$((fail + 1)); }
for input in '' 'not json {{' '{"tool_input":{"file_path":"/nonexistent/x.go"}}'; do
  printf '%s' "$input" | PATH="$BASEPATH" bash "$HOOK" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && { echo "PASS: input [$input] -> exit 0"; pass=$((pass + 1)); } \
    || { echo "FAIL: input [$input] rc=$rc"; fail=$((fail + 1)); }
done
mkdir -p "$TMP/nogit"; printf orig > "$TMP/nogit/x.go"
run_hook "$TMP/nogit/x.go" >/dev/null 2>&1
[ "$(cat "$TMP/nogit/x.go")" = orig ] && { echo "PASS: file outside a git repo untouched"; pass=$((pass + 1)); } \
  || { echo "FAIL: file outside a git repo was formatted"; fail=$((fail + 1)); }

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
