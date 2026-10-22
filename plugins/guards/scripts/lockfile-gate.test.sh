#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for lockfile-gate.sh. The package managers are stubs on PATH: each writes
# STUB_WRITE into the lockfile in its cwd and exits STUB_EXIT, so no network and no
# real install is needed.
#
# The gate blocks (exit 2) a `git commit` whose staged package.json leaves the nearest
# lockfile out of sync with the index. It never destroys an unstaged edit to the
# lockfile: the working copy is restored from a snapshot taken before regenerating.
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lockfile-gate.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1 (got [$2] want [$3])"; }

TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/stubs"; mkdir -p "$STUBS"
for t in pnpm npm; do
  printf '#!/bin/sh\necho ran >> "%s/ran-%s"\nlock=pnpm-lock.yaml; [ "%s" = npm ] && lock=package-lock.json\n[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"\nprintf "%%s" "$STUB_WRITE" > "$lock"\n[ "${STUB_EXIT:-0}" = 0 ] || echo "stub: resolution failed" >&2\nexit "${STUB_EXIT:-0}"\n' \
    "$TMP" "$t" "$t" > "$STUBS/$t"
  chmod +x "$STUBS/$t"
done

# new_repo <name> <lockfile name> [nostage] [folder]: a repo with a committed package.json and
# lockfile ("lock: 1") in <folder> (default app), and an edit to package.json, staged unless
# "nostage". Prints the repo path.
new_repo() {
  local r="$TMP/$1" d="${4:-app}"
  mkdir -p "$r/$d"
  git init -q "$r"; git -C "$r" config user.email test@example.com; git -C "$r" config user.name t
  printf '{"name":"a"}' > "$r/$d/package.json"; printf 'lock: 1' > "$r/$d/$2"
  git -C "$r" add -A; git -C "$r" commit -qm base
  printf '{"name":"a","dependencies":{"x":"1"}}' > "$r/$d/package.json"
  [ "${3:-}" = nostage ] || git -C "$r" add "$d/package.json"
  printf '%s' "$r"
}

# fire <command> <cwd> [extra env...]: runs the hook with the stubs first on PATH.
fire() {
  local cmd="$1" cwd="$2"; shift 2
  jq -nc --arg c "$cmd" --arg d "$cwd" '{tool_input:{command:$c},cwd:$d}' \
    | env PATH="$STUBS:$PATH" "$@" bash "$HOOK" 2>"$TMP/err" >/dev/null
}

echo "lockfile-gate.sh tests:"

# Rows: name | lockfile | working copy before (blank = as committed) | stub writes |
#       stub exit | command (REPO = the repo) | want exit | want lockfile after
CASES=(
  "in sync|pnpm-lock.yaml||lock: 1|0|git commit -m x|0|lock: 1"
  "drift blocks, refreshed copy left to stage|pnpm-lock.yaml||lock: 2|0|git commit -m x|2|lock: 2"
  "tool failure blocks and keeps an unstaged hand edit|pnpm-lock.yaml|lock: 1 hand edit|partial|1|git commit -m x|2|lock: 1 hand edit"
  "in sync keeps an unstaged hand edit|pnpm-lock.yaml|lock: 1 hand edit|lock: 1|0|git commit -m x|0|lock: 1 hand edit"
  "drift with an unstaged hand edit blocks and keeps it|pnpm-lock.yaml|lock: 1 hand edit|lock: 2|0|git commit -m x|2|lock: 1 hand edit"
  "npm lockfile drift blocks|package-lock.json||lock: 2|0|git commit -m x|2|lock: 2"
  "git -C commit from outside the repo is gated|pnpm-lock.yaml||lock: 2|0|git -C REPO commit -m x|2|lock: 2"
  "echo of git commit is not a commit|pnpm-lock.yaml||lock: 2|0|echo git commit|0|lock: 1"
  "non-commit command ignored|pnpm-lock.yaml||lock: 2|0|git status|0|lock: 1"
)
i=0
for row in "${CASES[@]}"; do
  i=$((i+1))
  IFS='|' read -r name lock before write sexit cmd want_rc want_after <<<"$row"
  repo=$(new_repo "r$i" "$lock")
  [ -z "$before" ] || printf '%s' "$before" > "$repo/app/$lock"
  cmd=${cmd//REPO/$repo}
  cwd=$repo; case "$cmd" in *"-C $repo"*) cwd=$TMP ;; esac
  fire "$cmd" "$cwd" STUB_WRITE="$write" STUB_EXIT="$sexit"; rc=$?
  check "$name: exit" "$rc" "$want_rc"
  check "$name: lockfile after" "$(cat "$repo/app/$lock")" "$want_after"
