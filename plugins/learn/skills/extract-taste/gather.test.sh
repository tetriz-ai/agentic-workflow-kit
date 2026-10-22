#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Adversarial fixture for gather.sh's scope selector.
#
# The selector keeps a project dir only when its first transcript `cwd` is
# under THIS repo, with an anchored boundary: `cwd == REPO_ROOT || cwd == REPO_ROOT/*`.
# A prefix match (`cwd == REPO_ROOT*`) would let a sibling checkout `<root>-fork` share the
# prefix and sweep another repo's private sessions in.
#
# This suite builds a sandbox CLAUDE home with planted sessions and asserts:
#   - block-the-leak : a sibling `<root>-fork` cwd is DROPPED (skip, not keep).
#                      Fails on the buggy glob form; passes on the anchored form.
#   - keep-the-real  : the repo root and a subdir cwd are KEPT.
#   - drop-private   : a private-marker dir name is dropped under every mode.
# Deterministic shell, no LLM. Run: bash gather.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/gather.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A temp git repo stands in for "this checkout" (gather.sh derives REPO_ROOT from
# `git rev-parse --show-toplevel`). mktemp may hand back a /var -> /private/var
# symlink on macOS; resolve it so REPO_ROOT matches the cwd gather.sh records.
REPO="$(cd "$TMP" && mkdir -p repo && cd repo && pwd -P)"
git -C "$REPO" init -q
git -C "$REPO" remote add origin https://example.com/acme/core.git

# A sandbox CLAUDE home so $CLAUDE_HOME/projects is ours, not the real one.
HOME_DIR="$TMP/claude-home"
PROJECTS="$HOME_DIR/projects"
mkdir -p "$PROJECTS"

# Plant one project dir with a single transcript whose first line carries `cwd`.
plant() { # dir-name, cwd-value
  local d="$PROJECTS/$1"; mkdir -p "$d"
  printf '{"cwd":"%s","type":"user"}\n' "$2" > "$d/session.jsonl"
}

plant "proj-root"     "$REPO"                 # exact repo root      -> keep
plant "proj-subdir"   "$REPO/server/x"       # under repo root      -> keep
plant "proj-fork"     "${REPO}-fork"          # SIBLING prefix-match -> must DROP
plant "personal-notes" "$REPO"                # private NAME marker  -> drop first

# Run the selector (default this-repo-verified scope) from inside the repo.
OUT="$(cd "$REPO" && CLAUDE_CONFIG_DIR="$HOME_DIR" bash "$GATE" 2>/dev/null || true)"

# Extract just the "<verb> (...): <base>" decision lines.
sel() { printf '%s' "$OUT" | grep -E "^(keep|skip|drop) .*: $1$" | head -1; }

line="$(sel proj-fork)"
case "$line" in
  keep*) bad "SIBLING core-fork was KEPT — boundary leak: $line" ;;
  skip*) ok "sibling core-fork is dropped (boundary anchored)" ;;
  *)     bad "no decision line for proj-fork (got: '${line:-<none>}')" ;;
esac

line="$(sel proj-root)"
case "$line" in keep*) ok "repo-root cwd is kept" ;; *) bad "repo-root not kept (got: '${line:-<none>}')" ;; esac

line="$(sel proj-subdir)"
case "$line" in keep*) ok "subdir cwd is kept" ;; *) bad "subdir not kept (got: '${line:-<none>}')" ;; esac

line="$(sel personal-notes)"
case "$line" in drop*) ok "private-name dir is dropped" ;; *) bad "private dir not dropped (got: '${line:-<none>}')" ;; esac

# --- @include confinement: only files inside the Claude home or this repo are listed to
#     read in full; any other target (an absolute path, a ~/ path outside the Claude home, a
#     relative path that climbs out) is listed as refused and never offered for reading.
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME/.ssh" "$TMP/outside"
echo "fake key material" > "$FAKE_HOME/.ssh/id_rsa"
echo "notes" > "$TMP/outside/notes.md"
echo "notes" > "$HOME_DIR/NOTES.md"
mkdir -p "$HOME_DIR/rules"; echo "rule" > "$HOME_DIR/rules/style.md"
echo "repo note" > "$REPO/TEAM.md"
printf '%s\n' "@NOTES.md" "see also @rules/style.md" "@~/.ssh/id_rsa" "@$TMP/outside/notes.md" \
  "@../outside/notes.md" "@$REPO/TEAM.md" > "$HOME_DIR/CLAUDE.md"
OUT2="$(cd "$REPO" && HOME="$FAKE_HOME" CLAUDE_CONFIG_DIR="$HOME_DIR" bash "$GATE" 2>/dev/null || true)"
# Rows: want (listed|refused) | include target as gather.sh resolves it
CASES=(
  "listed|$HOME_DIR/NOTES.md"
  "listed|$HOME_DIR/rules/style.md"
  "listed|$REPO/TEAM.md"
  "refused|$FAKE_HOME/.ssh/id_rsa"
  "refused|$TMP/outside/notes.md"
)
for row in "${CASES[@]}"; do
  want=${row%%|*}; target=${row#*|}
  listed=no; printf '%s\n' "$OUT2" | grep -qxF "file: $target" && listed=yes
  refused=no; printf '%s\n' "$OUT2" | grep -q "^refused (outside the Claude home and the repo): .*${target##*/}$" && refused=yes
  if [ "$want" = listed ]; then
    [ "$listed" = yes ] && ok "include listed: $target" || bad "include not listed: $target"
  else
    [ "$listed" = no ] && [ "$refused" = yes ] && ok "include refused: $target" || bad "include not refused: $target (listed=$listed refused=$refused)"
  fi
done

# --- per-session membership: a project dir whose transcripts come from two repos keeps only
#     the sessions whose own cwd is in this repo, whatever their file-name order.
MIX="$PROJECTS/proj-mixed"; mkdir -p "$MIX"
printf '{"cwd":"%s","type":"user"}\n' "$REPO" > "$MIX/a-this-repo.jsonl"
printf '{"cwd":"%s","type":"user"}\n' "$TMP/other-repo" > "$MIX/b-other-repo.jsonl"
MIX2="$PROJECTS/proj-mixed2"; mkdir -p "$MIX2"
printf '{"cwd":"%s","type":"user"}\n' "$TMP/other-repo" > "$MIX2/a-other-repo.jsonl"
printf '{"cwd":"%s","type":"user"}\n' "$REPO" > "$MIX2/b-this-repo.jsonl"
OUT3="$(cd "$REPO" && CLAUDE_CONFIG_DIR="$HOME_DIR" bash "$GATE" 2>/dev/null || true)"
# Rows: want (in|out) | session file
CASES=(
  "in|$MIX/a-this-repo.jsonl"
  "out|$MIX/b-other-repo.jsonl"
  "out|$MIX2/a-other-repo.jsonl"
  "in|$MIX2/b-this-repo.jsonl"
)
for row in "${CASES[@]}"; do
  want=${row%%|*}; f=${row#*|}
  got=out; printf '%s\n' "$OUT3" | grep -qF "	$f" && got=in
  [ "$got" = "$want" ] && ok "session $want: ${f#"$PROJECTS"/}" || bad "session ${f#"$PROJECTS"/} is $got, want $want"
done

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
