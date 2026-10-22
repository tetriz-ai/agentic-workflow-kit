#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for push.sh — the only path that pushes a taste artifact and opens its PR.
#
# No network: origin is a bare repository in a temp dir, and `gh` and `pbcopy` are stubs on
# PATH (the gh stub logs every call; STUB_GH_FAIL=<subcommand> makes `gh pr <subcommand>`
# fail; STUB_PR_NUMBER is the open PR `gh pr list` reports).
#
# Contract asserted: exit 0 pushed + PR | 1 scrub blocked | 2 usage | 3 not confirmed |
# 4 a git or gh step failed. The PR targets the configured base branch and repo. A re-run
# from another clone, which has no remote-tracking branch yet, still updates the branch. The
# consolidator is tagged when the PR is opened, not on every refresh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PUSH="$HERE/push.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export HOME="$TMP/home"; mkdir -p "$HOME"

STUBS="$TMP/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/gh" <<'STUB'
#!/bin/bash
printf 'GH:%s\n' "$*" >> "${GH_LOG:-/dev/null}"
case "$1 $2" in
  "label create") exit 0 ;;
  "pr list")      printf '%s\n' "${STUB_PR_NUMBER:-}"; exit 0 ;;
  "pr view")      echo "https://github.com/acme/widgets/pull/${STUB_PR_NUMBER:-1}"; exit 0 ;;
  "pr edit")      exit 0 ;;
  "pr create")    [ "${STUB_GH_FAIL:-}" = create ] && { echo "gh: create failed" >&2; exit 1; }
                  echo "https://github.com/acme/widgets/pull/9"; exit 0 ;;
  "pr comment")   exit 0 ;;
esac
exit 0
STUB
printf '#!/bin/sh\ncat >/dev/null\n' > "$STUBS/pbcopy"
chmod +x "$STUBS/gh" "$STUBS/pbcopy"

ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN"; git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
SEED="$TMP/seed"; git clone -q "$ORIGIN" "$SEED" 2>/dev/null
git -C "$SEED" checkout -q -b main; echo base > "$SEED/README.md"; git -C "$SEED" add README.md
git -C "$SEED" commit -qm base; git -C "$SEED" push -q origin main 2>/dev/null

# new_wt <name>: a fresh clone of origin with a worktree on taste/h holding an artifact.
new_wt() {
  local c="$TMP/$1"
  git clone -q "$ORIGIN" "$c" 2>/dev/null
  git -C "$c" worktree add -q -B taste/h "$c-wt" origin/main 2>/dev/null
  mkdir -p "$c-wt/docs/taste-collection"
  printf '# taste\nUser prefers table-driven tests (%s).\n' "$1" > "$c-wt/docs/taste-collection/h.md"
  printf '%s' "$c-wt"
}
run_push() { # run_push <worktree> [env...]: prints the exit status
  local wt="$1"; shift
  env PATH="$STUBS:$PATH" GH_LOG="$GH_LOG" "$@" bash "$PUSH" h "$wt" --confirm-push >"$TMP/out" 2>"$TMP/err"
  printf '%s' "$?"
}

# A second clone made before the first push: it has no origin/taste/h tracking ref.
LATE_WT=$(new_wt late)