done

# Yarn: Yarn 2 and later regenerate yarn.lock and a drift blocks; Yarn 1 has no lockfile-only
# mode, so the gate skips it with a note and the commit goes through.
printf '#!/bin/sh\nif [ "$1" = --version ]; then [ -z "${STUB_YARN_VERSION_SLEEP:-}" ] || sleep "$STUB_YARN_VERSION_SLEEP"; echo "${STUB_YARN_VERSION:-4.1.0}"; exit 0; fi\nprintf "%%s" "$STUB_WRITE" > yarn.lock\n' > "$STUBS/yarn"; chmod +x "$STUBS/yarn"
# Rows: name | yarn version | want exit | note on stderr (blank: none)
YCASES=(
  "Yarn 4 lockfile drift blocks|4.1.0|2|"
  "Yarn 1 is skipped with a note|1.22.19|0|Yarn 1"
)
for row in "${YCASES[@]}"; do
  IFS='|' read -r name ver want note <<<"$row"
  i=$((i+1)); repo=$(new_repo "y$i" yarn.lock)
  fire "git commit -m x" "$repo" STUB_WRITE="lock: 2" STUB_YARN_VERSION="$ver"; rc=$?
  check "$name: exit" "$rc" "$want"
  [ -z "$note" ] || check "$name: note" "$(grep -c "$note" "$TMP/err")" "1"
done

# The tool's own output comes with the block.
repo=$(new_repo toolerr pnpm-lock.yaml)
fire "git commit -m x" "$repo" STUB_WRITE="partial" STUB_EXIT=1; rc=$?
check "tool failure: blocked" "$rc" "2"
check "tool failure: its output is shown" "$(grep -c 'stub: resolution failed' "$TMP/err")" "1"

# Commits that take working-tree changes read every change against HEAD, not only the index.
# Rows: name | stage (staged|nostage) | folder | command | want exit
WCASES=(
  "-am with an unstaged package.json change blocks|nostage|app|git commit -am x|2"
  "--all with an unstaged package.json change blocks|nostage|app|git commit --all -m x|2"
  "a pathspec commit of an unstaged package.json blocks|nostage|app|git commit app/package.json -m x|2"
  "a pathspec after -- blocks|nostage|app|git commit -m x -- app|2"
  "a quoted message naming the file is not a pathspec|nostage|app|git commit -m \"app/package.json next\"|0"
  "a staged package.json under a non-ASCII folder blocks|staged|café|git commit -m x|2"
)
for row in "${WCASES[@]}"; do
  IFS='|' read -r name stage dir cmd want <<<"$row"
  i=$((i+1)); repo=$(new_repo "w$i" pnpm-lock.yaml "$stage" "$dir")
  fire "$cmd" "$repo" STUB_WRITE="lock: 2"; rc=$?
  check "$name: exit" "$rc" "$want"
done

# A package manager still running at commit_gate_timeout is stopped and the commit blocked.
repo=$(new_repo slowtool pnpm-lock.yaml)
fire "git commit -m x" "$repo" STUB_WRITE="lock: 1" STUB_SLEEP=30 CLAUDE_PLUGIN_OPTION_COMMIT_GATE_TIMEOUT=1; rc=$?
check "slow package manager: blocked" "$rc" "2"
check "slow package manager: reason names the deadline" "$(grep -c 'timed out after 1s in all; speed up the check, or raise commit_gate_timeout up to 570' "$TMP/err")" "1"

# One deadline covers every lockfile: three runs of 2 seconds each do not fit in 3 seconds, though
# each one alone would.
repo=$(new_repo three pnpm-lock.yaml nostage)
for d in b c; do
  mkdir -p "$repo/$d"; printf '{"name":"%s"}' "$d" > "$repo/$d/package.json"; printf 'lock: 1' > "$repo/$d/pnpm-lock.yaml"
