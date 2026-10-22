---
name: ship-task
description: >-
  Takes one task end to end. It grounds the task in its RFC and the code, builds it in a worktree,
  proves it works, and ships it through /ship:pr, the merge gate and /ship:github-issues. The task
  is one slice of an RFC's Task Breakdown, or a standalone GitHub issue written with the
  task-brief template. Use when the user says "ship task #N" or "take this slice end to end". To
  drain a whole Task Breakdown in dependency order, use /queue:ship-queue --integration-branch
  instead. On Codex, call it as $ship-task.
argument-hint: "[issue-number]"
---

# Skill: ship-task

Take **one task end-to-end** — ground → build → prove → ship — staying anchored to the design the whole way. One slice, one worktree, in this session. It **composes the kit's shippers** (`/ship:pr`, the merge gate, `/ship:github-issues`) — never a personal skill, so it works for anyone who installs the kit. The soft review panel fires on its own cadence; ship-task does not force it.

> **Single-task only — multi-slice drains live in `/queue:ship-queue`.** ship-task takes exactly one slice e2e. Draining a whole RFC Task Breakdown — many dependent slices, in dependency order, unattended — is **`/queue:ship-queue --integration-branch`** (it reads each issue's `Execution.Depends-on`, builds satisfied slices, merges each onto a long-lived integration branch so dependents unblock within the same run, then opens one human-reviewed integration→base-branch PR). One proven, recovery-capable home for the DAG; ship-task does not orchestrate.

**Grounding is the spine.** Everything anchors to **the codebase + the RFC** (and the PRD only if it helps — the RFC should already be PRD-anchored). Accuracy over speed: a sub-agent re-checks against the real code, never builds from a plausible guess.

Deep mechanics — the clarity gate, the autonomy rules — are in [reference.md](reference.md). Read it before the first run.

Resolve the two settings this skill reads once, up front:

```bash
BASE=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get base_branch '${user_config.base_branch}')
GATE=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get merge_gate '${user_config.merge_gate}')
```

`GATE` is the command or label that clears your merge gate; blank means the base branch's required GitHub checks.

## Step 0 — Resolve & pick branch strategy
- **Input is** a GitHub issue number (a task brief, from the task-brief template the `/plan:task-breakdown` skill holds) **or** an RFC + a slice (read the RFC's Task Breakdown row).
- Read the task-brief / slice and its References to the **RFC sections + PRD** it implements — enough to settle **stacked vs independent** (the author's choice): `depends-on` an unmerged task → **stacked** (branch off that task's branch, PR targets it); otherwise **independent** (off fresh `origin/$BASE` — see Step 1). Ask once only if genuinely ambiguous.
  - **Squash-only caveat — prefer independent.** When the repo squash-merges, a stacked PR's commits collapse into one on merge and the dependent must rebase/retarget. For a single task the **safe default is independent off fresh `origin/$BASE`** (or off the dependency once it has *merged*). Reach for a manual stack only when the dependency is genuinely unmerged and the work cannot wait — and know GitHub honors `Closes #N` only once the PR targets the default branch (see reference.md "Stacked PRs don't auto-close their issue"). A *multi-slice* dependency chain is not this skill's job — that is `/queue:ship-queue --integration-branch`, which sidesteps the squash/rebase dance via a long-lived integration branch.
- If it's an RFC slice with **no ticket yet** and the RFC is reviewed, create the issue just-in-time from the task-brief template (`/ship:github-issues`) so the work is tracked and the brief is the agent's grounding.

## Step 1 — Cut the worktree (before grounding)
- **Always work in a worktree**, cut **before** the Step 2 code-path grounding — so grounding, the clarity gate, and the build all run against current code; a stale base makes all of it stale.
- **No carve-out for meta tasks.** This holds even when the task only edits skills / rules / docs / config and touches no code path — "it's just a skill file, branch isolation doesn't matter" is the rationalization that defeats the rule. The base can still be stale (an edited file may be newer on `origin/$BASE`), so cut the worktree first and ground inside it regardless of what the task changes. The only reading allowed on the base checkout is Step 0 resolution (the issue/brief + its references to settle stacked-vs-independent) — the moment you start tracing the files the task will change, you must already be in the worktree.
- **Independent:** `git fetch origin "$BASE"` and cut from `origin/$BASE`, never a stale local `$BASE`. **Stacked:** cut off the dependency's branch (the PR targets it).
- **Heavy deps are not auto-installed.** Worktree hydration (the worktrees plugin, if installed) copies local config but never dependency directories such as `node_modules` / `.venv` — they break when copied. So if the slice touches code whose build, code generation or tests need installed dependencies, install them in the worktree (for example `pnpm install`, `uv sync`) before a build or the merge gate run. A slice that needs none (a skill or docs slice) skips this.

## Step 2 — Ground & clarity gate (in the worktree)
- **Ground:** trace the **code paths** the task touches against the worktree's current code; verify load-bearing facts, never assume. Tag each load-bearing current-state claim `verified:<file read this turn>` — an `UNVERIFIED` claim gets grounded before you build on or present it, never asserted from memory.
- **For a fix, ground its *efficacy*, not just its correctness** (a correct diff can fix nothing): **(a) reachability** — does the fix's active path actually fire in prod, or is it dead / rare code? **(b) evidence cross-check** — does the change move the issue's *cited* evidence (the exact status / vendor / site the report names), or only a plausible-but-unobserved variant? **(c) blast-radius** — is the fix single-site for a symptom the evidence shows is broader (vendor/site-agnostic)? **(d) worse-case** — does any "strictly better / never worse / no regression" claim survive an explicit worse-case search? A change claimed costless that in fact regresses some axis (freshness, latency, coverage) is a finding, not a clean ship. A "no" on any is a scope/plan flag to surface, not a silent build.
- Then the **autonomy decision** (full gate in reference.md):
  - **Autonomous** — `AFK`-tagged, grounding resolves, the acceptance is a concrete check, and no `UNRESOLVED` fork blocks it → run e2e without blocking the human.
  - **Pause** — `human-gated`, or ambiguous (missing grounding/acceptance, an unresolved fork) → surface the **one** decision/gap to the human, then proceed. Don't barrel past a genuine gate; don't stop for routine.

## Step 3 — Implement, grounded
- Follow the RFC: the LLD (schema / contracts / **package placement**), the concerns (data scoping, observability), and — **if the slice's Task Breakdown row names an implementing skill** — load it (a refactor or one-off script slice names none; proceed on the RFC + conventions). Plus the conventions it needs: the repo's own skills or agents, discovered at run time.
- Write the slice's **demoable proof** as the test: an integration test through the real path, a direct API call, a read-only script run, or an assertion that the write path lands the expected row.
- Dispatch heavy ops (builds, test runs, queries) to sub-agents; verify against real runs, not assumptions.

## Step 4 — Prove
- Run the demoable proof and confirm it passes. The cadence `review-panel` fires on its own — let it; do not force or re-invoke it.

## Step 5 — Ship (compose the kit's shippers)
- The merge gate (`GATE`) — the deterministic gate (must fully pass).
- `/ship:pr` — an impact-first PR body (per `/ship:pr-communication`), `Closes #<issue>`, anchored to the RFC slice. Stacked → the PR targets the prior task's branch.
- These are shared skills anyone with the kit has — not a personal shipper.

## Draining many slices — that is `/queue:ship-queue`
A whole RFC Task Breakdown (many dependent slices) is **not** orchestrated here. File one task-brief issue per slice (`/ship:github-issues`), label them for the queue, and run **`/queue:ship-queue --integration-branch <name>`**: it reads each issue's `Execution.Depends-on`, ships satisfied slices, `git merge`s each onto the integration branch so dependents unblock in the **same run**, and opens **one** human-reviewed integration→base-branch PR. ship-task is the per-slice spine `/queue:ship-queue` reuses — not a multi-slice orchestrator of its own.

## Team safety (why autonomous is safe here)
The load-bearing protections are automated, because none of them waits on a human read: the **clarity gate** only auto-runs fully-specified AFK tasks; **human-gated tasks pause** for the one real decision; **grounding** keeps the build anchored to the RFC + real code; the soft **`review-panel`** cadence reviews the diff as it is written (advisory — it never blocks); and **the merge gate** is the deterministic gate that must fully pass.

**No approving review is required to merge, but a human still merges.** Where the base branch requires a PR and a passing merge gate but **zero** approvals, and the agent does not run `gh pr merge` itself, the merge is a human action, not a human *review* gate. Tag by where a **decision** sits, and do not tag `human-gated` on the assumption that a line-by-line read is waiting downstream, because none is guaranteed. A gate whose stated need is "someone should read the diff" duplicates the merge gate, which runs on every task, and the review cadence's pre-PR panel — note that ship-task does not itself force the panel (the cadence owns it, per the Boundaries below), so lean on the merge gate as the guaranteed one. A genuinely consequential decision left untagged has nothing behind it.

## Boundaries (do not drift)
- Composes `/ship:pr` + the merge gate + `/ship:github-issues` — never reimplements PR creation, never depends on a personal skill.
- Does not force `/review:review-panel` (the cadence owns that) and does not run the merge gate itself beyond Step 5's gate.
- Reads the design; never edits the RFC. Design changes go back through `/plan:tech-design-doc-writing`.

## See also
- [reference.md](reference.md) — the clarity gate and the autonomy rules.
- The task-brief template the `/plan:task-breakdown` skill holds — the task brief it consumes/creates.
- `/queue:ship-queue` — drains a whole Task Breakdown (many slices) in dependency order; reuses this skill's per-slice spine.
- `/plan:tech-design-doc-writing` (produces the Task Breakdown), `/plan:task-breakdown` (the grounded builder that hardens it before a slice is shipped), `/ship:pr`, `/ship:github-issues`.
