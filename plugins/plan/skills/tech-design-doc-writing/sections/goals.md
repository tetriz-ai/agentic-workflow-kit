# §3 Goals, Non-Goals & Success Criteria

**What it is** — the contract: what this design achieves, what it deliberately doesn't, and the one signal that says it's done.
**Applies when** — every RFC.

## Claude drafts (derivable)
- Candidate **technical** goals extracted from the PRD (things engineering controls and can verify at build time).
- A first cut of non-goals from the PRD's stated out-of-scope.

## Author decides (grill — printed question + your recommendation + "or your take")
- **The scope line, split two ways:** for each thing we're not doing, is it **scoped out completely** (never us / another team / not a fit) or **deferred to a future version** (V2)? The two are different promises — be explicit. *Recommend a split, ask the human to confirm.*
- **The mid/future-term lens (don't build something rigid):** what is likely to change in 6–12 months — a new vendor, a second use-case, more dimensions? Does the design leave room, or does it hard-code today's shape? *Surface the one place rigidity would hurt and ask whether to design for the bend.*
- **The one measurable success signal (the Definition of Done):** an engineering-verifiable bar — error rate under X, the metric computes right, the dashboard live, zero privacy complaints in the window — **not** a business OKR (adoption %, conversion). *Propose the signal; ask the human to confirm it's the right one.* This is the DoD; the GA-widening gate that consumes it lives in §10 Feature Flags. **When the design's value rests on how *good* its output is rather than that output was produced, the quality bar itself is the DoD** — "the job runs and the table fills" is pipeline liveness, and a design can pass it while producing output nobody would use. The bar and how it is measured are settled in §7's output-quality concern, which is drafted four sections later — so record the signal as provisional here and revisit it once §7 settles the bar, the same back-edge §10's ungate criteria already have onto this section.

## Ground in (pointers — read, don't restate)
- the PRD's goals / non-goals / success metrics

## Review hooks (what /plan:tech-design-doc-review checks here)
- Goals are **technical, not business** (a product OKR here → WARN: belongs in the PRD).
- Non-goals present **and split** complete-vs-deferred → missing split is a WARN.
- A **measurable** success signal present (the DoD) → missing → WARN.
- A design whose value rests on **graded** output whose DoD is a pipeline-liveness signal (the job runs, the table fills, the RPC returns) rather than the quality bar → WARN. The bar itself is gated in §7's output-quality concern; this hook catches the doc that states a bar there and then does not make it the success signal here.
- The mid/future-term lens addressed where rigidity is a real risk (a design that obviously won't bend and doesn't say so → WARN).
