# Design Doc Reference — Workflow Mechanics

The cross-section mechanics of the decision workflow, plus the shared blocks the per-section files point at (data-model conventions, rounding-out concerns, slicing examples). **Per-section guidance lives in [sections/](sections/), not here** — this file is the workflow, not the sections. Read [SKILL.md](SKILL.md) first.

---

## The Decision Workflow — deep mechanics

SKILL.md states the loop: per section, draft → classify each item (already-decided / derivable / open-fork) → grill the open forks → record in the Decisions Log → don't pass a fork unanswered. Here is how to run it well.

### Finding the real forks

After drafting a section, re-read it adversarially: *where did I make a choice the PRD did not make for me?* Those are candidates. Filter with the real-fork test (SKILL.md). The most common real forks by section: the data-model write pattern / key / JSONB bound (§6); the API shape and error semantics (§6); every applicable concern (§7) until the human confirms; the flag defaults + ungate criteria (§10); the rollout order + rollback (§9).

### How to ask — and how not to

Good grilling questions are *pointed and grounded*, and **printed in chat** — never a multiple-choice tool. Compare (the concrete details are invented for illustration; copy the *shape*, not the content):

- Weak: "How should we handle scale?"
- Strong: "The PRD joins `order_events` per order at request time. At a 5k-order customer over 90 days that's ~5k JSONB lookups per page load. Do we (a) compute at query time, (b) materialize a daily rollup, or (c) cap the window? I lean (a) for V1 — no stored state to backfill, flag flip stays reversible — but it forks on whether large orgs are in the pilot."

**Print the question + the genuine options + your recommendation and its reason + an explicit "or give me your own take."** Do **not** use `AskUserQuestion` / a multiple-choice surface — the author usually wants to add nuance or context, not pick a chip, and a forced choice loses that. Mark your recommendation every time; a question with no lean makes the human do the analysis you were supposed to.

**Match the register to the reader.** The Strong example is for an *engineer* (`order_events`, JSONB are fine). For a PM, strip the internals and ask in product terms ("a fast-to-build option that's slower for big teams, vs a slower-to-build option that stays fast — which matters for the pilot?"). Two hard rules: never paste internal tool/rule/skill names into a question (it's a UX surface); one sharp question beats five soft ones (many small questions = you're grilling on trivia).

### The autonomous / AFK path

The workflow assumes a human to grill. The UNRESOLVED path is **only** for a run where prompting is *structurally impossible* (a cron / headless / non-interactive invocation with no channel to ask) — being mid-task or the human being slow is not that. When the run genuinely cannot ask: make a provisional pick, record it in the Decisions Log `Status: UNRESOLVED (NEEDS HUMAN)` with options + reasoning, carry it into §12 Open Questions. The review gate FAILs a fork resolved *silently*, and requires open forks to be **surfaced** (a Decisions Log row + an Open Questions entry). A surfaced `UNRESOLVED (NEEDS HUMAN)` is fine to take to *review* (an RFC with open questions is reviewable) — but `/queue:ship-task` blocks *implementation* until it's answered. So the gate catches the silent picks, not the honest open ones.

### The Decisions Log — worked example

The single record of decisions **and** alternatives ("Options considered" is the alternatives). Rows are illustrative — they show the format, not content to reuse:

```
## Decisions Log

| # | Decision | Options considered | Choice | Why (+ trade-off) | Decided by | Status |
|---|----------|-------------------|--------|-------------------|-----------|--------|
| 1 | Delivery-time anchor | true `delivered_at` vs `shipped_at` proxy | true `delivered_at` if stored, else descope | `shipped_at` includes orders that were never delivered (wrong number); accepting a dependency on the carrier feed | human | UNRESOLVED (NEEDS HUMAN) — needs a stored-payload check |
| 2 | Warning thresholds | guess from cross-account stats vs calibrate from observed | ship suppressed, calibrate after 4-6 wks | cross-account averages mismatch within-account ratios; leaves room to ungate later (future-compat) | human | decided |
| 3 | Compute site | query-time vs stored ETL | query-time | flag flip stays reversible, no backfill | agent (obvious) | decided |
```

Row 3 was obvious — one line, no question. Row 1 is a genuine fork blocked on a fact to **verify** (a check of what the stored vendor payload holds), not assume. The load-bearing rows (1, 2) carry the **trade-off accepted** and, where relevant, whether the choice **leaves room for the known next step** (future-compat). After implementation, the decisions that generalise beyond this feature graduate into ADRs (`/plan:adr`); keeping the Log light is what stops a later `/simplify` pass from re-opening a deliberate choice.