# Rows: name | env (space separated) | want exit | checks (GH:<re> logged, !GH:<re> not logged,
#       OUT:<re> printed, UNMOVED = origin's taste/h and the worktree's HEAD did not move).
# SAME_PLANT=1 writes the artifact exactly as origin's taste/h already holds it.
CASES=(
  "first run opens the PR against the configured base and repo|CLAUDE_PLUGIN_OPTION_BASE_BRANCH=trunk CLAUDE_PLUGIN_OPTION_REPO_SLUG=acme/widgets|0|GH:^GH:pr create .*--base trunk|GH:^GH:pr create .*--repo acme/widgets"
  "the consolidator is tagged once when the PR is opened|EXTRACT_TASTE_CONSOLIDATOR=maint|0|GH:^GH:pr comment 9"
  "a refresh of an open PR does not tag the consolidator again|EXTRACT_TASTE_CONSOLIDATOR=maint STUB_PR_NUMBER=7|0|!GH:^GH:pr comment"
  "a gh failure exits 4|STUB_GH_FAIL=create|4|"
  "a scrub hit exits 1|SCRUB_PLANT=1|1|!GH:^GH:pr create"
  "a re-run with nothing new exits 0 and commits, pushes and refreshes nothing|SAME_PLANT=1 STUB_PR_NUMBER=7|0|OUT:^push.sh: no new taste since [0-9a-f]+ \\([0-9-]+\\)|!GH:^GH:|UNMOVED"
)
n=0
for row in "${CASES[@]}"; do
  n=$((n + 1))
  IFS='|' read -r name envs want check1 check2 check3 <<<"$row"
  GH_LOG="$TMP/gh-$n.log"; : > "$GH_LOG"
  wt=$(new_wt "c$n")
  case " $envs " in *" SCRUB_PLANT=1 "*) echo "token ghp_0123456789abcdefghijklmnopqrstuvwxyz" >> "$wt/docs/taste-collection/h.md" ;; esac  # gitleaks:allow
  case " $envs " in *" SAME_PLANT=1 "*) git -C "$ORIGIN" show refs/heads/taste/h:docs/taste-collection/h.md > "$wt/docs/taste-collection/h.md" ;; esac
  remote_before=$(git -C "$ORIGIN" rev-parse -q --verify refs/heads/taste/h || true); head_before=$(git -C "$wt" rev-parse HEAD)
  # shellcheck disable=SC2086
  rc=$(run_push "$wt" $envs)
  verdict=yes
  [ "$rc" = "$want" ] || verdict="no (exit $rc, want $want: $(head -2 "$TMP/err" | tr '\n' ' '))"
  for c in "$check1" "${check2:-}" "${check3:-}"; do
    [ -n "$c" ] || continue
    case "$c" in
      GH:*)  grep -qE -- "${c#GH:}" "$GH_LOG" || verdict="no (not logged: ${c#GH:})" ;;
      !GH:*) grep -qE -- "${c#!GH:}" "$GH_LOG" && verdict="no (logged: $(grep -E -- "${c#!GH:}" "$GH_LOG" | head -1))" ;;
      OUT:*) grep -qE -- "${c#OUT:}" "$TMP/out" || verdict="no (not printed: ${c#OUT:}; got: $(head -1 "$TMP/out"))" ;;
      UNMOVED) [ "$(git -C "$ORIGIN" rev-parse -q --verify refs/heads/taste/h || true)" = "$remote_before" ] \
                 && [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || verdict="no (origin's taste/h or HEAD moved)" ;;
    esac
  done
  [ "$verdict" = yes ] && ok "$name" || bad "$name: $verdict"
done

# A re-run from the late clone (no remote-tracking branch for taste/h) still updates the branch.
GH_LOG="$TMP/gh-late.log"; : > "$GH_LOG"
rc=$(run_push "$LATE_WT" STUB_PR_NUMBER=7)
late_head=$(git -C "$LATE_WT" rev-parse HEAD)
remote_head=$(git -C "$ORIGIN" rev-parse refs/heads/taste/h 2>/dev/null)
if [ "$rc" = 0 ] && [ "$late_head" = "$remote_head" ]; then ok "re-run from a clone without the tracking branch updates it"
else bad "re-run from a clone without the tracking branch (exit $rc, local $late_head, remote $remote_head: $(head -2 "$TMP/err" | tr '\n' ' '))"; fi

# A push failure exits 4 (origin moved away).
wt=$(new_wt broken); git -C "$wt" remote set-url origin "$TMP/no-such-origin.git"
GH_LOG="$TMP/gh-broken.log"; : > "$GH_LOG"
rc=$(run_push "$wt")
[ "$rc" = 4 ] && ok "a git push failure exits 4" || bad "a git push failure exits 4 (exit $rc)"

# Usage and confirmation contract.
rc=$(env PATH="$STUBS:$PATH" bash "$PUSH" >/dev/null 2>&1; printf '%s' "$?")
[ "$rc" = 2 ] && ok "no args is usage exit 2" || bad "no args exit $rc (want 2)"
rc=$(env PATH="$STUBS:$PATH" bash "$PUSH" h "$LATE_WT" >/dev/null 2>&1; printf '%s' "$?")
[ "$rc" = 3 ] && ok "no --confirm-push is exit 3" || bad "no --confirm-push exit $rc (want 3)"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
