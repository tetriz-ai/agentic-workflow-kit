# ship-task — mechanics

The clarity gate and the autonomy rules for taking **one** slice e2e. Read [SKILL.md](SKILL.md) first. (Multi-slice dependency orchestration is **not** here — it lives in `/queue:ship-queue --integration-branch`.) `$BASE` and `$GATE` are the `base_branch` and `merge_gate` settings, resolved as SKILL.md shows.

## The clarity gate (full)

Before running a task unattended, confirm all four — any miss flips it from autonomous to pause:

1. **Grounding resolves** — the task-brief / RFC slice has References that exist (PRD/RFC sections, code paths), and you've traced them against the real code. A task you can't ground is not runnable; surface the missing anchor.
2. **Acceptance is a concrete, executable check** — a named integration test / direct API call / read-only script run / write-path-to-table assertion, not "looks right." If you can't name the check, the task isn't ready.
3. **No blocking `UNRESOLVED` fork** — nothing in the RFC's Decisions Log marked `NEEDS HUMAN` sits on this task's path.
4. **Tag** — the task is `AFK`. A `human-gated` task always pauses at its decision point.

**On pause:** surface the *one* decision or gap to the human (printed, with your recommendation), get the answer, then proceed e2e. Pause for a genuine gate or a real gap — never for routine. When clarity is full, do **not** block the human: run it.

## Autonomy rules (how to run, encoded)

- **Bias to autonomous when clarity is full.** The point is to take a clear task to a reviewed PR without the human babysitting. Stop only at a real gate (HITL tag) or a real gap (failed clarity check).
- **Ground to reality, never a plausible guess.** Build from the RFC + the actual code. If the RFC and the code disagree, that's a stop — surface it (the design may be stale), don't silently follow one.
- **Heavy ops in sub-agents.** Builds, test runs, queries, server checks → a sub-agent returns the structured result; keep the orchestrating context clean.
- **Verify before you present.** Run the proof; don't claim a green you didn't see. Report the command + result.
- **The merge gate must fully pass** before the PR is called done — a partial pass is not done.
- **Surgical scope** — build the task, not its neighbours. Out-of-scope cleanups go to a separate task, not this PR.

These are safe to run autonomously **only because** of the gates in SKILL.md. The hard merge gate is a fully-passing **merge gate**; ahead of it, the **clarity gate** only auto-runs fully-specified AFK tasks, **`human-gated`** tasks pause for the real decision, **grounding** keeps the build accurate, and the soft **`review-panel`** cadence reviews the diff as it is written (advisory, non-blocking). Every one of those is automated, which is the point: the autonomy removes the babysitting *and* the dependence on a heavy human read, and it does not remove the merge gate.

**Merging is a human action but not a human review gate** — the exact policy, and what follows for how to tag, is stated once in SKILL.md's *Team safety* section. Tag honestly against it: an over-gated task spends the pause on something the automated gates already cover, an under-gated one has nothing behind it.

## Branch strategy for the single slice (author's choice)
- **Independent (the default):** no `depends-on`, or the dependency has already **merged** → branch off **fresh `origin/$BASE`** (fetch first, never a stale local `$BASE`) and ship one PR to the base branch. This is the safe default — when the repo squash-merges, an independent PR has no rebase/retarget tail.
- **Manual stack (only when forced):** the dependency is genuinely **unmerged** and the work cannot wait → branch off the dependency's branch and target the PR at it. You own the squash/retarget dance below; prefer waiting for the dependency to merge, or — for a *chain* of slices — hand the whole breakdown to `/queue:ship-queue --integration-branch` instead of hand-stacking here.

