#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Self-contained tests for review-cadence.sh. No external deps beyond git + jq.
# Run: bash review-cadence.test.sh   (exits non-zero on first failure)
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review-cadence.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1 (got [$2] want [$3])"; }

REPO=$(mktemp -d)
cleanup() { rm -rf "$REPO"; }
trap cleanup EXIT

cd "$REPO" || exit 1
git init -q; git config user.email test@example.com; git config user.name t
git commit -q --allow-empty -m c0

# Fire the hook in stdin (hook) mode with low thresholds.
fire() {
  printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$REPO" \
    | REVIEW_CADENCE_COMMITS=3 REVIEW_CADENCE_LINES=200 bash "$HOOK"
}
has_nudge() { [ "$(echo "$1" | grep -c additionalContext)" -gt 0 ] && echo yes || echo no; }

# Fire with a stubbed `gh` on PATH so the git-push open-PR check is deterministic
# (no network). $2 is the gh stub body, e.g. 'echo OPEN' or 'exit 1'.
fire_gh() {
  local bindir; bindir=$(mktemp -d)
  printf '#!/bin/bash\n%s\n' "$2" > "$bindir/gh"; chmod +x "$bindir/gh"
  printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$REPO" \
    | PATH="$bindir:$PATH" REVIEW_CADENCE_COMMITS=3 REVIEW_CADENCE_LINES=200 bash "$HOOK"
  rm -rf "$bindir"
}

echo "review-cadence.sh tests:"

# 1. First commit initializes the baseline silently.
out=$(fire "git commit -m x")
check "first-commit silent"        "${#out}" "0"
check "baseline initialized"       "$([ -s .claude/review-cadence/baseline ] && echo yes || echo no)" "yes"

# 2. Below the commit threshold -> silent.
git commit -q --allow-empty -m c1; git commit -q --allow-empty -m c2
out=$(fire "git commit -m x")
check "below-threshold silent"     "${#out}" "0"

# 3. At/above the commit threshold -> nudge once.
git commit -q --allow-empty -m c3
out=$(fire "git commit -m x")
check "threshold nudge"            "$(has_nudge "$out")" "yes"
check "nudge is valid PreToolUse"  "$(echo "$out" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" "PreToolUse"

# 4. Once-per-crossing: second fire is silent.
out=$(fire "git commit -m x")
check "once-per-crossing silent"   "${#out}" "0"

# 5. reset rebaselines to HEAD and re-arms.
bash "$HOOK" reset
check "reset rebaselines to HEAD"  "$(cat .claude/review-cadence/baseline)" "$(git rev-parse HEAD)"
check "reset clears nudge flag"    "$([ -f .claude/review-cadence/nudged ] && echo yes || echo no)" "no"

# 6. Line threshold fires on a single large commit.
bash "$HOOK" reset
seq 1 250 > big.txt; git add big.txt; git commit -q -m big
out=$(fire "git commit -m x")
check "line-threshold nudge"       "$(has_nudge "$out")" "yes"

# 7. gh pr create with unreviewed commits -> pre-PR nudge.
out=$(fire "gh pr create --fill")
check "pre-PR nudge"               "$([ "$(echo "$out" | grep -c 'pre-PR mode')" -gt 0 ] && echo yes || echo no)" "yes"
# 7b. pre-PR nudge separates soft from optional and names the skip-whitelist
#     (a confident skip must not read as a sanctioned judgment call).
check "pre-PR nudge: soft!=optional" "$([ "$(echo "$out" | grep -c 'guaranteed checkpoint')" -gt 0 ] && echo yes || echo no)" "yes"
check "pre-PR nudge: skip-whitelist" "$([ "$(echo "$out" | grep -c 'skip-whitelist')" -gt 0 ] && echo yes || echo no)" "yes"

# 8. Non-commit commands are ignored.
gs=$(fire "git status");      check "git status ignored" "${#gs}" "0"
gb=$(fire "go build ./...");  check "go build ignored"   "${#gb}" "0"

# 8b. Word-bounded matcher: commit-graph / commit-tree / prose must NOT match.
cg=$(fire "git commit-graph write"); check "commit-graph not matched" "${#cg}" "0"
ct=$(fire "git commit-tree HEAD^");  check "commit-tree not matched"  "${#ct}" "0"

