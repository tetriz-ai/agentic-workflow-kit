#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for worktree-hydrate.sh — the shared logic that copies local gitignored
# files from the main checkout into a fresh worktree per .worktreeinclude.
#
# Builds a self-contained throwaway git repo + real linked worktree (no
# dependency on any real repo's state) and asserts: required + optional files
# copy, `**` recurses, the main checkout is never hydrated onto itself, unsafe
# patterns are rejected, copies are idempotent, and the run is always non-fatal.
# Must pass on macOS stock bash 3.2.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/worktree-hydrate.sh"
pass=0; fail=0
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

ok()   { echo "PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $1"; fail=$((fail + 1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3' got '$2')"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MAIN="$TMP/main"
git init -q "$MAIN"
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name t
# Tracked content + the include manifest.
mkdir -p "$MAIN/server/cfg" "$MAIN/secrets/nested"
cat > "$MAIN/.worktreeinclude" <<'EOF'
required .env
required server/cfg/app.local.yml
required secrets/**
optional present.optional
optional absent.optional
optional ../escape.txt
EOF
echo "tracked" > "$MAIN/tracked.txt"
git -C "$MAIN" add .worktreeinclude tracked.txt
git -C "$MAIN" commit -qm init
# Local gitignored files that should be copied (created AFTER commit, untracked).
echo "ENVVAL"        > "$MAIN/.env"
echo "CFGVAL"        > "$MAIN/server/cfg/app.local.yml"
echo "S1"            > "$MAIN/secrets/one.pem"
echo "S2"            > "$MAIN/secrets/nested/two.pem"
echo "OPT"           > "$MAIN/present.optional"
chmod 600 "$MAIN/.env"

# --- Linked worktree gets hydrated ---
WT="$TMP/wt"
git -C "$MAIN" worktree add -q "$WT" -b feat
out="$(bash "$SCRIPT" "$WT" 2>&1)"
[ -f "$WT/.env" ]                      && ok "required .env copied"               || bad "required .env copied ($out)"
[ -f "$WT/server/cfg/app.local.yml" ] && ok "required nested config copied"      || bad "required nested config copied"
[ -f "$WT/secrets/one.pem" ]           && ok "** top-level file copied"           || bad "** top-level file copied"
[ -f "$WT/secrets/nested/two.pem" ]    && ok "** recurses into subdir"            || bad "** recurses into subdir"
[ -f "$WT/present.optional" ]          && ok "present optional copied"            || bad "present optional copied"
[ ! -e "$WT/absent.optional" ]         && ok "absent optional is a no-op"         || bad "absent optional is a no-op"

# Content + perms preserved.
chk "content preserved" "$(cat "$WT/.env" 2>/dev/null)" "ENVVAL"
chk "perms preserved (cp -p)" "$(stat -c %a "$WT/.env" 2>/dev/null || stat -f %Lp "$WT/.env" 2>/dev/null)" "600"

# Unsafe pattern (../escape) must be ignored, never written outside the tree.
[ ! -e "$TMP/escape.txt" ] && ok "parent-traversal pattern rejected" || bad "parent-traversal pattern rejected"
printf '%s' "$out" | grep -q "unsafe pattern" && ok "unsafe pattern is logged" || bad "unsafe pattern is logged"

# --- Idempotency: a second run copies nothing (no copy summary is emitted) ---
out2="$(bash "$SCRIPT" "$WT" 2>&1)"
printf '%s' "$out2" | grep -qE 'copied=[1-9]' && bad "second run idempotent ($out2)" || ok "second run copies 0 (idempotent)"

# Pre-existing file in the worktree is never clobbered.
echo "WORKTREE_OWN" > "$WT/.env"
bash "$SCRIPT" "$WT" >/dev/null 2>&1
chk "existing worktree file untouched" "$(cat "$WT/.env")" "WORKTREE_OWN"

# --- Main checkout is never hydrated onto itself ---
rm -f "$MAIN/.env"
bash "$SCRIPT" "$MAIN" >/dev/null 2>&1
[ ! -e "$MAIN/.env" ] && ok "main checkout not self-hydrated" || bad "main checkout not self-hydrated"

# --- Always non-fatal ---
bash "$SCRIPT" "$WT" >/dev/null 2>&1; chk "exit 0 on normal run" "$?" "0"
bash "$SCRIPT" "/nonexistent/path/xyz" >/dev/null 2>&1; chk "exit 0 on bad path" "$?" "0"
bash "$SCRIPT" "$TMP" >/dev/null 2>&1; chk "exit 0 outside any git repo" "$?" "0"

# --- Unsupported glob shapes are rejected loudly, never copied ---
# The hook honours only literal paths + trailing dir/**; richer globs are
# rejected so a future pattern can never silently over-copy or partial-fail.
mkdir -p "$MAIN/services/a"
echo "SVC" > "$MAIN/services/a/.env"
printf 'optional services/*/.env\n' >> "$WT/.worktreeinclude"
out_glob="$(bash "$SCRIPT" "$WT" 2>&1)"
[ ! -e "$WT/services/a/.env" ] && ok "single-level * glob is not honoured" \
                              || bad "single-level * glob is not honoured"
printf '%s' "$out_glob" | grep -q "unsupported pattern" && ok "unsupported glob is logged" \
                                                       || bad "unsupported glob is logged"

# --- A *required* unsupported glob rejects without a false "matched nothing" ---
# (the reject comes before the matched_any accounting, so a required unsupported pattern is
#  logged once and is not counted in missing_required.)
printf 'required services/*/conf.yml\n' >> "$WT/.worktreeinclude"
out_req="$(bash "$SCRIPT" "$WT" 2>&1)"
# Assert specifically about THIS pattern (other required rules in the manifest
# may legitimately match nothing in this mutated fixture).
printf '%s' "$out_req" | grep -q "unsupported pattern.*services/\*/conf.yml" \
  && ok "required unsupported glob logged unsupported" \
  || bad "required unsupported glob logged unsupported"
printf '%s' "$out_req" | grep "matched nothing" | grep -q "services/\*/conf.yml" \
  && bad "required unsupported glob false 'matched nothing'" \
  || ok "no false 'matched nothing' for the unsupported pattern"

# --- Missing .worktreeinclude is a clean no-op (no built-in fallback) ---
WT2="$TMP/wt2"
git -C "$MAIN" worktree add -q "$WT2" -b feat2
rm -f "$WT2/.worktreeinclude"
rm -f "$MAIN/.worktreeinclude"
out_none="$(bash "$SCRIPT" "$WT2" 2>&1)"; rc=$?
chk "missing .worktreeinclude exits 0" "$rc" "0"
[ ! -e "$WT2/.env" ] && ok "missing .worktreeinclude copies nothing" \
                     || bad "missing .worktreeinclude copies nothing"
printf '%s' "$out_none" | grep -q "nothing to hydrate" && ok "missing manifest is logged" \
                                                       || bad "missing manifest is logged"

# --- A rule is never glob-expanded in the caller's cwd ---
# worktree-hydrate-claude.sh runs this script from the main checkout, where a
# `dir/**` rule's files exist. Rows: name | rule | files under the main checkout |
# files the worktree must hold afterwards.
CASES=(
  "dir/** from the main checkout's cwd copies every file|required keys/**|keys/a.pem keys/b.pem keys/c.pem|keys/a.pem keys/b.pem keys/c.pem"
  "optional dir/** from the main checkout's cwd|optional certs/**|certs/x.crt certs/sub/y.crt|certs/x.crt certs/sub/y.crt"
)
n=0
for row in "${CASES[@]}"; do
  n=$((n + 1))
  IFS='|' read -r name rule files want <<<"$row"
  M="$TMP/glob-main-$n"; W="$TMP/glob-wt-$n"
  git init -q "$M"; git -C "$M" config user.email test@example.com; git -C "$M" config user.name t
  printf '%s\n' "$rule" > "$M/.worktreeinclude"
  git -C "$M" add .worktreeinclude; git -C "$M" commit -qm init
  for f in $files; do mkdir -p "$M/$(dirname "$f")"; echo x > "$M/$f"; done
  git -C "$M" worktree add -q "$W" -b "glob-$n"
  (cd "$M" && bash "$SCRIPT" "$W" >/dev/null 2>&1)
  got=""; for f in $want; do [ -f "$W/$f" ] && got="$got $f"; done
  chk "$name" "${got# }" "$want"
done

# --- A branch whose tracked symlinks lead out of the worktree: never written through ---
M3="$TMP/m3"; OUT="$TMP/outside"; mkdir -p "$OUT"
git init -q -b main "$M3"; git -C "$M3" config user.email test@example.com; git -C "$M3" config user.name t
printf 'optional .env.local\noptional cfg/local.yml\n' > "$M3/.worktreeinclude"
git -C "$M3" add .worktreeinclude; git -C "$M3" commit -qm init
git -C "$M3" checkout -qb evil
ln -s "$OUT/target" "$M3/.env.local"; ln -s "$OUT" "$M3/cfg"
git -C "$M3" add .env.local cfg; git -C "$M3" commit -qm links
git -C "$M3" checkout -q main
echo "LOCAL" > "$M3/.env.local"; mkdir -p "$M3/cfg"; echo "CFG" > "$M3/cfg/local.yml"
git -C "$M3" worktree add -q "$TMP/wt3" evil
out="$(bash "$SCRIPT" "$TMP/wt3" 2>&1)"
[ -z "$(ls -A "$OUT")" ] && ok "a leaf and a parent link to an outside folder are not written through" || bad "outside folder written: $(ls -A "$OUT") ($out)"
[ "$(printf '%s\n' "$out" | grep -c 'refusing to copy')" = 2 ] && ok "each refused file is logged" || bad "refusals not logged: $out"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
