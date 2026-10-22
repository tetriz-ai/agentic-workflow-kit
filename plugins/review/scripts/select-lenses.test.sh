#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for select-lenses.sh: given a file of changed paths and lens folders, it prints the lens
# files whose `applies-to` globs match a changed path. A later folder's lens overrides an
# earlier one with the same `lens:` name; a lens with `needs-setting` is selected only when that
# setting resolves non-blank; a lens file with no `applies-to` is an error (exit 2).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SEL="$HERE/select-lenses.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
PLUG="$TMP/plugin/lenses"; REPO="$TMP/repo/.claude/review-lenses"; mkdir -p "$PLUG" "$REPO"
lens() { # lens <file> <name> <glob>... : write a lens file with a header (NEEDS=<key> adds needs-setting)
  local f="$1" n="$2"; shift 2
  { echo "---"; echo "lens: $n"; echo "applies-to:"; for g in "$@"; do echo "  - \"$g\""; done
    [ -z "${NEEDS:-}" ] || echo "needs-setting: $NEEDS"
    echo "summary: test lens $n"; echo "---"; echo "## Focus"; echo "focus of $n"; } > "$f"
}
lens "$PLUG/db.md" database-migrations "**/migrations/**" "**/*.sql"
lens "$PLUG/ui.md" client-queries "web/**/use*.{ts,tsx}"
lens "$PLUG/root.md" root-config "Makefile" "*.toml"
NEEDS=architecture_rules_file lens "$PLUG/arch.md" architecture-rules "**/*.go"
lens "$REPO/db-team.md" database-migrations "db/**"
lens "$REPO/team.md" team-only "services/**"

# select <env...> -- prints the selected lens files' basenames, sorted, space separated
select_lenses() {
  env "$@" bash "$SEL" --changed "$TMP/changed" "$PLUG" "$REPO" "$TMP/no-such-dir" 2>"$TMP/err" \
    | while IFS= read -r f; do basename "$f"; done | sort | tr '\n' ' '
}

# Rows: name | changed paths (space separated) | env | want selected (basenames, sorted)
CASES=(
  "no change selects nothing|README.md||"
  "a migration path selects nothing from the overridden plugin lens|backend/migrations/0001_init.up.sql||"
  "the repo lens of the same name wins, with its own globs|db/schema.sql||db-team.md"
  "a brace glob matches either extension|web/app/useOrders.tsx||ui.md"
  "a brace glob does not match other extensions|web/app/useOrders.js||"
  "a root-level glob matches only at the root|Makefile pkg/Makefile||root.md"
  "a single-star glob does not cross a slash|tools/x.toml||"
  "a needs-setting lens is skipped while its setting is blank|cmd/main.go||"
  "a needs-setting lens is selected once its setting is set|cmd/main.go|AGENTIC_KIT_ARCHITECTURE_RULES_FILE=docs/arch.md|arch.md"
  "lenses from both folders combine|services/a.go db/x.sql web/useA.ts||db-team.md team.md ui.md"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name changed envs want <<<"$row"
  printf '%s\n' $changed > "$TMP/changed"
  # shellcheck disable=SC2086
  got=$(select_lenses $envs)
  got=${got% }
  [ "$got" = "$want" ] && ok "$name" || bad "$name (got [$got] want [$want])"
done

# A lens file with no applies-to is an error that names the file (exit 2), not a silent skip.
printf -- '---\nlens: broken\nsummary: no globs\n---\n## Focus\nx\n' > "$REPO/broken.md"
printf 'a.go\n' > "$TMP/changed"
bash "$SEL" --changed "$TMP/changed" "$PLUG" "$REPO" >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" = 2 ] && grep -q 'broken.md' "$TMP/err" && ok "a lens without applies-to exits 2 and names the file" || bad "missing applies-to (exit $rc: $(cat "$TMP/err"))"
rm -f "$REPO/broken.md"

# The shipped lenses (the review-lenses plugin beside this one in the kit repo) all parse, and
# each is selected by a path it is written for.
SHIPPED="$HERE/../../review-lenses/lenses"
if [ -d "$SHIPPED" ]; then
  # Rows: changed path | lens file that must be selected
  for row in "db/migrations/0002_add.up.sql|database-migrations.md" "internal/sync/github/loop.go|sync-cursors.md" \
             "server/handlers/orders.go|performance.md" "pkg/dao/orders.go|multi-tenant-isolation.md"; do
    printf '%s\n' "${row%%|*}" > "$TMP/changed"
    out=$(bash "$SEL" --changed "$TMP/changed" "$SHIPPED" 2>"$TMP/err"); rc=$?
    if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q "/${row#*|}$"; then ok "shipped lens ${row#*|} is selected by ${row%%|*}"
    else bad "shipped lens ${row#*|} for ${row%%|*} (exit $rc: $(cat "$TMP/err"))"; fi
  done
  printf 'cmd/main.go\n' > "$TMP/changed"
  out=$(env -u AGENTIC_KIT_ARCHITECTURE_RULES_FILE bash "$SEL" --changed "$TMP/changed" "$SHIPPED" 2>/dev/null)
  printf '%s\n' "$out" | grep -q 'architecture-rules.md' && bad "architecture-rules offered with no rules document set" || ok "architecture-rules is not offered with no rules document set"
fi

# Usage errors.
bash "$SEL" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "no arguments is a usage error" || bad "no arguments (exit $rc)"
bash "$SEL" --changed "$TMP/missing-list" "$PLUG" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "a missing changed-paths file is an error" || bad "missing changed-paths file (exit $rc)"

# A malformed glob is an error named on stderr, never a silent no-match.
BADDIR="$TMP/bad-lenses"; mkdir -p "$BADDIR"; lens "$BADDIR/broken.md" broken "web/{a,b"
printf 'web/a\n' > "$TMP/changed"
bash "$SEL" --changed "$TMP/changed" "$BADDIR" >/dev/null 2>"$TMP/err"; rc=$?
if [ "$rc" = 2 ] && grep -q 'malformed glob: web/{a,b' "$TMP/err"; then ok "a malformed glob exits 2 and names the glob"
else bad "a malformed glob (exit $rc: $(cat "$TMP/err"))"; fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