# 9. NEVER blocks AND emits on a real crossing: assert both nudge and exit 0.
bash "$HOOK" reset
git commit -q --allow-empty -m x1; git commit -q --allow-empty -m x2; git commit -q --allow-empty -m x3
nudge=$(fire "git commit -m x"); rc=$?
check "exit 0 while emitting nudge" "$rc" "0"
check "crossing actually emits"     "$(has_nudge "$nudge")" "yes"

# 10. Auto re-arm: after a nudge, dropping back below threshold clears the flag
#     so a later genuine crossing nudges again without an explicit reset.
git reset -q --hard HEAD~3            # rewind below threshold (0 commits since baseline)
below=$(fire "git commit -m x")
check "below-threshold after rewind silent" "${#below}" "0"
check "rewind cleared nudge flag" "$([ -f .claude/review-cadence/nudged ] && echo yes || echo no)" "no"
git commit -q --allow-empty -m y1; git commit -q --allow-empty -m y2; git commit -q --allow-empty -m y3
re=$(fire "git commit -m x")
check "re-crossing nudges again"  "$(has_nudge "$re")" "yes"

# 11. The pre-PR nudge fires even with NO baseline (first hook call is the
#     PR), falling back to merge-base origin/main. Simulate origin/main.
bash "$HOOK" reset >/dev/null 2>&1
rm -rf .claude/review-cadence                       # no baseline at all
MASTER=$(git rev-parse HEAD)                         # treat current HEAD as the branch point
git update-ref refs/remotes/origin/main "$MASTER"
git commit -q --allow-empty -m unreviewed1; git commit -q --allow-empty -m unreviewed2
nb=$(fire "gh pr create --fill")
check "pre-PR nudge with no baseline" "$([ "$(echo "$nb" | grep -c 'pre-PR mode')" -gt 0 ] && echo yes || echo no)" "yes"

# 11b. Codex command adapters may report the session checkout in `.cwd` and
#      the command's actual worktree in `tool_input.workdir`. Cadence must key
#      state and the pre-PR diff to the explicit workdir, not to main.
WDROOT=$(mktemp -d)
git init -q "$WDROOT"
git -C "$WDROOT" config user.email test@example.com
git -C "$WDROOT" config user.name t
git -C "$WDROOT" commit -q --allow-empty -m base
WDBASE=$(git -C "$WDROOT" rev-parse HEAD)
git -C "$WDROOT" update-ref refs/remotes/origin/main "$WDBASE"
git -C "$WDROOT" commit -q --allow-empty -m unreviewed
wdpr=$(printf '{"tool_input":{"command":"gh pr create --fill","workdir":"%s"},"cwd":"%s"}' "$WDROOT" "$REPO" \
  | REVIEW_CADENCE_COMMITS=3 REVIEW_CADENCE_LINES=200 bash "$HOOK")
check "Codex workdir: pre-PR nudge uses command worktree" \
  "$([ "$(echo "$wdpr" | grep -c 'pre-PR mode')" -gt 0 ] && echo yes || echo no)" "yes"

(cd "$WDROOT" && bash "$HOOK" reset)
git -C "$WDROOT" commit -q --allow-empty -m c1
git -C "$WDROOT" commit -q --allow-empty -m c2
git -C "$WDROOT" commit -q --allow-empty -m c3
wdcadence=$(printf '{"tool_input":{"command":"git commit -m next","workdir":"%s"},"cwd":"%s"}' "$WDROOT" "$REPO" \
  | REVIEW_CADENCE_COMMITS=3 REVIEW_CADENCE_LINES=200 bash "$HOOK")
check "Codex workdir: cadence nudge uses command worktree" "$(has_nudge "$wdcadence")" "yes"
rm -rf "$WDROOT"

