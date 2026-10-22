#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for setup.sh against fixture repos. `plan` writes nothing; `apply <part>` writes only that
# part, merges instead of clobbering (settings, deny list, .gitignore), never overwrites a file the
# repo already has unless --force, and running it twice changes nothing the second time.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/setup.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
newrepo() { local r="$TMP/$1"; git init -q "$r"; printf '%s' "$r"; }
run() { (cd "$1" && shift && bash "$SUT" "$@" >"$TMP/out" 2>"$TMP/err"); echo $?; }

# --- plan writes nothing ---
R=$(newrepo plan); rc=$(run "$R" plan)
[ "$rc" = 0 ] && [ -z "$(cd "$R" && git status --porcelain)" ] && grep -q 'config' "$TMP/out" && ok "plan lists the parts and writes nothing" || bad "plan (exit $rc: $(cat "$TMP/err"))"

# --- each part, on a fresh repo: Rows: part | args | a file that must exist afterwards | a check on it (jq or grep -q) ---
CASES=(
  "config|--set base_branch=trunk --set queue_label=ready|.agentic-workflow-kit.json|jq -e '.base_branch == \"trunk\" and .queue_label == \"ready\"'"
  "deny||.claude/settings.json|jq -e 'any(.permissions.deny[]; . == \"Bash(gh pr merge:*)\")'"
  "rules||.claude/rules/operational-principles.md|grep -q 'Verify, and flag'"
  "rule-index||scripts/check-rule-index.sh|grep -q 'Rule coverage'"
  "githooks||.githooks/post-checkout|test -x"
  "gitignore||.gitignore|grep -qx '.claude/triage/'"
  "worktreeinclude||.worktreeinclude|grep -q 'required'"
)
n=0
for row in "${CASES[@]}"; do
  n=$((n + 1))
  IFS='|' read -r part args file check <<<"$row"
  R=$(newrepo "p$n")
  # shellcheck disable=SC2086
  rc=$(run "$R" apply "$part" $args)
  if [ "$rc" = 0 ] && [ -e "$R/$file" ] && grep -qF -- " $file" "$TMP/out" && (cd "$R" && eval "$check \"$file\"" >/dev/null 2>&1); then ok "apply $part writes $file and reports it"
  else bad "apply $part (exit $rc, file $file: $( [ -e "$R/$file" ] && echo present || echo missing); err: $(cat "$TMP/err"))"; fi
done

# --- merging: existing settings, deny list and .gitignore are kept ---
R=$(newrepo merge); mkdir -p "$R/.claude"
printf '{"model":"x","permissions":{"allow":["Bash(ls)"],"deny":["Bash(rm -rf /)"]}}\n' > "$R/.claude/settings.json"
printf '{"repo_slug":"acme/widgets"}\n' > "$R/.agentic-workflow-kit.json"
printf 'node_modules/\n' > "$R/.gitignore"
run "$R" apply deny config gitignore --set base_branch=trunk >/dev/null
jq -e '.model == "x" and (.permissions.allow == ["Bash(ls)"]) and (.permissions.deny | index("Bash(rm -rf /)") != null) and (.permissions.deny | index("Bash(gh pr merge:*)") != null)' "$R/.claude/settings.json" >/dev/null \
  && ok "deny merges into an existing settings file, keeping its keys and entries" || bad "deny merge: $(cat "$R/.claude/settings.json")"
jq -e '.repo_slug == "acme/widgets" and .base_branch == "trunk"' "$R/.agentic-workflow-kit.json" >/dev/null && ok "config merges into an existing settings file" || bad "config merge"
grep -qx 'node_modules/' "$R/.gitignore" && grep -qx '.claude/triage/' "$R/.gitignore" && ok "gitignore keeps existing lines" || bad "gitignore merge"
jq -e '.permissions.deny | index("Bash(git push * trunk)") != null' "$R/.claude/settings.json" >/dev/null && ok "the deny list also protects a non-default base branch" || bad "deny for base branch trunk"