---

## Data-model conventions (referenced from sections/lld.md)

Frequent §6 forks — start from access patterns, design the schema to serve them, then:
- **Naming consistency** — check column names against existing tables in the same DB; don't coin a new term for an established concept.
- **Stable identifiers in keys** — uniqueness constraints and storage paths use immutable IDs, never human-readable names that change; keep display names as separate refreshed columns.
- **Write pattern** — last-write-wins (full overwrite), append-only (immutable rows), or incremental assembly (different writes populate different columns; NULL = "not yet"). For incremental assembly, every upsert preserves existing values (no partial-write blanking).
- **Cross-platform field mapping** — when normalizing multiple vendors, an explicit column → source-field-per-vendor table; flag fields absent on some vendors.
- **Server vs client state** — never combine server lifecycle flags (`is_latest`, `SUPERSEDED`) with client intent (`pinned`, `dismissed`) in one column; split them (different owners, different write paths).
- Don't denormalize before you have evidence of a performance problem.

---

## Rounding-out concerns (referenced from sections/concerns.md)

Raise where relevant, no boilerplate:
- **Security** — auth level on every new RPC, input validation at the trust boundary, secrets from a secret manager not literals.
- **Reliability — the failure-mode worksheet** — for each external dep (DB, cache, queue, vendor API): down 5 min? 10x slow? returns garbage? blast radius?
- **Cost** — compute/storage/third-party-API at expected load; cost per business unit; linear or worse with load?
- **External-API integration** — polling-only when the vendor supports webhooks? (webhook-primary + polling-fallback is standard.) Rate-limit scope (per-org/user/app)?
- **Operational safety (async/queued work)** — retry policy (don't inherit a queue framework's default retry count for expensive ops), rate-limit on user-triggered expensive actions, dedup of in-flight tasks, HTTP timeouts, a staleness reaper, staggering for multi-tenant crons.

---

## Slicing — worked examples (referenced from sections/task-breakdown.md)

A **slice** is a unit of behaviour change that crosses a layer boundary and can be asserted in isolation — input to observable output through the real path, not "the DAO method" alone but "the DAO method wired far enough to assert the number it returns."

Illustrative slice table (invented; model the columns, not the rows; the skill cells are placeholders for whatever skills domain routing finds):

```
## Task Breakdown

| # | Slice | Layers crossed | Demoable proof | HITL/AFK | Depends-on | RFC anchor | Implementing skill |
|---|-------|----------------|----------------|----------|------------|------------|--------------------|
| 1 | Order-fulfilment-time DAO + RPC | DAO → handler | integration test: fixture orders → expected median hours | human-gated (first metric, wrong-number risk) | — | §6, §7.1 | `/<data-access skill>`, `/<API skill>` |
| 2 | Breakdown table behind flag | RPC → frontend | flag ON in dev, table shows the rows | autonomous | 1 | §6, §10 | `/<frontend skill>` |
| 3 | Ratios emitted as Prometheus metrics | handler → /metrics | `grpcurl` + scrape `/metrics`, assert gauges | autonomous | 1 | §7.2 | `/<observability skill>` |
```

**"Demoable" is not a screen.** For backend, the proof is: an integration test through the real path; an operational job's READ mode that prints what it would write; a `grpcurl` against the running service; or an ingest-to-table assertion (the ingestion path writes the expected rows). A frontend slice can demo via a dev render; a backend slice needs one of those.

**Not everything is a slice** — these prove differently, don't force the mould: a performance optimization → before/after benchmark; a migration → symmetric up+down + the schema snapshot regenerated + diff reviewed; a refactor → existing suite stays green; an infra change → deploy smoke.

**HITL vs AFK** — about where a human *decision* sits, not whether review happens (the reviewer panel runs regardless). Human-gated = an explicit human decision (approve the design, or the diff before merge) — first emit of a metric, a schema change, a security path, anything the Decisions Log flagged load-bearing. Autonomous = the gates suffice, no decision pending. Set during slicing, human-overridable. This tag is what `/queue:ship-task` reads to decide what it can run unattended.

---

## Domain-specific adaptations

The sections cover backend services. For other domains, also cover: ML/AI (data pipeline, feature engineering, eval, drift); data pipelines (lineage, schema evolution, idempotency, backfill, freshness SLAs); frontend (component architecture, state, perf budget, accessibility, all UI states); mobile (offline-first, old-app-version compat); infra/platform (developer experience, multi-tenancy, migration path, deprecation).