# 11c. Silencing direction (the guard the honored-workdir cases above do NOT
#      give): a command-controlled workdir must not be able to zero the one
#      guaranteed pre-PR review. When workdir points at a CLEAN repo (HEAD ==
#      origin/main, nothing unreviewed) but the session cwd carries real
#      unreviewed work, the nudge must STILL fire via the session-cwd fallback.
#      Without that fallback, trusting workdir alone for the diff base lets a
#      spoofed or mismatched workdir silently skip the checkpoint. ($REPO here
#      still has the 2 unreviewed commits + origin/main from case 11.)
CLEANWD=$(mktemp -d)
git init -q "$CLEANWD"
git -C "$CLEANWD" config user.email test@example.com
git -C "$CLEANWD" config user.name t
git -C "$CLEANWD" commit -q --allow-empty -m base
CLEANBASE=$(git -C "$CLEANWD" rev-parse HEAD)
git -C "$CLEANWD" update-ref refs/remotes/origin/main "$CLEANBASE"   # HEAD==origin/main -> nothing unreviewed
silenced=$(printf '{"tool_input":{"command":"gh pr create --fill","workdir":"%s"},"cwd":"%s"}' "$CLEANWD" "$REPO" \
  | REVIEW_CADENCE_COMMITS=3 REVIEW_CADENCE_LINES=200 bash "$HOOK")
check "clean workdir cannot silence pre-PR when session cwd has work" \
  "$([ "$(echo "$silenced" | grep -c 'pre-PR mode')" -gt 0 ] && echo yes || echo no)" "yes"
rm -rf "$CLEANWD"

# 12. After reset, uncommitted (working-tree) changes must NOT re-nudge
#     on the next commit - counting is committed-only.
bash "$HOOK" reset
seq 1 250 > uncommitted_big.txt                      # 250 lines, NOT committed
f2=$(fire "git commit -m x")
check "uncommitted changes do not re-nudge" "${#f2}" "0"
rm -f uncommitted_big.txt

# 13. A new file added+committed in one step is counted once committed
#     (on the next trigger), not silently dropped.
bash "$HOOK" reset
seq 1 250 > new_big.txt; git add new_big.txt; git commit -q -m "add big new file"
f3=$(fire "git commit -m x")
check "committed new file counts toward lines" "$(has_nudge "$f3")" "yes"

# 14. git push to an ALREADY-OPEN PR with unreviewed commits -> pre-PR/update nudge.
#     (Closes the iterate-after-create gap: pushing more to an open PR re-nudges.)
#     The push path is gated on the branch having an upstream (@{u}), so set one.
bash "$HOOK" reset >/dev/null 2>&1
rm -rf .claude/review-cadence
MASTER2=$(git rev-parse HEAD); git update-ref refs/remotes/origin/main "$MASTER2"  # merge-base fallback (no baseline)
git commit -q --allow-empty -m push_unreviewed1; git commit -q --allow-empty -m push_unreviewed2
pushopen=$(fire_gh "git push" "echo OPEN")
check "push to open PR nudges"         "$([ "$(echo "$pushopen" | grep -c 'Updating this open PR')" -gt 0 ] && echo yes || echo no)" "yes"
check "push nudge: no-baseline wording" "$([ "$(echo "$pushopen" | grep -c 'not yet reviewed by the panel')" -gt 0 ] && echo yes || echo no)" "yes"
# A never-baselined branch is wholly unreviewed -> always material (full fan-out).
check "push nudge: unreviewed branch is material" "$([ "$(echo "$pushopen" | grep -c 'COMPLETE same-model fan-out')" -gt 0 ] && echo yes || echo no)" "yes"

# 15. git push with NO open PR -> silent (the gh-pr-create path owns the pre-PR nudge).
pushnopr=$(fire_gh "git push" "exit 1")
check "push with no open PR silent"   "${#pushnopr}" "0"

# 16. git push must NEVER block, even when it nudges: exit 0.
fire_gh "git push" "echo OPEN" >/dev/null 2>&1; check "push hook exits 0" "$?" "0"

# 17. Word-bounded: `git push-graph` (hypothetical) / prose must not match push.
gpf=$(fire_gh "git pushy-thing" "echo OPEN"); check "non-push word not matched" "${#gpf}" "0"

# 18. Cost gate: a push with NO unreviewed commits (reset -> baseline=HEAD, so
#     PRCOMMITS=0) skips the gh network call and stays silent, even if gh would
#     say OPEN. This is the per-push network guard (don't hit the net with
#     nothing to review).
bash "$HOOK" reset >/dev/null 2>&1
nonew=$(fire_gh "git push" "echo OPEN")
check "push with 0 unreviewed commits silent (gate skips gh)" "${#nonew}" "0"