# --- edge files: Rows: name | file | its content (printf format) | part | check on the repo ---
EDGES=(
  "a .gitignore with no final newline keeps its last line whole|.gitignore|node_modules\\n.env|gitignore|grep -qx '.env' .gitignore && grep -qx '.claude/triage/' .gitignore && git check-ignore -q .env"
  "an empty settings file is read as {}|.claude/settings.json||deny|jq -e 'any(.permissions.deny[]; . == \"Bash(gh pr merge:*)\")' .claude/settings.json"
  "a whitespace-only settings file is read as {}|.claude/settings.json|\\n  \\n|deny|jq -e '.permissions.deny | length > 0' .claude/settings.json"
)
n=0
for row in "${EDGES[@]}"; do
  n=$((n + 1))
  IFS='|' read -r name file content part check <<<"$row"
  R=$(newrepo "e$n"); mkdir -p "$(dirname "$R/$file")"
  # shellcheck disable=SC2059
  printf "$content" > "$R/$file"; touch "$R/.env"
  rc=$(run "$R" apply "$part")
  if [ "$rc" = 0 ] && (cd "$R" && eval "$check" >/dev/null 2>&1); then ok "$name"; else bad "$name (exit $rc: $(head -c 200 "$R/$file" | tr '\n' '~'))"; fi
done

# --- a new file is reported as written, an existing one as merged ---
R=$(newrepo notes); run "$R" apply config >/dev/null
grep -q '^write  .agentic-workflow-kit.json' "$TMP/out" && ok "a new settings file is reported as write" || bad "new file note: $(cat "$TMP/out")"
run "$R" apply config --set base_branch=trunk >/dev/null
grep -q '^merge  .agentic-workflow-kit.json' "$TMP/out" && ok "an existing settings file is reported as merge" || bad "merge note: $(cat "$TMP/out")"

# --- idempotence: a second apply changes nothing ---
R=$(newrepo twice); run "$R" apply config deny rules rule-index githooks gitignore worktreeinclude >/dev/null
(cd "$R" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum) > "$TMP/first"
rc=$(run "$R" apply config deny rules rule-index githooks gitignore worktreeinclude)
(cd "$R" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum) > "$TMP/second"
[ "$rc" = 0 ] && cmp -s "$TMP/first" "$TMP/second" && ok "a second apply changes nothing" || bad "idempotence (exit $rc)"

# --- no clobber: a different existing file is kept, reported, and replaced only with --force ---
R=$(newrepo keep); mkdir -p "$R/.claude/rules"; echo "team version" > "$R/.claude/rules/comments.md"
rc=$(run "$R" apply rules)
[ "$rc" = 1 ] && grep -q 'comments.md' "$TMP/out" && [ "$(cat "$R/.claude/rules/comments.md")" = "team version" ] && ok "an existing different file is kept and reported (exit 1)" || bad "no clobber (exit $rc)"
rc=$(run "$R" apply rules --force)
[ "$rc" = 0 ] && grep -q 'Earn the line' "$R/.claude/rules/comments.md" && ok "--force replaces it" || bad "--force (exit $rc)"

# --- githooks: an existing core.hooksPath is not changed ---
R=$(newrepo hooks); git -C "$R" config core.hooksPath .husky
rc=$(run "$R" apply githooks)
[ "$(git -C "$R" config core.hooksPath)" = ".husky" ] && grep -q 'core.hooksPath' "$TMP/out" && ok "an existing core.hooksPath is kept and reported" || bad "hooksPath kept (exit $rc)"
R=$(newrepo hooks2); run "$R" apply githooks >/dev/null
[ "$(git -C "$R" config core.hooksPath)" = ".githooks" ] && ok "core.hooksPath is set when unset" || bad "hooksPath set"
R=$(newrepo hooks3); printf '#!/bin/sh\nexit 0\n' > "$R/.git/hooks/pre-commit"; chmod +x "$R/.git/hooks/pre-commit"
run "$R" apply githooks >/dev/null
if [ -z "$(git -C "$R" config core.hooksPath)" ] && grep -q 'keep   core.hooksPath unset: .git/hooks has pre-commit' "$TMP/out"; then ok "live .git/hooks keep core.hooksPath unset, and the note says why"
else bad "live .git/hooks: hooksPath [$(git -C "$R" config core.hooksPath)] out [$(cat "$TMP/out")]"; fi