### Verify the base is fresh by the remote — never infer it from commit subjects
`EnterWorktree` with the default `baseRef: fresh` branches off `origin/<default-branch>`, so a worktree is current *iff* that tracking ref is. Two traps make a fresh base look stale (or a stale one look fresh); check the remote, do not reason from what `git log` prints:
- **PR numbers in commit subjects are not merge order.** A long-open PR squash-merges to a *low* `#NNNN` but a *recent* commit, so `git log --oneline` showing a lower-numbered PR on top of a higher-numbered one can mean the lower number is the newer tip. Never conclude "my base is behind" because a subject's number looks old — that inference is unsound. Ground truth: `git merge-base --is-ancestor <X> <Y>` (is X an ancestor of Y?), not subject ordering.
- **The session-start `git status` "Recent commits" are the local checkout's branch**, which can itself lag `origin/$BASE` (a worktree cut fresh is often *ahead* of a stale local base branch). It is a snapshot, not the remote.

The authoritative check: `git fetch origin` (refreshes every tracking ref via the default `+refs/heads/*` refspec — `git fetch origin "$BASE"` updates `origin/$BASE` too under that refspec, but the bare form covers all refs in one call), then `git merge-base --is-ancestor "origin/$BASE" HEAD`. It **succeeds** when the true remote base is reachable from your worktree HEAD (base equal to — or ahead of, via your own commits — the remote tip = fresh) and **fails** when the remote has advanced past your base (stale). Mind the direction: a stale base is *itself* an ancestor of the advanced remote tip, so the reverse test (`HEAD` ancestor-of `origin/$BASE`) would wrongly pass exactly the stale case. On failure, rebase before grounding — a stale base makes grounding, the clarity gate, and the build all stale. If a fetch's *summary* output looks wrong, re-run the raw git command to see its unfiltered result before trusting a wrapper's rendering (`git ls-remote origin "$BASE"` asks GitHub directly).

### Stacked PRs don't auto-close their issue
GitHub honors `Closes #N` only on a PR whose base is the **default branch**. A manually-stacked PR (base = the dependency's branch) leaves `closingIssuesReferences` empty — merging it into its base will **not** close the issue. Handle it:
- Keep `Closes #N` in the body, but know it activates only once the PR targets the default branch.
- When the base PR merges, GitHub **auto-retargets** the open stacked PR to the default branch and `Closes` becomes effective on its merge. If you merge out of order or the retarget doesn't fire, **retarget the stacked PR's base yourself** (`gh pr edit <n> --base "$BASE"`).
- Until the change reaches the default branch, report the dependent issue as **still open by design** — never as closed.

### Once the parent squash-merges, move the child's base
Manual stacks only. A `/queue:ship-queue --integration-branch` drain merges its slices onto the
integration branch rather than squashing them, so none of this fires there.

A squash replaces the parent's commits on the base branch with one new commit. The child's merge-base with
the base branch is still where the parent branched from, so the child's PR lists every file the parent
touched, and a merge gate that sizes its run from the changed files sizes it from that inflated list.

Do not rebase straight onto `origin/$BASE`. It replays commits the base branch already holds, so it either
conflicts or quietly succeeds, and you cannot tell which. Move the base explicitly instead, naming
the parent's pre-merge tip as the cut-off:

```bash
git fetch origin
git rebase --onto "origin/$BASE" <pre-merge parent tip>
git push --force-with-lease
```

Fetch first either way. A stale `origin/$BASE` predates the parent's squash, so you would replay
onto a base that does not have the parent's work in it. The alternative is to fetch, branch afresh
off `origin/$BASE`, and cherry-pick the child's own commits. Changing the base also clears any
results your merge gate recorded against the old one, so the PR needs a fresh full merge gate run.

## Boundaries
- Reads the RFC; **never edits it** — design changes go through `/plan:tech-design-doc-writing`.
- Composes `/ship:pr` + the merge gate + `/ship:github-issues`; never a personal skill.
- Does not force `/review:review-panel` (the cadence owns it).
- **Single-task only.** Draining a whole Task Breakdown (many slices, dependency order, unattended) is `/queue:ship-queue --integration-branch`, not this skill — there is one home for the DAG, and it is the queue.