# 19. Base-ref fallback is not hard-coded to origin/main: with origin/main absent but
#     origin/master present and no baseline, the merge-base fallback resolves origin/master,
#     so an open PR with unreviewed commits still nudges.
bash "$HOOK" reset >/dev/null 2>&1; rm -rf .claude/review-cadence
git update-ref -d refs/remotes/origin/main 2>/dev/null || true
MAINPT=$(git rev-parse HEAD); git update-ref refs/remotes/origin/master "$MAINPT"
git commit -q --allow-empty -m main_unreviewed1
mainfb=$(fire "gh pr create --fill")
check "base-ref fallback resolves origin/master (not hard-coded main)" "$(has_nudge "$mainfb")" "yes"

# 19ab. `gh -R <repo> pr create` and `gh pr new` are PR creations too.
for cmd in "gh -R acme/widgets pr create --fill" "gh pr new --fill"; do
  out=$(fire "$cmd")
  check "pre-PR nudge for [$cmd]" "$(has_nudge "$out")" "yes"
done

# 19aa. An echoed "gh pr create" is not a PR creation: no pre-PR nudge.
echoed=$(fire "echo 'next: gh pr create --fill'")
check "an echoed gh pr create does not nudge" "$(has_nudge "$echoed")" "no"

# 19a. A remote not named origin: with only `upstream` configured, the fallback resolves
#      upstream/main, so the same unreviewed commit still nudges.
bash "$HOOK" reset >/dev/null 2>&1; rm -rf .claude/review-cadence
git update-ref -d refs/remotes/origin/master
git remote add upstream "$PWD/no-such-upstream.git"; git update-ref refs/remotes/upstream/main "$MAINPT"
upfb=$(fire "gh pr create --fill")
check "base-ref fallback resolves a non-origin remote (upstream/main)" "$(has_nudge "$upfb")" "yes"
git remote remove upstream; git update-ref refs/remotes/origin/master "$MAINPT"

# 19b. Push magnitude — SMALL measurable delta since a REAL panel baseline: below
#      both thresholds with >0 counted lines -> default nudge, WITHOUT the full-fan-out
#      escalation. The size never gates coverage down (review-panel content-routes);
#      it only omits the emphasis clause here.
has_escalation() { [ "$(echo "$1" | grep -c 'COMPLETE same-model fan-out')" -gt 0 ] && echo yes || echo no; }
bash "$HOOK" reset >/dev/null 2>&1                       # baseline = HEAD (a real panel run)
seq 1 5 > small_delta.txt; git add small_delta.txt; git commit -q -m "small delta"
smallpush=$(fire_gh "git push" "echo OPEN")
check "small re-push nudges (default)"        "$([ "$(echo "$smallpush" | grep -c 'Updating this open PR')" -gt 0 ] && echo yes || echo no)" "yes"
check "small re-push says since-last-panel"   "$([ "$(echo "$smallpush" | grep -c 'since the last reviewer-panel run')" -gt 0 ] && echo yes || echo no)" "yes"
check "small re-push is NOT escalated"        "$(has_escalation "$smallpush")" "no"

# 19c. Push magnitude — LARGE by lines (>= THRESHOLD_LINES) -> escalate to full fan-out.
bash "$HOOK" reset >/dev/null 2>&1
seq 1 250 > big_delta.txt; git add big_delta.txt; git commit -q -m "big delta"
bigpush=$(fire_gh "git push" "echo OPEN")
check "large-by-lines re-push escalates"      "$(has_escalation "$bigpush")" "yes"

# 19d. Push magnitude — LARGE by commit count (>= THRESHOLD_COMMITS), each commit
#      small, so it is the commit threshold (not lines) that escalates.
bash "$HOOK" reset >/dev/null 2>&1
for i in 1 2 3; do echo "l$i" > "cc$i.txt"; git add "cc$i.txt"; git commit -q -m "cc$i"; done
commitpush=$(fire_gh "git push" "echo OPEN")
check "large-by-commits re-push escalates"    "$(has_escalation "$commitpush")" "yes"

# 19e. An unmeasurable delta (here a 0-line empty commit; a binary-only
#      change is the same shape) must NOT read as small -> stays material. Fail toward
#      more review, never less.
bash "$HOOK" reset >/dev/null 2>&1
git commit -q --allow-empty -m zero_line
zeropush=$(fire_gh "git push" "echo OPEN")
check "zero-line/unmeasurable re-push is material" "$(has_escalation "$zeropush")" "yes"

