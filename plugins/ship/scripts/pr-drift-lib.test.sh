#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for pr-drift-lib.sh + the check-pr-description-drift.sh PostToolUse hook.
#
# pr_drift_detect talks to `gh` (network) and `git`, so this exercises it
# hermetically: a fake `gh` on PATH (driven by GH_* env vars) and throwaway git
# repos with caller-controlled commit times. The headline guarantee under test
# is the per-body-version dedup: a SECOND push of a NEW commit while the PR body
# is unchanged stays SILENT (a per-SHA key would re-fire on every push and make long
# sessions noisy).
#
# Run: bash pr-drift-lib.test.sh   (exits non-zero on first-block failure)
set -uo pipefail
# Every temp path this test creates goes under one directory, removed on exit (a local
# mktemp, since some mktemp builds ignore TMPDIR).
TEST_TMP="$(command mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mktemp() {
  case "${1:-}" in
    -d) command mktemp -d "$TEST_TMP/t.XXXXXX" ;;
    -u) command mktemp -u "$TEST_TMP/t.XXXXXX" ;;
    *)  command mktemp "$TEST_TMP/t.XXXXXX" ;;
  esac
}

command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/pr-drift-lib.sh"
HOOK="$DIR/check-pr-description-drift.sh"

# ── fake gh on PATH ──────────────────────────────────────────────────────────
# Emits exactly what each `gh ... --jq` call resolves to (the lib reads stdout
# directly). Driven by env: GH_PR (pr number, empty=no PR), GH_NWO (owner/name),
# GH_BODY_EDITED (ISO-Z body-edit time, empty=lookup fail), GH_AUTH (auth exit).
TMPBIN="$(mktemp -d)"
cat > "$TMPBIN/gh" <<'SH'
#!/bin/bash
case "$1" in
  auth) exit "${GH_AUTH:-0}" ;;                                  # gh auth status
  pr)   [ -n "${GH_PR:-}" ] && printf '%s\n' "$GH_PR"; exit 0 ;; # gh pr list ... --jq
  repo) printf '%s\n' "${GH_NWO:-acme/widgets}"; exit 0 ;;  # gh repo view --jq
  api)  [ -n "${GH_BODY_EDITED:-}" ] && printf '%s\n' "$GH_BODY_EDITED"; exit 0 ;; # graphql --jq
esac
exit 0
SH
chmod +x "$TMPBIN/gh"
export PATH="$TMPBIN:$PATH"

# shellcheck source=/dev/null
. "$LIB"

# Fixed body-edit instants (avoid date -r/-d portability); commit times are set
# relative to these epochs so drift is deterministic with grace pinned to 0.
export PR_DRIFT_GRACE_SECONDS=0
BODY_ISO="2026-03-01T00:00:00Z";  B1=$(jq -rn --arg s "$BODY_ISO"  '$s|fromdateiso8601')
BODY_ISO2="2026-03-05T00:00:00Z"; B2=$(jq -rn --arg s "$BODY_ISO2" '$s|fromdateiso8601')

pass=0; fail=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }

newrepo() { # -> prints a fresh repo dir on branch "feature" with one commit
  local d; d=$(mktemp -d)
  git -C "$d" init -q -b feature
  GIT_AUTHOR_DATE="$B1 +0000" GIT_COMMITTER_DATE="$B1 +0000" \
    git -C "$d" -c user.email=test@example.com -c user.name=t commit -q --allow-empty -m init
  printf '%s' "$d"
}
commit_at() { # $1 repo  $2 epoch  $3 msg
  GIT_AUTHOR_DATE="$2 +0000" GIT_COMMITTER_DATE="$2 +0000" \
    git -C "$1" -c user.email=test@example.com -c user.name=t commit -q --allow-empty -m "$3"
}
# run pr_drift_detect inside repo $1 with the given GH_* env; returns its rc
detect_in() { ( cd "$1" && pr_drift_detect ); }

echo "── pr_drift_detect ──"

# T1 first drift: body B1, commit well after -> fires (rc 0)
R=$(newrepo); commit_at "$R" "$((B1+3600))" c2
GH_PR=100 GH_NWO=acme/widgets GH_BODY_EDITED="$BODY_ISO" detect_in "$R" \
  && ok "first drift fires" || bad "first drift fires"

# T2 (the dedup) same body, a NEW commit -> SILENT (per-body-version dedup)
commit_at "$R" "$((B1+7200))" c3
GH_PR=100 GH_NWO=acme/widgets GH_BODY_EDITED="$BODY_ISO" detect_in "$R" \
  && bad "same-body new-commit re-fires (should be silent)" \
  || ok "same-body new-commit stays silent"

