#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests the bridge install path end to end in a temp repo: sync-codex-harness.sh copies the
# adapters and this folder, links AGENTS.md and the skills, and passes its full validator; a
# second sync changes nothing; a locally edited file is kept unless --force is given; and the
# validator fails when a required piece is missing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
for t in jq git python3; do command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 0; }; done
# shellcheck source=yq-resolve.sh
. "$HERE/yq-resolve.sh"
resolve_yq >/dev/null || { echo "SKIP: no working yq"; exit 0; }
[ -d "$HERE/../codex" ] || { echo "SKIP: run from the kit (bridge/agent-harness)"; exit 0; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
R="$TMP/repo"; git init -q -b main "$R"
printf '# Project\n' > "$R/CLAUDE.md"
mkdir -p "$R/.claude/skills/demo" "$R/.claude/rules"
printf -- '---\nname: demo\ndescription: "A demo skill."\n---\n# demo\n' > "$R/.claude/skills/demo/SKILL.md"
# The Codex validator needs the rule /starter:setup writes.
cp "$HERE/../../plugins/starter/files/rules/codex-compatibility.md" "$R/.claude/rules/"
git -C "$R" add -A; git -C "$R" commit -q -m base

sync() { (cd "$R" && bash "$HERE/sync-$1-harness.sh" ${2:+"$2"}) >"$TMP/out" 2>&1; }
snapshot() { (cd "$R" && find .codex .agent-harness -type f -exec shasum {} + 2>/dev/null | sort); }

# Rows: name | a path that must exist afterwards
CASES=(
  "the Codex sync installs the adapters|.codex/hooks.json"
  "the Codex sync installs the rules|.codex/rules/default.rules"
  "the Codex sync installs the harness helpers|.agent-harness/rules-for-paths.sh"
  "the Codex sync links AGENTS.md to CLAUDE.md|AGENTS.md"
  "the Codex sync links the skills|.agents/skills/demo/SKILL.md"
)
if sync codex; then ok "sync-codex-harness.sh passes its full validator"; else bad "sync-codex-harness.sh: $(tail -5 "$TMP/out" | tr '\n' ' ')"; fi
for row in "${CASES[@]}"; do
  IFS='|' read -r name path <<<"$row"
  if [ -e "$R/$path" ]; then ok "$name"; else bad "$name ($path missing)"; fi
done
[ "$(readlink "$R/AGENTS.md")" = CLAUDE.md ] && ok "AGENTS.md is a symlink to CLAUDE.md" || bad "AGENTS.md link: $(readlink "$R/AGENTS.md")"

# A second sync changes nothing.
before=$(snapshot); sync codex; after=$(snapshot)
[ "$before" = "$after" ] && ok "a second sync changes nothing" || bad "a second sync changed files"

# A local edit is kept and reported; --force replaces it.
printf '# local edit\n' >> "$R/.codex/config.toml"
sync codex
if grep -q 'kept     config.toml' "$TMP/out" && grep -q '# local edit' "$R/.codex/config.toml"; then ok "a locally edited file is kept and reported"
else bad "local edit not kept: $(grep -i router "$TMP/out")"; fi
sync codex --force
grep -q '# local edit' "$R/.codex/config.toml" && bad "--force did not replace the edited file" || ok "--force replaces the edited file"

# The validators fail when a required piece is missing.
# Rows: name | validator | the path removed first
BROKEN=(
  "the Codex validator fails without hooks.json|validate-codex-harness.sh|.codex/hooks.json"
  "the Codex validator fails without the execpolicy rules|validate-codex-harness.sh|.codex/rules/default.rules"
)
for row in "${BROKEN[@]}"; do
  IFS='|' read -r name validator path <<<"$row"
  cp -p "$R/$path" "$TMP/saved"
  rm -f "$R/$path"
  if (cd "$R" && bash ".agent-harness/$validator" --quick) >/dev/null 2>&1; then bad "$name (it passed)"; else ok "$name"; fi
  cp -p "$TMP/saved" "$R/$path"
done
(cd "$R" && bash .agent-harness/validate-codex-harness.sh --quick) >/dev/null 2>&1 \
  && ok "the validator passes again once the pieces are back" || bad "validator after restore"

# A repo with no CLAUDE.md and no .claude/skills: the sync says what it did not link.
R2="$TMP/bare"; git init -q -b main "$R2"
mkdir -p "$R2/.claude/rules"; cp "$HERE/../../plugins/starter/files/rules/codex-compatibility.md" "$R2/.claude/rules/"
git -C "$R2" add -A; git -C "$R2" commit -q -m base
(cd "$R2" && bash "$HERE/sync-codex-harness.sh") >"$TMP/out2" 2>&1
# Rows: name | text the sync prints
SKIPS=(
  "no CLAUDE.md: the sync says AGENTS.md is not linked|AGENTS.md not linked: there is no CLAUDE.md"
  "no .claude/skills: the sync says the skills are not linked|.agents/skills not linked: there is no .claude/skills"
)
for row in "${SKIPS[@]}"; do
  IFS='|' read -r name text <<<"$row"
  grep -qF "$text" "$TMP/out2" && ok "$name" || bad "$name: $(tr '\n' ' ' < "$TMP/out2" | cut -c1-300)"
done
[ ! -e "$R2/AGENTS.md" ] && ok "no CLAUDE.md: no AGENTS.md is created" || bad "an AGENTS.md was created without CLAUDE.md"

# Symlinks that lead out of the repo: the sync refuses before writing anything, and the outside
# files stay as they were. Rows: name | in-repo link | link target under the outside dir
LINKS=(
  "a .codex folder linked outside|.codex|."
  "an .agent-harness folder linked outside|.agent-harness|."
  "a .codex file linked outside|.codex/config.toml|config.toml"
  "an .agents folder linked outside|.agents|."
)
n=0
for row in "${LINKS[@]}"; do
  n=$((n + 1))
  IFS='|' read -r name link target <<<"$row"
  R3="$TMP/link$n"; O="$TMP/outside$n"; git init -q -b main "$R3"; mkdir -p "$O"
  printf '# Project\n' > "$R3/CLAUDE.md"; mkdir -p "$R3/.claude/skills/demo" "$R3/.claude/rules"
  printf -- '---\nname: demo\ndescription: "A demo skill."\n---\n# demo\n' > "$R3/.claude/skills/demo/SKILL.md"
  cp "$HERE/../../plugins/starter/files/rules/codex-compatibility.md" "$R3/.claude/rules/"
  printf 'outside = true\n' > "$O/config.toml"
  mkdir -p "$(dirname "$R3/$link")"; ln -s "$O/$target" "$R3/$link"
  cp -R "$O" "$TMP/before$n"
  (cd "$R3" && bash "$HERE/sync-codex-harness.sh") >"$TMP/outl" 2>&1; rc=$?
  wrote=""; [ -e "$R3/.agent-harness" ] && [ ! -L "$R3/.agent-harness" ] && wrote=" .agent-harness"
  if [ "$rc" = 2 ] && diff -r "$O" "$TMP/before$n" >/dev/null 2>&1 && [ -z "$wrote" ] && grep -q 'outside the repo' "$TMP/outl"; then
    ok "$name: the sync refuses and writes nothing"
  else bad "$name (exit $rc, outside changed: $(diff -rq "$O" "$TMP/before$n" 2>&1 | head -2 | tr '\n' ' '), wrote:$wrote, out: $(tail -3 "$TMP/outl" | tr '\n' ' '))"; fi
done

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