# 20. Off-lineage baseline (rebase / branch-switch / fresh branch off another
#     base) recovers SILENTLY instead of reporting the cross-lineage divergence
#     as an inflated false nudge. The baseline SHA still EXISTS but is not an
#     ancestor of HEAD -> must be treated invalid and re-baselined, not counted.
git checkout -q -b _sidebr_
git commit -q --allow-empty -m side_only
SIDE=$(git rev-parse HEAD)
git checkout -q -                       # back to the prior (main) branch
git commit -q --allow-empty -m after_side_1
git commit -q --allow-empty -m after_side_2
git commit -q --allow-empty -m after_side_3
git commit -q --allow-empty -m after_side_4
mkdir -p .claude/review-cadence
printf '%s\n' "$SIDE" > .claude/review-cadence/baseline   # off-lineage baseline
rm -f .claude/review-cadence/nudged 2>/dev/null || true
offl=$(fire "git commit -m x")
check "off-lineage baseline recovers silently (no inflated nudge)" "$(has_nudge "$offl")" "no"
NEWB=$(cat .claude/review-cadence/baseline 2>/dev/null)
check "off-lineage baseline recovered to an ancestor of HEAD" \
  "$(git merge-base --is-ancestor "$NEWB" HEAD 2>/dev/null && echo yes || echo no)" "yes"
check "recovered baseline is no longer the off-lineage sha" \
  "$([ "$NEWB" != "$SIDE" ] && echo yes || echo no)" "yes"

# 21. Rewind: HEAD reset/checked-out BACKWARD so the baseline is a DESCENDANT of
#     HEAD (same lineage, ahead). No new work -> recover to HEAD (count 0), NOT to
#     an earlier branch point that would re-count already-reviewed commits.
git commit -q --allow-empty -m rw1
git commit -q --allow-empty -m rw2
AHEAD=$(git rev-parse HEAD)             # descendant we will rewind past
git reset -q --hard HEAD~1             # HEAD now behind AHEAD
mkdir -p .claude/review-cadence
printf '%s\n' "$AHEAD" > .claude/review-cadence/baseline   # baseline is a descendant of HEAD
rm -f .claude/review-cadence/nudged 2>/dev/null || true
rw=$(fire "git commit -m x")
check "rewind baseline recovers silently (no re-count)" "$(has_nudge "$rw")" "no"
check "rewind re-baselines to HEAD (not an earlier point)" \
  "$([ "$(cat .claude/review-cadence/baseline 2>/dev/null)" = "$(git rev-parse HEAD)" ] && echo yes || echo no)" "yes"

# 23. Inline-cd worktree work: a `cd <worktree> && git commit` compound command is
#     reported by the Bash tool with cwd = the MAIN checkout. The hook must attribute
#     the commit to the worktree (via the leading cd), not main — else the baseline is
#     keyed on main (HEAD never moves there) and the worktree's commits never nudge.
WTROOT=$(mktemp -d); WT="$WTROOT/wt"
git worktree add -q "$WT" -b cadence-wt-test >/dev/null 2>&1
fire_cd() {  # cwd is the MAIN repo; the command cd's into the worktree first
  printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$REPO" \
    | REVIEW_CADENCE_COMMITS=3 REVIEW_CADENCE_LINES=200 bash "$HOOK"
}
# First inline-cd commit initializes the baseline under the WORKTREE toplevel
# (not main), proving the leading cd is honored.
out=$(fire_cd "cd $WT && git commit -m x")
check "inline-cd first-commit silent"             "${#out}" "0"
check "inline-cd baseline lands on worktree"      "$([ -s "$WT/.claude/review-cadence/baseline" ] && echo yes || echo no)" "yes"
# Cross the threshold in the worktree; the inline-cd commit must nudge.
git -C "$WT" commit -q --allow-empty -m w1
git -C "$WT" commit -q --allow-empty -m w2
git -C "$WT" commit -q --allow-empty -m w3
out=$(fire_cd "cd $WT && git commit -m x")
check "inline-cd threshold nudge (worktree attributed)" "$(has_nudge "$out")" "yes"