# T3 body edited to a new version, then drift -> re-arms (rc 0)
commit_at "$R" "$((B2+3600))" c4
GH_PR=100 GH_NWO=acme/widgets GH_BODY_EDITED="$BODY_ISO2" detect_in "$R" \
  && ok "body-edit re-arms the reminder" || bad "body-edit re-arms the reminder"

# T4 no drift: body newer than the latest commit -> silent
R=$(newrepo); commit_at "$R" "$((B1-3600))" older
GH_PR=100 GH_BODY_EDITED="$BODY_ISO" detect_in "$R" \
  && bad "body-newer-than-commit (should be silent)" || ok "no drift when body newer than commit"

# T5 grace window: commit only +30s after body edit, grace 60 -> silent
R=$(newrepo); commit_at "$R" "$((B1+30))" within
GH_PR=100 GH_BODY_EDITED="$BODY_ISO" PR_DRIFT_GRACE_SECONDS=60 detect_in "$R" \
  && bad "within-grace burst (should be silent)" || ok "within-grace burst stays silent"

# T5b a grace setting that is not an integer falls back to the default 60s: a
#     commit +30s after the edit is still inside the grace window.
for g in abc 1x; do
  R=$(newrepo); commit_at "$R" "$((B1+30))" within-bad-grace
  GH_PR=100 GH_BODY_EDITED="$BODY_ISO" PR_DRIFT_GRACE_SECONDS="$g" detect_in "$R" 2>/dev/null \
    && bad "grace=$g uses the default (should be silent)" || ok "grace=$g falls back to the default"
done

# T6 on master -> silent
R=$(mktemp -d); git -C "$R" init -q -b master
GIT_AUTHOR_DATE="$B1 +0000" GIT_COMMITTER_DATE="$B1 +0000" git -C "$R" -c user.email=test@example.com -c user.name=t commit -q --allow-empty -m m
GH_PR=100 GH_BODY_EDITED="$BODY_ISO" detect_in "$R" \
  && bad "master should be silent" || ok "master branch stays silent"

# T7 no open PR -> silent
R=$(newrepo); commit_at "$R" "$((B1+3600))" c
GH_PR="" GH_BODY_EDITED="$BODY_ISO" detect_in "$R" \
  && bad "no-PR should be silent" || ok "no open PR stays silent"

# T8 gh auth probe surfaces unauth (rc 2), authed (rc 0). GH_AUTH must be
# EXPORTED so the mock gh child process sees it.
( export GH_AUTH=2; pr_drift_gh_status ); [ "$?" -eq 2 ] && ok "gh_status flags unauth" || bad "gh_status flags unauth"
( export GH_AUTH=0; pr_drift_gh_status ); [ "$?" -eq 0 ] && ok "gh_status ok when authed" || bad "gh_status ok when authed"

echo "── check-pr-description-drift.sh (hook) ──"
payload() { jq -nc --arg c "$1" '{tool_input:{command:$c}}'; }
# run the hook in repo $1 with env $2.. ; the hook finds its lib beside itself and
# cwd supplies the git context.
hook_in() { local r="$1"; shift; ( cd "$r" && env "$@" bash "$HOOK" ); }

# H1 non-push command -> no output
R=$(newrepo); commit_at "$R" "$((B1+3600))" c
out=$(printf '%s' "$(payload 'echo hi')" | hook_in "$R" GH_PR=100 GH_BODY_EDITED="$BODY_ISO")
[ -z "$out" ] && ok "non-push command silent" || bad "non-push command silent (got: $out)"

# H1b no jq on PATH: an advisory hook stays silent with exit 0 (a non-zero exit is
# shown to the user as a hook error).
NOJQ=$(mktemp -d)
for t in bash sh git cat sed tr grep dirname basename env; do
  p=$(command -v "$t" 2>/dev/null) && [ -n "$p" ] && ln -sf "$p" "$NOJQ/$t"