# --- symlinks: never write through a link that leaves the repo ---
# Rows: name | part | in-repo path that is a link | link target, relative to the outside dir |
#       the outside file that must stay byte-identical (or stay absent, when the row says "absent")
LINKS=(
  "merge_json through a leaf link|deny|.claude/settings.json|settings.json|settings.json"
  "merge_json through a parent link|deny|.claude|.|settings.json"
  "merge_json config through a leaf link|config|.agentic-workflow-kit.json|kit.json|kit.json"
  "put through a leaf link|worktreeinclude|.worktreeinclude|wti|wti"
  "put through a dangling leaf link|worktreeinclude|.worktreeinclude|new-wti|absent:new-wti"
  "put through a parent link|rules|.claude|.|rules/comments.md"
  "append_lines through a leaf link|gitignore|.gitignore|gi|gi"
)
n=0
for row in "${LINKS[@]}"; do
  n=$((n + 1))
  IFS='|' read -r name part link target watch <<<"$row"
  R=$(newrepo "link$n"); O="$TMP/outside$n"; mkdir -p "$O/rules"
  printf '{"outside":true}\n' > "$O/settings.json"; printf '{"outside":true}\n' > "$O/kit.json"
  printf 'outside\n' > "$O/wti"; printf 'outside\n' > "$O/gi"; printf 'outside\n' > "$O/rules/comments.md"
  mkdir -p "$(dirname "$R/$link")"; ln -s "$O/$target" "$R/$link"
  cp -R "$O" "$TMP/before$n"
  rc=$(run "$R" apply "$part")
  case "$watch" in
    absent:*) f="${watch#absent:}"; intact=0; [ ! -e "$O/$f" ] && intact=1 ;;
    *) intact=0; cmp -s "$O/$watch" "$TMP/before$n/$watch" && intact=1 ;;
  esac
  same_dir=0; diff -r "$O" "$TMP/before$n" >/dev/null 2>&1 && same_dir=1
  if [ "$rc" = 2 ] && [ "$intact" = 1 ] && [ "$same_dir" = 1 ] && grep -q 'outside the repo' "$TMP/err"; then ok "$name is refused and the outside file is untouched"
  else bad "$name (exit $rc, outside intact $intact, outside dir unchanged $same_dir, err: $(cat "$TMP/err"))"; fi
done
# A refused part stops the whole run before anything is written.
R=$(newrepo link-all); O="$TMP/outside-all"; mkdir -p "$O"; ln -s "$O" "$R/.claude"
rc=$(run "$R" apply config deny)
[ "$rc" = 2 ] && [ ! -e "$R/.agentic-workflow-kit.json" ] && [ -z "$(ls -A "$O")" ] && ok "a refused destination writes no other part either" || bad "refused run wrote something (exit $rc, $(ls -A "$R" "$O"))"
# A link that stays inside the repo still works.
R=$(newrepo link-in); mkdir -p "$R/conf"; ln -s conf "$R/.claude"
rc=$(run "$R" apply deny)
[ "$rc" = 0 ] && jq -e '.permissions.deny | length > 0' "$R/conf/settings.json" >/dev/null 2>&1 && ok "a link that stays inside the repo is written through" || bad "inside link (exit $rc, err: $(cat "$TMP/err"))"

# --- usage ---
R=$(newrepo usage)
for args in "" "apply" "apply nosuchpart" "apply config --set Bad-Key=1" "apply config --set unknown_key=1"; do
  # shellcheck disable=SC2086
  rc=$(run "$R" $args); [ "$rc" = 2 ] && ok "usage error: [$args]" || bad "usage error expected for [$args] (exit $rc)"
done

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