done
git -C "$repo" add b c; git -C "$repo" commit -qm "b and c"
for d in b c; do printf '{"name":"%s","dependencies":{"x":"1"}}' "$d" > "$repo/$d/package.json"; done
git -C "$repo" add app/package.json b/package.json c/package.json
start=$SECONDS
fire "git commit -m x" "$repo" STUB_WRITE="lock: 1" STUB_SLEEP=2 CLAUDE_PLUGIN_OPTION_COMMIT_GATE_TIMEOUT=3; rc=$?
check "three lockfiles share one deadline: blocked" "$rc" "2"
check "three lockfiles share one deadline: reason" "$(grep -c 'timed out after 3s in all' "$TMP/err")" "1"
check "three lockfiles share one deadline: stopped near it" "$([ $((SECONDS - start)) -lt 9 ] && echo yes || echo no)" "yes"

# The Yarn version check runs under the same deadline: a `yarn --version` that hangs is stopped.
repo=$(new_repo yarnhang yarn.lock)
start=$SECONDS
fire "git commit -m x" "$repo" STUB_WRITE="lock: 1" STUB_YARN_VERSION_SLEEP=30 CLAUDE_PLUGIN_OPTION_COMMIT_GATE_TIMEOUT=2; rc=$?
check "a hanging yarn --version: blocked" "$rc" "2"
check "a hanging yarn --version: reason names the deadline" "$(grep -c 'timed out after 2s in all' "$TMP/err")" "1"
check "a hanging yarn --version: stopped within the deadline and grace" "$([ $((SECONDS - start)) -le 8 ] && echo yes || echo no)" "yes"

# Codex carries the command's checkout as tool_input.workdir; it wins over the session cwd.
repo=$(new_repo workdir pnpm-lock.yaml)
jq -nc --arg w "$repo" --arg d "$TMP" '{tool_input:{command:"git commit -m x",workdir:$w},cwd:$d}' \
  | env PATH="$STUBS:$PATH" STUB_WRITE="lock: 2" bash "$HOOK" 2>"$TMP/err" >/dev/null; rc=$?
check "a Codex workdir is the repo the gate checks: exit" "$rc" "2"

# No staged package.json: nothing runs.
repo=$(new_repo nostage pnpm-lock.yaml nostage)
rm -f "$TMP/ran-pnpm"
fire "git commit -m x" "$repo" STUB_WRITE="lock: 2"; rc=$?
check "no staged package.json: exit" "$rc" "0"
check "no staged package.json: tool not run" "$([ -e "$TMP/ran-pnpm" ] && echo ran || echo none)" "none"

# A missing package manager is not a block; the gate says so.
repo=$(new_repo notool pnpm-lock.yaml)
NOPNPM="$TMP/nopnpm"; mkdir -p "$NOPNPM"
for t in bash sh git cat sed tr grep dirname basename tail head mktemp rm env cp cmp jq; do
  p=$(command -v "$t" 2>/dev/null) && [ -n "$p" ] && ln -sf "$p" "$NOPNPM/$t"
done
BASH_BIN=$(command -v bash)
printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$repo" | PATH="$NOPNPM" "$BASH_BIN" "$HOOK" 2>"$TMP/err" >/dev/null; rc=$?
check "missing pnpm: exit" "$rc" "0"
check "missing pnpm: noted" "$(grep -q 'pnpm not installed' "$TMP/err" && echo yes)" "yes"

# No jq: a commit is blocked with a reason (exit 127 would be a non-blocking error,
# which lets the commit through); a command that is not a commit still passes.
rm -f "$NOPNPM/jq"; ln -sf "$STUBS/pnpm" "$NOPNPM/pnpm"
for row in "git commit -m x|2" "git status|0"; do
  IFS='|' read -r cmd want <<<"$row"
  printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$cmd" "$repo" | PATH="$NOPNPM" "$BASH_BIN" "$HOOK" 2>"$TMP/err" >/dev/null; rc=$?
  check "no jq: $cmd exit" "$rc" "$want"
  [ "$want" = 2 ] && check "no jq: reason names jq" "$(grep -q 'jq' "$TMP/err" && echo yes)" "yes"
done

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
