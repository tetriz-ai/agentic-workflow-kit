# ship-queue — blocked-and-continue protocol

On-demand detail for **Step 5**. Read this the moment an issue hits a per-issue blocker. The whole point: a blocker on **one** issue must **not** stall the queue — record the blocker durably on the issue, flip its ledger row, and move to the next item. The human resolves blockers out-of-band; a later run picks them back up.

This is per-issue only. A **queue-wide** failure (auth/token expiry, lock contention, a usage pause) still stops the run — that distinction lives in SKILL.md Step 5, not here.

## What counts as a per-issue blocker

These conditions mark-and-continue instead of stopping the queue:

| Blocker type (marker tag) | When |
|---|---|
| `scope-ambiguous` | the fix balloons past the issue's stated scope and the right cut is a judgment call |
| `scope-increase` | the real fix is strictly larger than the issue asks (extra files/behaviour) — see the split rule below |
| `pick-blocker` | a dependency means another issue must land first, or the change is irreversible/high-stakes (schema/data migration, security/authz, a public contract) needing human sign-off |
| `root-cause-diverges` | grounding shows the root cause is ambiguous, or diverges from what the issue claims |
| `human-gated` | the author **declared** the gate — the issue's `Execution.HITL / AFK` (or, in `--from-rfc` mode, the Task-Breakdown row's `HITL/AFK` cell) resolves to gated. Read it in Step 2 and honour it; do not re-derive whether the gate is warranted |

The merge gate staying red after a reasonable fix attempt is **not** a blocker type of its own — it is either a `root-cause-diverges` (the fix is wrong) or a `pick-blocker` (infrastructure or a dependency). Classify it, do not invent a sixth tag.

> **Resolving the tag.** `--from-rfc` reads the RFC table *directly*, and RFCs spell this field several ways. The **leading-token rule, its token table, and the fail-closed default are single-sourced in the contract** — the Task Breakdown section contract of the `/plan:tech-design-doc-writing` skill, its "HITL/AFK tag" bullet. Read it there and resolve from it; do not keep a second copy here, because a partial copy is how this gate goes inert. Two consequences worth stating at the honouring site: `run-time-gated` resolves **autonomous** (the operator is the run-time gate), and an unresolvable cell fails **closed** to gated.

> **`human-gated` vs `pick-blocker`.** Both end in a human reply, and the difference is who decided. `pick-blocker` is the loop's *own* judgment that a change is irreversible or high-stakes. `human-gated` is the **breakdown author's** decision, made at design time and written into the row — so it needs no re-derivation and is not subject to the build-now bias below: an unstated-but-tagged gate is honoured on the tag alone. It is the one blocker type that is evidence-bound **by construction** — the tag sits in the issue body or the RFC table, a git/GitHub-checkable artefact, so it can be neither self-granted nor self-waived. If grounding *also* finds a real blocker, record that one instead; the tag is a floor on human involvement, not a ceiling.

> **`waiting` (integration drain) is NOT a blocker — do not conflate it with `pick-blocker`.** In `--integration-branch` mode, an ordinary slice-on-slice `Depends-on` that has not yet merged onto integration parks the row as **`waiting`** (SKILL.md Step 1 / run-ledger.md): no marker comment, no `Status=Blocked`, no grounding subagent spent — it **auto-promotes** the moment its deps land, needing no human reply. `pick-blocker` is reserved for a **real human-sign-off dependency** (irreversible/high-stakes — schema/data migration, security/authz, a public contract). A mergeable chain parked behind `pick-blocker` would strand it behind the human-reply resume rule below; an ordinary dependency is `waiting`, full stop.

### A blocker must be evidence-bound (not self-asserted)

Because don't-stall turns "stop" into "skip", marking an issue `Blocked` is the escape hatch — and an escape hatch grantable by self-assertion is gameable (an agent that finds the work hard can cry "ambiguous" and move on). So bind it: **a `scope-ambiguous` or `root-cause-diverges` marker is invalid unless its `Grounding:` field cites the specific `file:line` and the concrete fork that genuinely cannot be resolved from the code, a sibling, an RFC, or the issue body.** "It feels unclear / I am not sure / it looks risky" is **not** a grounded blocker — if grounding produced no specific unresolvable fork, it is not a blocker: **proceed with the intended scope (build-now bias).** This mirrors the anti-fear-descope guard below: when in doubt, the default is *do the work*, not *block it*. A `pick-blocker` is bound by its nature (the named dependency / the irreversible operation is the evidence); a `scope-increase` is bound by the follow-up issue it must file; a `human-gated` is bound by the tag itself, which lives in the issue body or the RFC row rather than in the agent's judgment.

## The marker comment (post exactly once per blocker)