# A single-quoted target with a space exercises the quoted-extraction branch
# (the unquoted branch would split the path at the space).
SPWT="$WTROOT/has space/wt"
git worktree add -q "$SPWT" -b cadence-wt-space >/dev/null 2>&1
out=$(fire_cd "cd '$SPWT' && git commit -m x")
check "inline-cd quoted path with space attributed" "$([ -s "$SPWT/.claude/review-cadence/baseline" ] && echo yes || echo no)" "yes"
git worktree remove --force "$SPWT" 2>/dev/null; git branch -q -D cadence-wt-space 2>/dev/null

# A leading `~` must expand to $HOME, not be treated as a relative literal
# (which would fall back to main). HOME is overridden so the worktree lives
# under it and the assertion is deterministic.
THOME=$(mktemp -d); TWT="$THOME/wt"
git worktree add -q "$TWT" -b cadence-wt-tilde >/dev/null 2>&1
out=$(printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "cd ~/wt && git commit -m x" "$REPO" \
  | HOME="$THOME" REVIEW_CADENCE_COMMITS=3 REVIEW_CADENCE_LINES=200 bash "$HOOK")
check "inline-cd tilde path expands to HOME" "$([ -s "$TWT/.claude/review-cadence/baseline" ] && echo yes || echo no)" "yes"
git worktree remove --force "$TWT" 2>/dev/null; git branch -q -D cadence-wt-tilde 2>/dev/null; rm -rf "$THOME"

git worktree remove --force "$WT" 2>/dev/null; git branch -q -D cadence-wt-test 2>/dev/null; rm -rf "$WTROOT"

# 24. Codex's explicit command workdir is command-controlled. A leading cd into a
#     different repo wins over the claimed workdir, so state and nudges follow the
#     repo the commit actually lands in.
CWSROOT=$(mktemp -d)
CWSTARGET="$CWSROOT/target"
CWSCP="$CWSROOT/claimed"
for d in "$CWSTARGET" "$CWSCP"; do
  mkdir -p "$d"; git init -q "$d"
  git -C "$d" config user.email test@example.com; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m base
done
fire_codex_spoof() {
  printf '{"tool_input":{"command":"%s","workdir":"%s"},"cwd":"%s"}' "$1" "$CWSCP" "$REPO" \
    | REVIEW_CADENCE_COMMITS=3 REVIEW_CADENCE_LINES=200 bash "$HOOK"
}
out=$(fire_codex_spoof "cd $CWSTARGET && git commit -m x")
git -C "$CWSTARGET" commit -q --allow-empty -m s1
git -C "$CWSTARGET" commit -q --allow-empty -m s2
git -C "$CWSTARGET" commit -q --allow-empty -m s3
out=$(fire_codex_spoof "cd $CWSTARGET && git commit -m x")
check "Codex claimed workdir does not hide the leading cd repo" "$(has_nudge "$out")" "yes"

# A leading subshell cd is followed too: prime the cd target above threshold and the nudge
# fires for it, not for the claimed workdir.
(cd "$CWSTARGET" && bash "$HOOK" reset)
git -C "$CWSTARGET" commit -q --allow-empty -m c1
git -C "$CWSTARGET" commit -q --allow-empty -m c2
git -C "$CWSTARGET" commit -q --allow-empty -m c3
out=$(fire_codex_spoof "(cd $CWSTARGET && git commit -m x)")
check "a subshell cd is attributed to its target, not the claimed workdir" "$(has_nudge "$out")" "yes"
rm -rf "$CWSROOT"

# 25. Multiple leading cds: `cd A && cd B && git commit` runs in B, so
#     attributing to the FIRST cd (A) is wrong. Resolution must bail to the tool
#     cwd rather than mis-key cadence state on A.
MROOT=$(mktemp -d); MA=$(mktemp -d); MB=$(mktemp -d)
git init -q "$MROOT"; git -C "$MROOT" config user.email test@example.com; git -C "$MROOT" config user.name t; git -C "$MROOT" commit -q --allow-empty -m base
for d in "$MA" "$MB"; do git init -q "$d"; git -C "$d" config user.email test@example.com; git -C "$d" config user.name t; git -C "$d" commit -q --allow-empty -m base; done
out=$(printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "cd $MA && cd $MB && git commit -m x" "$MROOT" \
  | REVIEW_CADENCE_COMMITS=3 REVIEW_CADENCE_LINES=200 bash "$HOOK")
check "multi-cd does not key state on the first cd target" \
  "$([ ! -e "$MA/.claude/review-cadence/baseline" ] && echo yes || echo no)" "yes"