done
nojq_bash=$(command -v bash)
out=$(cd "$R" && printf '{"tool_input":{"command":"git push"}}' | PATH="$NOJQ" "$nojq_bash" "$HOOK" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "no jq: silent exit 0" || bad "no jq: silent exit 0 (rc=$rc out=$out)"
rm -rf "$NOJQ"

# H1c a `git -C <repo> push` run from a directory outside the repo still checks that repo.
RC=$(newrepo); commit_at "$RC" "$((B1+3600))" c
OUTSIDE=$(mktemp -d)
out=$(printf '%s' "$(payload "git -C $RC push")" | hook_in "$OUTSIDE" GH_PR=100 GH_BODY_EDITED="$BODY_ISO")
rm -rf "$OUTSIDE"
printf '%s' "$out" | grep -qF 'PR #100' && ok "git -C <repo> push is checked in <repo>" || bad "git -C push from elsewhere (got: $out)"

# H2 dry-run push -> no output
out=$(printf '%s' "$(payload 'git push --dry-run')" | hook_in "$R" GH_PR=100 GH_BODY_EDITED="$BODY_ISO")
[ -z "$out" ] && ok "dry-run push silent" || bad "dry-run push silent (got: $out)"

# H3 real push with drift -> passive reminder: valid JSON, names the PR, NO
# AskUserQuestion, and carries the load-bearing cadence guidance (refresh at a
# checkpoint, not on every push) so a future edit can't silently drop it.
out=$(printf '%s' "$(payload 'git push')" | hook_in "$R" GH_PR=100 GH_BODY_EDITED="$BODY_ISO")
if printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
   && printf '%s' "$out" | grep -qF 'PR #100' \
   && printf '%s' "$out" | grep -qiF 'passive reminder' \
   && printf '%s' "$out" | grep -qiF 'every push' \
   && printf '%s' "$out" | grep -qiF 'checkpoint' \
   && ! printf '%s' "$out" | grep -qF 'AskUserQuestion'; then
  ok "push drift -> passive reminder, no AskUserQuestion, cadence guidance present"
else bad "push drift -> passive reminder (got: $out)"; fi

# H4 second push, same body -> silent (marker from H3)
commit_at "$R" "$((B1+9000))" c5
out=$(printf '%s' "$(payload 'git push')" | hook_in "$R" GH_PR=100 GH_BODY_EDITED="$BODY_ISO")
[ -z "$out" ] && ok "second push same body silent" || bad "second push same body silent (got: $out)"

echo "── pre-push-pr-drift-check.sh (sibling, shared marker) ──"
PREPUSH="$DIR/pre-push-pr-drift-check.sh"
# pre-push resolves the lib beside itself; the repo only supplies git context.
newrepo_linked() { newrepo; }
# drain stdin (refspecs), capture stderr; -u clears any inherited in-session var.
prepush_in() { local r="$1"; shift; ( cd "$r" && printf '' | env -u CLAUDE_CODE_ENTRYPOINT "$@" bash "$PREPUSH" 2>&1 ); }

# P1 in-session (CLAUDE_CODE_ENTRYPOINT set) -> defers to PostToolUse, silent
R=$(newrepo_linked); commit_at "$R" "$((B1+3600))" c
out=$(prepush_in "$R" CLAUDE_CODE_ENTRYPOINT=cli GH_PR=100 GH_BODY_EDITED="$BODY_ISO")
[ -z "$out" ] && ok "pre-push defers in-session" || bad "pre-push defers in-session (got: $out)"

# P2 terminal push (not in-session) with drift -> stderr reminder naming the PR
R=$(newrepo_linked); commit_at "$R" "$((B1+3600))" c
out=$(prepush_in "$R" GH_PR=100 GH_BODY_EDITED="$BODY_ISO")
printf '%s' "$out" | grep -qF 'PR #100' && ok "pre-push warns on drift (terminal)" \
  || bad "pre-push warns on drift (got: $out)"

# P4 HOME unset with gh not authenticated: the reminder about gh is shown and the push is never
#     blocked (the hook exits 0).
R=$(newrepo_linked); commit_at "$R" "$((B1+3600))" c
out=$( cd "$R" && printf '' | env -u CLAUDE_CODE_ENTRYPOINT -u HOME GH_AUTH=2 bash "$PREPUSH" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "pre-push with HOME unset never blocks (exit 0)" || bad "pre-push with HOME unset (exit $rc: $out)"

# P3 shared marker: a PostToolUse fire silences a following terminal pre-push
#     for the same body-version (both use .git/.pr-drift-nudged).
R=$(newrepo_linked); commit_at "$R" "$((B1+3600))" c
printf '%s' "$(payload 'git push')" | hook_in "$R" GH_PR=100 GH_BODY_EDITED="$BODY_ISO" >/dev/null
out=$(prepush_in "$R" GH_PR=100 GH_BODY_EDITED="$BODY_ISO")
[ -z "$out" ] && ok "pre-push silent after PostToolUse fired (shared marker)" \
  || bad "pre-push silent after PostToolUse fired (got: $out)"

echo "──────────────"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
