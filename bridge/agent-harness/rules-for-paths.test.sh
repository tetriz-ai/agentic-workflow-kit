#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for rules-for-paths.sh against a fixture repo it builds itself, so the result
# does not depend on the rules of the repo it runs in. Exit 0 when all pass.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER="$HERE/rules-for-paths.sh"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

git -C "$FIX" init -q
mkdir -p "$FIX/.claude/rules"
printf '# Always rule\nApplies everywhere.\n' > "$FIX/.claude/rules/always.md"
printf -- '---\npaths:\n  - "**/CLAUDE.md"\n---\n# Docs rule\nApplies to CLAUDE.md files.\n' > "$FIX/.claude/rules/docs.md"
printf -- '---\npaths:\n  - "src/**/*.go"\n  - "cmd/**/*.go"\n---\n# Go rule\nApplies to Go code.\n' > "$FIX/.claude/rules/go.md"
{ printf -- '---\npaths:\n  - "big/**"\n---\n# Big rule\n'; head -c 4000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$FIX/.claude/rules/big.md"

run() { (cd "$FIX" && AGENTIC_KIT_RULE_BODY_MAX_BYTES=2000 "$ROUTER" "$@"); }

# Listing mode: rows are "<rule>\t<path or always>".
legacy_output="$(run CLAUDE.md)"
printf '%s\n' "$legacy_output" | grep -F $'.claude/rules/always.md\talways' >/dev/null \
  || fail "path lookup dropped an unconditional rule"
printf '%s\n' "$legacy_output" | grep -F $'.claude/rules/docs.md\tCLAUDE.md' >/dev/null \
  || fail "path lookup dropped a scoped rule"
printf '%s\n' "$legacy_output" | grep -F '.claude/rules/go.md' >/dev/null \
  && fail "path lookup leaked a rule scoped to other paths"

# A multi-path rule resolves on a path that is not its first entry.
printf '%s\n' "$(run cmd/tool/main.go)" | grep -F $'.claude/rules/go.md\tcmd/tool/main.go' >/dev/null \
  || fail "multi-path rule dropped a non-first path entry"

# Body modes.
always_output="$(run --print --always)"
printf '%s\n' "$always_output" | grep -F '===== .claude/rules/always.md =====' >/dev/null \
  || fail "body mode omitted an unconditional rule"
printf '%s\n' "$always_output" | grep -F '# Always rule' >/dev/null \
  || fail "body mode omitted unconditional rule content"
printf '%s\n' "$always_output" | grep -F '===== .claude/rules/docs.md =====' >/dev/null \
  && fail "always-only body mode included a scoped rule"

scoped_output="$(run --print --scoped-only CLAUDE.md)"
printf '%s\n' "$scoped_output" | grep -F '===== .claude/rules/docs.md =====' >/dev/null \
  || fail "scoped-only body mode omitted a matched rule"
printf '%s\n' "$scoped_output" | grep -F '# Docs rule' >/dev/null \
  || fail "scoped-only body mode omitted matched rule content"
printf '%s\n' "$scoped_output" | grep -F '===== .claude/rules/always.md =====' >/dev/null \
  && fail "scoped-only body mode repeated an unconditional rule"

run --print --scoped-only >/dev/null 2>&1 && fail "scoped-only body mode accepted an empty path list"
run --print CLAUDE.md >/dev/null 2>&1 && fail "body mode accepted an ambiguous scope"

# Over the body budget: no partial output, an explicit marker, and the listing fallback.
large_output="$FIX/large.out"
if run --print --scoped-only big/file.txt >"$large_output" 2>"$large_output.err"; then
  fail "body mode emitted a result over its byte budget"
fi
[ ! -s "$large_output" ] || fail "oversized body mode emitted partial rule content"
grep -F 'RULES_FOR_PATHS_BODY_LIMIT_EXCEEDED' "$large_output.err" >/dev/null \
  || fail "oversized body mode omitted its explicit fallback marker"
grep -F $'.claude/rules/big.md\tbig/file.txt' "$large_output.err" >/dev/null \
  || fail "oversized body mode omitted the listing fallback"

# Frontmatter shapes: an unindented or deeper-indented list, single-quoted patterns, brace
# alternatives and absolute input paths all resolve; none of these rules is always-loaded.
printf -- '---\npaths:\n- "web/**"\n---\n# Unindented list\n' > "$FIX/.claude/rules/unindented.md"
printf -- "---\npaths:\n  - 'docs/**/*.md'\n---\n# Single-quoted\n" > "$FIX/.claude/rules/single.md"
printf -- '---\npaths:\n  - "app/**/*.{ts,tsx}"\n---\n# Braces\n' > "$FIX/.claude/rules/brace.md"
printf -- '---\npaths:\n    # a comment line\n    - "deep/**"\n---\n# Deeper indent\n' > "$FIX/.claude/rules/deeper.md"
FIX_REAL="$(cd "$FIX" && pwd -P)"
# Rows: input path | rule | want (in|out)
CASES=(
  "web/a.js|unindented.md|in"
  "docs/guide/x.md|single.md|in"
  "app/ui/view.tsx|brace.md|in"
  "app/ui/view.ts|brace.md|in"
  "app/ui/view.js|brace.md|out"
  "deep/z.txt|deeper.md|in"
  "$FIX_REAL/web/a.js|unindented.md|in"
)
q7_failures=0
for row in "${CASES[@]}"; do
  IFS='|' read -r input rule want <<<"$row"
  got=out
  printf '%s\n' "$(run "$input")" | grep -F $'.claude/rules/'"$rule"$'\t'"$input" >/dev/null && got=in
  if [ "$got" != "$want" ]; then echo "FAIL: $rule for [$input] is $got, want $want" >&2; q7_failures=$((q7_failures + 1)); fi
done
always_now="$(run --always)"
for rule in unindented.md single.md brace.md deeper.md; do
  if printf '%s\n' "$always_now" | grep -F ".claude/rules/$rule" >/dev/null; then
    echo "FAIL: $rule is read as always-loaded" >&2; q7_failures=$((q7_failures + 1))
  fi
done
[ "$q7_failures" -eq 0 ] || fail "$q7_failures frontmatter-shape case(s) failed"

echo "rules-for-paths tests passed"