rm -rf "$MROOT" "$MA" "$MB"

# 26. Design-doc routing nudge: when the reviewed range touches a routed
#     design doc (an RFC or a numbered ADR), the nudge names the routing so the
#     docs-only skip cannot be self-granted on it. A non-design diff must NOT carry
#     the note. Covers both the cadence and pre-PR trigger points.
has_design_note() { [ "$(echo "$1" | grep -c 'RFC/ADR design doc')" -gt 0 ] && echo yes || echo no; }

# 26a. cadence: an RFC file in the crossing range -> nudge carries the routing note.
bash "$HOOK" reset
mkdir -p docs/rfc
git commit -q --allow-empty -m d1
echo "# proposed design" > docs/rfc/some-feature.md; git add docs/rfc/some-feature.md; git commit -q -m "add rfc"
git commit -q --allow-empty -m d3
rfcnudge=$(fire "git commit -m x")
check "cadence nudge fires on RFC range"      "$(has_nudge "$rfcnudge")" "yes"
check "cadence nudge carries design-doc note" "$(has_design_note "$rfcnudge")" "yes"

# 26b. cadence: a non-design crossing -> nudge present but WITHOUT the note.
bash "$HOOK" reset
git commit -q --allow-empty -m n1; git commit -q --allow-empty -m n2; git commit -q --allow-empty -m n3
plainnudge=$(fire "git commit -m x")
check "cadence nudge fires on plain range"        "$(has_nudge "$plainnudge")" "yes"
check "cadence nudge omits note on plain diff"    "$(has_design_note "$plainnudge")" "no"

# 26c. numbered ADR matches; an unnumbered docs/adr file (README/TEMPLATE) does not.
bash "$HOOK" reset
mkdir -p docs/adr
echo "x" > docs/adr/0007-some-decision.md; git add docs/adr/0007-some-decision.md; git commit -q -m "add adr"
git commit -q --allow-empty -m a2; git commit -q --allow-empty -m a3
adrnudge=$(fire "git commit -m x")
check "cadence nudge carries note for numbered ADR" "$(has_design_note "$adrnudge")" "yes"

bash "$HOOK" reset
echo "y" > docs/adr/README.md; git add docs/adr/README.md; git commit -q -m "add adr readme"
git commit -q --allow-empty -m r2; git commit -q --allow-empty -m r3
readmenudge=$(fire "git commit -m x")
check "cadence nudge omits note for unnumbered adr/README" "$(has_design_note "$readmenudge")" "no"

# 26d. pre-PR: an RFC among the unreviewed commits -> pre-PR nudge carries the note.
bash "$HOOK" reset >/dev/null 2>&1
rm -rf .claude/review-cadence
PRPT=$(git rev-parse HEAD); git update-ref refs/remotes/origin/master "$PRPT"
echo "# more design" > docs/rfc/another.md; git add docs/rfc/another.md; git commit -q -m "add rfc 2"
prrfc=$(fire "gh pr create --fill")
check "pre-PR nudge fires with RFC"        "$([ "$(echo "$prrfc" | grep -c 'pre-PR mode')" -gt 0 ] && echo yes || echo no)" "yes"
check "pre-PR nudge carries design-doc note" "$(has_design_note "$prrfc")" "yes"

# 26e. push to an already-open PR whose unreviewed range includes an RFC -> the
#      push-path nudge (which also calls touches_design_doc on $PRBASE) carries
#      the note. Guards the IS_PUSH branch, distinct from gh-pr-create above.
bash "$HOOK" reset >/dev/null 2>&1
rm -rf .claude/review-cadence
PUSHPT=$(git rev-parse HEAD); git update-ref refs/remotes/origin/master "$PUSHPT"
echo "# pushed design" > docs/rfc/pushed.md; git add docs/rfc/pushed.md; git commit -q -m "add rfc 3"
pushrfc=$(fire_gh "git push" "echo OPEN")
check "push nudge fires with RFC"            "$([ "$(echo "$pushrfc" | grep -c 'Updating this open PR')" -gt 0 ] && echo yes || echo no)" "yes"
check "push nudge carries design-doc note"   "$(has_design_note "$pushrfc")" "yes"

