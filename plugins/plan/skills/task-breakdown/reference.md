# Task Breakdown — builder reference

The deep mechanics for `/plan:task-breakdown`. Read [SKILL.md](SKILL.md) first — this file carries the four pieces that need more than a step: the HITL rule, DAG-validation, the ground-verify fan-out, and the worked example.

## Why this is a separate skill

Building a breakdown *well* is a distinct, deep activity — inventory the surfaces, slice them, and then verify every dependency edge and touch-point against the real code rather than the design's assumption. Done wrong (ungrounded edges, over-gating, under-specified slices) it stalls the autonomous shipper or ships the wrong dependency order. The writing skill produces a first cut as part of authoring the RFC; hardening it into a grounded, machine-consumable graph is a separate pass with a different posture (verify-against-code, not derive-from-design), worth its own skill.

---

## The HITL three-category rule

Tag each slice by **where a human decision actually sits**, not by how risky the area feels. The failure mode this replaces is **"sensitive ⇒ gate"** — gating every auth/schema/security slice for a human eyeball, which trains the human to rubber-stamp and stalls the autonomous drain. A slice is one of three:

1. **Open decision → resolve now, then AFK.** The slice carries a choice that isn't settled yet (a name, a default, an order). The decision is a *design* act — resolve it now (in the RFC's Decisions Log, before the drain), and then the slice **builds autonomously**. The gate is the decision, not the build.
2. **Run-time-gated → build AFK.** The slice's real gate is an operator running it later — an operational job, a flag flip, a rollout step. It is **built and validated locally** AFK; nothing about *building* it needs a human pause. (READ-mode + a local validation is the proof; the run-time gate is the operator, not the merge.)
3. **Expensive-to-discover-late and uncovered → gate it.** A defect here is cheap to fix *now* and dear to fix after the drain has built on top of it: a wire contract everything depends on, a schema migration against existing rows, a security/auth path, a shared code path a regression could break. The gate is a **decision point where a human is deliberately brought in** — not "a human will look at the PR", which a base branch that merges without a required approving review does not guarantee. And it applies only where **no automated guardrail covers the defect**: that is the question step 5b asks, and a category-3 slice whose guardrail exists converts to autonomous.

**Collapse the foundation to one review.** The foundation slices (the wire contract + the schema everything builds on) do not each need a separate eyeball — they are reviewed **together, once**, when they land. One review of the foundation beats N reviews of its pieces.

The tag is what `/queue:ship-task` and `/queue:ship-queue` read to decide what runs unattended. Set it honestly and it is human-overridable.

### What counts as a guardrail (step 5b's third question)

Category 3 is the one the second pass interrogates, because it is the only tag a slice can carry by *feel* — the other two are settled by a fact (is the decision open; is the gate an operator). The question is whether the human's job can be done by a mechanism instead. A guardrail qualifies when it makes the bad outcome **impossible or loud without a human present**:

| The human was going to catch… | The guardrail that replaces them |
|---|---|
| a contract or boundary violation everything builds on | an arch test or a lint rule that fails the build |
| a migration that cannot be undone, or that mangles existing rows | a dry-run against a real snapshot plus a symmetric down-migration the proof exercises |
| a tenant-isolation or auth regression | a scoping test that asserts zero cross-tenant rows, run in the slice's own proof |
| a regression in a shared path many callers depend on | the existing suite for that path, extended to cover the changed branch |
| a defect only the deployed system shows | a deploy smoke the rollout slice runs, or a merge-gate check |

Three properties separate a guardrail from a wish. It is **automated** — no human step in its firing. It **already exists, or is a slice in this breakdown with its own proof** — a guardrail named but unbuilt converts nothing. And it **fails loudly** — a check that passes when the mechanism is absent (a test that skips when a fixture is missing, a gate that no-ops on empty input) is worse than no guardrail, because it reads green.

**Why each of step 5b's three bindings exists.** The citation is a `file:line` rather than a name because converting a tag is the cheap-looking move, and a name is not something anyone downstream opens — a location is one read for the reviewer, which is what makes the claim falsifiable instead of self-attested. The `depends-on` edge is required because the drain orders strictly on that column and a prose mention is invisible to it: without the edge, a converted slice can ship in an earlier wave than the guardrail it rests on, arriving with neither the human nor the mechanism behind it. With the edge, the drain simply parks the dependents until the guardrail lands, which is the whole protection and needs no new machinery. And author-set tags are excluded because the tag is human-overridable by contract, so a pass that quietly reverses the human's own call is not an audit.

