# ship-queue — continue mode (`--continue`)

Drain mode's per-issue precheck **skips** an issue that already has an open PR (that work is in flight; merging is the human's step). Continue mode is the opposite intent: **take the in-flight items toward completion** instead of skipping them. It closes the loop with the session-start nudge's "finish first" — the operator runs one command rather than hand-running `gh` per PR.

## Selection

The invoker's **assignee-scoped** issues that are **In Progress** or have an **open (unmerged) PR** — the same "finish first" set the nudge shows. A list, ordered by the chosen `--strategy`. `$BASE` and `$GATE` are the `base_branch` and `merge_gate` settings, resolved as SKILL.md shows. **`--continue` takes ISSUE numbers, never PR numbers** (ship-queue is issue-keyed everywhere): `--continue 123 124` limits to those issues; bare `--continue` takes the whole in-flight set. Given an issue, the mode resolves its open PR itself. In `--continue` mode the open-PR precheck does **not** skip — the issue enters the assess→advance path below.

## Per item: assess, then advance (the agent never merges)

1. **Assess the PR state** from `gh pr view <pr> --json isDraft,mergeStateStatus,statusCheckRollup` + the merge gate state (running / pass / fail: the gate command's compact verdict when `merge_gate` is a command, else `gh pr checks <pr>`).
2. **Advance with the one safe step the state calls for** (run heavy ops per the execution model — the merge gate as a background Bash, edits/commits in the main loop):

   | State | Advance step |
   |---|---|
   | `isDraft` | `gh pr ready <pr>`, then re-assess |
   | behind the base branch | update the branch in the slice worktree (`git fetch origin "$BASE"; git merge "origin/$BASE"`; push), then re-run the merge gate |
   | merge gate running | wait for the owning background run and re-assess; never launch a duplicate |
   | merge gate not green / not run | run the merge gate (background Bash); on red, fix (main loop or a fix-scout) and re-run |
   | gate not triggered (BLOCKED, `merge_gate` names a label that triggers the required check) | apply the label as the drain does (SKILL.md Step 3, item 6: `gh pr edit <pr> --add-label "$GATE"`); wait for the check (`gh pr checks <pr>`), then re-assess. (Only the final integration→base-branch PR leaves the label to the human, SKILL.md "Done".) |
   | CLEAN + mergeable + merge gate green | **merge-ready** — do NOT merge; mark the ledger `ready-to-merge` and surface it for the human |

3. **Ask the author when unsure — never guess** (reuse [blocker-protocol.md](blocker-protocol.md)): a non-mechanical conflict/rebase, a diverging root cause, a PR whose scope grew, or any step needing product/risk judgment → record the `<!-- ship-queue:blocked v1 -->` marker with the exact question, set the issue `Blocked`, and **move to the next item** (don't stall the list). A later run resumes it once the author answers.

## Boundary (why it stops where it stops)

`--continue` drives each PR to **merge-ready and stops** — the agent does **not** merge (permission rules deny `gh pr merge`, and the base-branch gate + merge are the human's step). So each item ends in exactly one of: **`ready-to-merge`** (surfaced for the human to merge), **`advanced`** (a step was taken — merge gate re-run, branch updated — but it is not merge-ready yet; re-runs on the next invocation), or **`blocked`** (asked the author). It never leaves a PR half-updated: an advance step either completes or is recorded as blocked.

## Ledger + resume

Reuses the run-ledger (`run-ledger.md`) with a `continue`-flavoured status per row (`ready-to-merge` / `advanced` / `blocked`). Resume re-assesses each in-flight PR from `gh` ground truth (state can have changed — the human may have merged one, or a check finished) before advancing, the same self-verified posture as the drain. Don't-stall and the idempotent blocker-resume rule are unchanged.