# 26f. RFC renamed OUT of its routed path (docs/rfc/x.md -> docs/archive/x.md) must
#      still nudge: that move is the deletion/supersession case the routing table
#      flags. Rename detection would collapse the diff to the destination alone and
#      hide the old docs/rfc path; --no-renames keeps the old name visible.
bash "$HOOK" reset
echo "# routed" > docs/rfc/to-move.md; git add docs/rfc/to-move.md; git commit -q -m "add rfc to move"
bash "$HOOK" reset                                   # baseline AFTER the rfc exists
mkdir -p docs/archive
git mv docs/rfc/to-move.md docs/archive/to-move.md; git commit -q -m "rename rfc out"
git commit -q --allow-empty -m mv2; git commit -q --allow-empty -m mv3
movenudge=$(fire "git commit -m x")
check "cadence nudge fires on RFC rename-out"        "$(has_nudge "$movenudge")" "yes"
check "cadence nudge carries note on RFC rename-out" "$(has_design_note "$movenudge")" "yes"

# 27. The shared classifier and the integer settings. Each row starts from a fresh
#     baseline in its own repo, makes N empty commits, then fires one command.
#     `git -C <dir> commit` (from any cwd), `git -c k=v commit` and an env prefix are
#     commits keyed to the right repo; `echo "git commit ..."` is not. A threshold
#     that is not an integer falls back to its default (5 commits, 200 lines).
OUTSIDE=$(mktemp -d)
# Rows: name | command (R = the row's repo) | cwd (R or OUT) | commits made | extra env | want nudge
CASES=(
  "git -C from outside the repo|git -C R commit -m x|OUT|3|REVIEW_CADENCE_COMMITS=3|yes"
  "git -c option before commit|git -c core.x=y commit -m x|R|3|REVIEW_CADENCE_COMMITS=3|yes"
  "env assignment before git|GIT_AUTHOR_NAME=x git commit -m x|R|3|REVIEW_CADENCE_COMMITS=3|yes"
  "echo of git commit is not a commit|echo git commit soon|R|3|REVIEW_CADENCE_COMMITS=3|no"
  "non-integer commit threshold uses the default 5|git commit -m x|R|6|REVIEW_CADENCE_COMMITS=abc|yes"
  "non-integer commit threshold, below the default|git commit -m x|R|4|REVIEW_CADENCE_COMMITS=abc|no"
  "non-integer line threshold uses the default 200|git commit -m x|R|1|REVIEW_CADENCE_LINES=1x|no"
)
n=0
for row in "${CASES[@]}"; do
  n=$((n+1))
  IFS='|' read -r name cmd where ncommits extra want <<<"$row"
  R="$OUTSIDE/r$n"; git init -q "$R"; git -C "$R" config user.email test@example.com; git -C "$R" config user.name t
  git -C "$R" commit -q --allow-empty -m base
  (cd "$R" && bash "$HOOK" reset)
  for _ in $(seq 1 "$ncommits"); do git -C "$R" commit -q --allow-empty -m c; done
  cmd=${cmd// R / $R }
  cwd=$R; [ "$where" = OUT ] && cwd=$OUTSIDE
  out=$(printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$cmd" "$cwd" \
    | env REVIEW_CADENCE_COMMITS=3 REVIEW_CADENCE_LINES=200 "$extra" bash "$HOOK" 2>"$OUTSIDE/err")
  check "$name: nudge" "$(has_nudge "$out")" "$want"
  check "$name: no stderr" "$(cat "$OUTSIDE/err")" ""
done
rm -rf "$OUTSIDE"

# 29. Exactly the line threshold crosses it: one commit of 200 lines (threshold 200, under the
#     3-commit threshold) nudges.
EXACT=$(mktemp -d); git -C "$EXACT" init -q; git -C "$EXACT" config user.email test@example.com; git -C "$EXACT" config user.name t
git -C "$EXACT" commit -q --allow-empty -m base; (cd "$EXACT" && bash "$HOOK" reset)
seq 1 200 > "$EXACT/exact.txt"; git -C "$EXACT" add exact.txt; git -C "$EXACT" commit -q -m exact
out=$(printf '{"tool_input":{"command":"git commit -m y"},"cwd":"%s"}' "$EXACT" | REVIEW_CADENCE_COMMITS=3 REVIEW_CADENCE_LINES=200 bash "$HOOK")
check "exactly the line threshold nudges" "$(has_nudge "$out")" "yes"
rm -rf "$EXACT"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