Post a single structured comment on the issue. It carries a **stable HTML marker** so a later run can find it deterministically, the **blocker type**, the **grounding result** (what the subagent actually found, file:line), and the **exact human input needed** to unblock — phrased as a question the human can answer in one reply.

```markdown
<!-- ship-queue:blocked v1 -->
**ship-queue blocked — `<blocker-type>`**

**Grounding:** <what the grounding subagent confirmed against current code — root cause, file:line, why it can't proceed autonomously>

**Needed from you:** <the one concrete decision/input that unblocks — a scope cut, a design call, a go-ahead on an irreversible change>

_Recorded by /queue:ship-queue. **Reply to this thread** with the answer to resolve (a body edit alone will not unblock — the next run needs an attributable human reply that postdates this marker)._
```

Then:
- **Set `Status = Blocked`** (when `github_project` names a board) via the `/ship:github-issues` field flow (it owns the project-item mutation + the `Blocked` option ID — do not hand-roll the GraphQL here).
- **Record the blocker in the ledger row** (`run-ledger.md`): `blocker = <type>`, `status = blocked`.
- **Continue to the next queue item.** Do not stop, do not retry in a loop.

**Never double-post.** Before posting, scan the issue's comments for `<!-- ship-queue:blocked v1 -->`. If one already exists, this is a re-encounter on a resume — apply the resume rule below instead of posting again.

## Scope-increase — split, don't silently expand

When the fix is strictly larger than the issue asks:

1. **File a follow-up issue** for the **extra** scope only (via `/ship:github-issues` — its conventions, labels, fields), cross-linking the original.
2. **Proceed with the originally-intended scope** in this run — ship the PR that closes the original issue, leaving the extra scope to the new follow-up.
3. Only mark the original `scope-increase`-blocked (rather than shipping it) if the intended scope **cannot stand alone** without the extra. If it ships cleanly on its own, that is not a blocker — ship it and let the follow-up carry the rest.

Silently expanding the diff to cover the extra scope is the failure this prevents: the PR then no longer matches the issue a human approved.

## Anti-fear-descope guard

Descope **only when it buys something concrete** — a smaller blast radius, an isolatable change that ships sooner, a genuinely separable concern. "It looked risky / I got cautious / it felt safer to do less" is **not** a reason. When descoping has no concrete benefit, **proceed with the intended scope** (build-now bias — the issue was author-approved at this size). If you are unsure whether a cut has a benefit, it does not — keep the scope.

## Resume — idempotent re-encounter

A later run (Step 1 precheck / Step 6) that finds an issue already carrying `<!-- ship-queue:blocked v1 -->`:

- **Read the marker's timestamp**, then look for a resolving signal that is **all three** of: (a) *postdates* the marker; (b) comes from a **human author other than the run identity** — the marker is "Recorded by /queue:ship-queue", so a comment authored by the same bot/run login **never** counts as resolution (that is the self-unblock the agent must not grant itself); (c) **explicitly answers the "Needed from you" question** (a +1, a "thanks", or a question back does not resolve). If all three hold, **pick the issue up** — re-ground from the current issue (it may have changed), clear `Status` back to `In Progress`, **quote the human's resolving text in the ledger/PR as the binding evidence** (not "the body now disambiguates"), and ship. The stale marker stays as history; do not delete it.
- **A body-edit with no attributable human reply does not self-resolve.** If the only postdating change is an issue-body edit (no human comment answering the ask), keep it `Blocked` and **surface it to the operator** rather than deciding for them that the body "now disambiguates" — that judgment is exactly the self-grant the human gate exists to prevent.
- **Otherwise skip again** and leave the marker untouched — no second marker, no `Status` change. The issue stays `Blocked` until a human acts.

**A `human-gated` marker is discharged by its resolving reply, and the discharge lapses if the slice changes.** This type needs its own rule because its trigger lives in a durable artefact a human comment does not edit: Step 2 re-reads the tag on every re-ground, so with no discharge the slice re-blocks forever while "never double-post" forbids a second marker.

So a qualifying resolving reply (all three conditions above) **discharges the gate**, and Step 2's tag-read skips a slice whose `human-gated` marker carries one. **The discharge is scoped to what the human approved:** it holds only while the slice's source of truth is unchanged since the reply — the issue body for a task-brief issue, the RFC row's last-touching commit in `--from-rfc` mode. If the source changed after the reply, the discharge **lapses** and a fresh marker is posted quoting what changed; that is the one case "never double-post" permits a second marker, because the human approved a different slice. Without this, one "go ahead" would permanently un-gate a slice against an arbitrarily different build.

Quote the reply in the ledger and PR as the binding evidence. The tag itself never changes — it records a design-time decision, and re-tagging is `/plan:task-breakdown`'s call, not the drain's.