What does **not** qualify, in the order it tends to get offered: the review panel (advisory, and it already reads every diff, so it cannot be the thing that changes a tag); the merge gate on its own for the same reason; the Codex sweep (post-PR, and legitimately absent — `no-show` / `codex-limited` are recorded as absent, never clean); care, attention, or a note in the PR description; and a guardrail that only exists in a later RFC.

**Also run it in reverse.** Walk the autonomous slices and ask which carry a category-3 defect with **no** row in the table above and no existing guardrail. Those earn a gate. Where no approving review is required to merge, the tag is where a human is pulled in *during* the build rather than a belt over a guaranteed later read — and a pass that only ever subtracts gates is not an audit, it is a ratchet.

---

## DAG-validation

Three checks on the whole graph before handoff:

- **No cycles.** Walk the `depends-on` edges; a cycle means two slices each wait on the other and the drain deadlocks. Break it by finding the real ordering (usually one edge is spurious — see ground-verify).
- **Every surface covered exactly once.** Cross the step-1 inventory against the slices: each surface has **a** slice (nothing dropped) and not **two** slices fighting over it (nothing duplicated). A surface in the inventory with no slice is the most common gap.
- **Supporting work present.** Tests, observability/dashboards, flag wiring, operational jobs, docs/terminology, rollout/runbook each have a slice (or an explicit "folded into slice N"). A breakdown that is only feature code fails here.

A clean DAG also **parses**: every slice has all the contract columns, and every `depends-on` references a slice ID that exists in the table.

---

## Ground-verify — the fan-out

Step 3 is where a plausible breakdown becomes a grounded one. Assume nothing the design asserts about *where code lives*; confirm it. Fan out to subagents (one per cluster of slices/edges) so the verification is parallel and the corrections come back as structured deltas, not prose. Each subagent verifies, against the schema snapshot + the named packages:

- **Touch-point reality** — the package/file/table exists where the slice claims; a column the slice adds is not already in the schema snapshot; a field is on the tier the slice says (a **proto** field and a **Go-struct** field are different slices).
- **Edge reality** — slice B's `depends-on: A` is real (B uses a symbol/table/contract A introduces), not coincidental adjacency.
- **Missing edges** — B reads something A produces but no edge is drawn.
- **Cross-tier skips** — an edge that crosses tiers (schema→API contract, data access→API layer, a job→its scheduler) is the easiest to misdraw; trace the actual call/read path.

Fold every correction back into the table, then (for a large or high-stakes breakdown) re-run the pass with a fresh subagent — a wrong edge misorders the autonomous drain, the costliest defect a breakdown can ship.

---

## Worked example — what grounding caught

Take a breakdown of an invented order-export RFC (slices across the API contract, schema, a background export job, the API layer, a UI page, observability, docs and rollout). The corrections that step 3 produces, each one a thing a first-cut breakdown gets wrong:

- **An internal-field-vs-contract misplacement** — an export-job field first drafted as an API contract change was an internal struct field, so it belonged in a different slice with a different proof (a unit test, not contract code generation). Tier matters: it changes the slice's layer, proof, and implementing skill.
- **A cross-tier skip dependency** — the export-job slice depended on an internal call two tiers away; the first cut drew the edge to the wrong producer.
- **A cap fold** — two slices each carried "enforce the per-order export cap"; the cap belonged in one orchestration slice, and the other depended on it. Duplication the coverage-once check catches.
- **A schema→contract edge** — a slice read a column another slice added but no `depends-on` was drawn; the drain would have built it before the column existed.

The shape to emulate: explicit slice IDs; a columnar `depends-on`; the HITL cell carrying the contract's canonical `human-gated` / `autonomous`; the implementing-skill cell always one of the three honest values; and the framing blocks around the table (execution strategy, the done+verified bar, a reviewed-together note for the collapsed foundation, and any not-a-slice pre-merge design item called out so it is not mistaken for build work).

The point is not the specific corrections — it is that **every one came from checking the code, not re-reading the design**. A breakdown's defects hide in the edges, and the edges are only true against the codebase.
