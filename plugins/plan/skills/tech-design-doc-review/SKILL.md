---
name: tech-design-doc-review
description: >-
  Reviews a tech design doc in the rfc_dir folder before a human does, and changes nothing. It
  reads every section as a newcomer would, checks that each decision is recorded with the options
  it rejected and that the Task Breakdown is usable, applies each section's review checks, looks
  for common AI writing failures, and re-derives the numbers. It reports PASS, SCOPED PASS, NEEDS
  WORK or FAIL. Use when an RFC is ready for review.

---

# Skill: Design Doc Review

Validates an RFC against the design bar `/plan:tech-design-doc-writing` defines and against AI failure modes. Run AFTER writing, BEFORE human review.

For writing guidance use `/plan:tech-design-doc-writing`; for ADR-vs-RFC see `/plan:adr`. Once this review passes, `/plan:task-breakdown` builds the grounded, machine-consumable Task Breakdown the shippers drain.

## How to invoke
```
/plan:tech-design-doc-review <rfc_dir>/my-design.md
```
No path → the most recently modified `.md` under the RFC directory:

```bash
RFC_DIR=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get rfc_dir '${user_config.rfc_dir}')
```

## Review process

Read the whole doc — but **size it first** (`wc -c`; ÷4 ≈ tokens) and **page it** with `offset`/`limit` (or per-`##` ranges) whenever it is anywhere near a single read's token ceiling; see the ceiling in `/plan:tech-design-doc-writing`'s **Budget** section. A doc past it truncates or hard-errors mid-read and the pass then silently grades a fragment while reporting whole. State the line count you actually covered. A comfortably small doc reads in one shot — the point is that the size is *checked*, not that paging is a ritual. Then run the **fresh-reader pass** (below — it is a mandatory phase, not optional), and evaluate three families, reporting **PASS / WARN / FAIL** with line references:
1. **Decision-Workflow Integrity (D1–D6)** — the harness gates; a polished one-shot draft no human decided on fails here. Highest signal — check first.
2. **Per-section Review hooks** — for each section present, apply the **Review hooks** defined in that section's `${CLAUDE_PLUGIN_ROOT}/skills/tech-design-doc-writing/sections/<x>.md`. That file is the single source — read it, don't reinvent the gate (this is what keeps writer and reviewer from drifting).
3. **Cross-cutting AI-quality** — the failure modes that aren't tied to one section.

A doc can read beautifully and still fail family 1. Lead the report with the D-checks.

Two further passes are conditional, not part of the three families: **re-derive the conclusions' numbers** when the doc's conclusions rest on numbers it computed, and the **drift re-read** after any readability rewrite round. Both are below, before the verdict.

## Fresh-reader pass — cold-read each section (mandatory)

The single highest-leverage phase — it makes the readability/grounding bar the default rather than something a human invokes by hand. Grade against the rubric, whose governing principle is *the human is the last reader, not the first*: a readability or grounding comment a human would add on this doc is a defect this pass must catch first.

- **How.** Split the doc into section ranges (roughly one per top-level `##`, grouping tiny ones). For each range, do a **cold read** as an engineer who did **not** write it and has **not** read the rest of the doc, grading against `${CLAUDE_PLUGIN_ROOT}/skills/tech-design-doc-writing/rfc-readability-rubric.md` — the shared substance/structure/grounding bar. Also ask *does this section need deepening* (a deferred affordance with no rationale, a claim with no ground). Realize it as **one fresh subagent per section range in parallel** when you can spawn subagents (true independence, and it scales to a long RFC); when you are already running as a leaf agent that cannot spawn them, do the same cold-read directly, range by range — the fan-out is the mechanism, the *fresh per-section cold-read against the rubric* is the requirement.
- **What it grades.** The rubric's cold-read / structure / lexical / grounding / deferred-affordance items (the rubric holds the exact triggers). A dense paragraph a fresh reader cannot restate, a claim-dump that wants bullets, an inline mapping that wants a table, stacked bold run-ins that want headings, an overloaded domain word, a repeated reassurance, and — the acute ones — an **un-grounded ownership/schema/type claim** (verify against the DI wiring, the data-access code, the schema snapshot, and sibling tables, not the doc's own logic) are each a **WARN**.
- **Where the findings land.** Report them under **Fresh-reader pass** in the output (below). They compose with, not replace, the section hooks (Family 2) and cross-cutting AI-quality (Family 3): a finding tied to one section's rubric slice is also its section hook; the cross-section readability/grounding items are this pass's own. Don't double-report the same line — attribute it to the most specific home.

## Family 1 — Decision-Workflow Integrity

Apply by **applicability** — a migration/refactor RFC has different obligations than a net-new feature (each check says how).

### D1. Decisions Log — present, populated, and the alternatives record
- A `## Decisions Log` section? A design that made any non-obvious choice with no Log → **FAIL** (the catch-all). A genuinely fork-free change (trivial config bump, pure rename) may state "no real forks" in one line; that holds only if the doc designs no hard-to-reverse or genuinely-forking decision — schema, stored enum, key, API/proto contract, wire boundary, new DB path, **or a non-structural fork** (an algorithm, a numeric threshold, a retention/concurrency setting, a rollout strategy). If it designs any, the one-liner is itself a silently-resolved fork → **FAIL** (list illustrative, not exhaustive). Check against what the doc actually designs.
- Empty/placeholder Log on a design that clearly made choices → **FAIL**.
- The Log **is** the alternatives record — "Options considered" per row. There is no separate Alternatives section to require; absence of alternatives only matters if a real fork has no options listed → **WARN**. (Do **not** flag "No Alternatives section.")
- Load-bearing rows name the **trade-off accepted**; rows with a choice but no rationale → **WARN**.

### D2. Unresolved forks — surfaced, not buried
- A genuine fork resolved silently (no Log row, no rationale) → **FAIL**.
- `UNRESOLVED (NEEDS HUMAN)` rows carried into §12 Open Questions with an owner? Present but not carried → **WARN**. Open forks are fine to ship for review; burying them is not.
- **Each §12 row carries a recommended answer** — what you would do, and what changes if it flips — so the author confirms in one word instead of re-deriving the analysis. A row that only poses the question → **WARN**. Rows that grounding could have settled (a fact checkable against the code, the schema, or a real run) should have been settled rather than asked → **WARN**, and say which check would close it.
- **Nudge toward zero open rows at merge.** Open questions are expected mid-review; the target state when the RFC merges is none left, so the Task Breakdown is unblocked on landing. Report the surviving §12 rows as an explicit closing list — for each, whether it needs grounding (name the check), rehoming into future scope, or a one-word confirmation from the author. This is a **nudge, never a FAIL**: some rows genuinely need a conversation with someone else on the team, and holding the doc hostage to those helps nobody.
- **A row may only leave §12 by closing, never by deletion.** "Zero open rows" is cheapest to reach by quietly dropping a row, and the nudge above supplies the motive — so every row present in an earlier revision must resolve to a Decisions Log entry naming *how* it closed (grounded, with the check named; rehomed, with the link; or author-confirmed). A row that disappeared with no such trace is graded exactly like a silently-resolved fork → **FAIL**. Without this the target is satisfiable by deletion, which is the opposite of what it asks for.
- A "decided" row whose rationale is a hedge ("could be X or Y", "TBD during implementation") → **FAIL** (undecided masquerading as decided).
- **Reaction-not-decision signal (advisory WARN).** The workflow is per-section: forks are put to the human *as the section is drafted*, not back-filled after a finished draft. A Decisions Log that reads as back-filled — every row in one late batch, rationale that's reactive rather than a fork genuinely put to the human — *signals* the loop may have been bypassed (free-drafted, then justified). The doc alone cannot prove this, so it is a **WARN** a human reviewer weighs, never a self-gradeable FAIL. It does **not** change the severity of the missing-options condition, which is graded where it already lives: a fork **with** a Log row but empty options-considered → **WARN** (D1); a fork with **no Log row at all** → **FAIL** (the silent-fork rule above). This signal only flags the back-filled *pattern* on top of those — don't escalate a D1 WARN to FAIL here.

### D3. Front-load concerns — the applicable seven addressed
For each concern that **applies**, addressed with a real answer (not boilerplate)? A *defensible explicit skip* passes; a skip line is **not valid** if its stated reason doesn't hold against what the doc designs ("Observability: N/A" doesn't hold if the doc adds a prod path that can silently misbehave) — an invalid skip is treated as a silent omission **at that concern's own severity** (below). The full gate per concern is in `${CLAUDE_PLUGIN_ROOT}/skills/tech-design-doc-writing/sections/concerns.md`; the FAIL-level ones:
- **Data/analytics correctness** — emits a number with no statement of the *right* number / how it's verified → **FAIL** (a fixture test is one way; do **not** mandate a golden-JSON ritual).
- **Tenant isolation & access scope** — a new DB path with no tenant-scoping treatment → **FAIL**; a missing decision on which access dimensions (plan, entitlement, seat) apply, where the product has them → **WARN**.
- **External / cross-service deps** — an unconfirmed data dependency presented as settled → **FAIL**.
- **Decision ownership** — a behaviour-shaping value (threshold, filter, vocabulary, window, cadence, default) introduced with no statement of *who is entitled to decide it* → **FAIL**; a promoted knob/setting with no enumerated reach set or no named consumer → **FAIL**. "Domain fact" asserted with no reason → **WARN**. Deferring is a legal answer when recorded in the Decisions Log.
- **Output quality** — a design whose value rests on **graded** output (a summary, a classification, a detector, a recommendation, a ranking — output where no fixture can assert a right answer) → **FAIL** on **either** of two independent defects: **no quality bar**, or **a bar with no evaluation method / no baseline** (an unmeasurable bar is as unusable as none, so grading the pair conjunctively would pass "the bar is useful summaries, method TBD"). Apply both discriminators before firing: output with a **computable** right answer is concern 1, not this one (a deterministic sort by a computed score is a number, not a judgment), and a design that only **moves, caches, or stores** someone else's graded output — a transport, a cache, a schema change — does not trip it either. A bar whose achievability rests on neither cited POC evidence nor a quality-spike slice that gates the LLD → **WARN**; a POC cited as a link or a name with no sample size and no measured number → **WARN**; no stated behaviour for output that misses the bar, or no ongoing quality watch where it will drift → **WARN**.
- **Observability** (prod-facing, no real-time signal → **WARN**; data flowing downstream with no downstream watch → **WARN**) and **Scale** (grows with scale, no sizing/extrapolation → **WARN**).
- Definition-of-done / GA is **not** a separate concern — check it via §3 (a measurable success signal) and §10 Feature Flags (a measurable ungate criterion).

### D4. Task Breakdown — present and machine-consumable
- A net-new feature with no `## Task Breakdown` → **WARN** (a material gap — per-check grades stay PASS/WARN/FAIL; the verdict logic rolls a material WARN up to a NEEDS WORK verdict).
- Each slice carries: a **demoable proof that is not assumed to be a screen** (integration test / operational-job READ mode / `grpcurl` / ingest-to-table assertion), a **HITL/AFK tag**, **depends-on**, an **RFC anchor**, and an **implementing skill** (or a one-line reason it has none — a refactor / operational job) → missing fields → **WARN** (these are what `/queue:ship-task` consumes for a single slice and `/queue:ship-queue` for the dependency-ordered drain). A skill omitted on a slice whose layers cross a surface that **has** a matching skill — one available in the session or in the repo's own `.claude/skills/` whose description covers that surface → **WARN** (the no-skill reason must hold against that list, not be self-asserted).
- Covers **supporting work** (tests, observability/dashboards, flag wiring, operational jobs, and the quality-evaluation harness where D3's output-quality concern applies), not only core code → only-core → **WARN**.
- **The HITL tags stand up to the two RFC-answerable questions** — every human-gated slice names a judgment the automated gates cannot make (not "read the diff", which the merge gate covers on every slice and `/review:review-panel` on every code slice), and none is gated on a question the Decisions Log already answers, *except* a tag the Log records the author setting, which is human-overridable and exempt → either missing → **WARN**. Also flag the under-gated direction from what the document shows: an autonomous slice whose RFC anchor describes an expensive-to-discover-late change (a shared contract, a migration against existing rows, an auth path) with **no** guardrail named in its proof → **WARN**.
- **The guardrail-conversion checks apply only once `/plan:task-breakdown` has run** — i.e. when the table carries a `Ground-verified:` stamp. Then: the breakdown reports **both** directions (the gated count with its reasons, and each converted slice with the guardrail behind it, a guardrail that is another slice carrying a real `depends-on` edge) → missing → **WARN**; and **resolve every guardrail the table cites** — a `file:line` that does not exist, or whose line is not an assertion, is graded as no guardrail → **WARN**, one read per citation, and the only thing between a cited guardrail and a self-granted conversion. On an **unstamped** table none of this exists yet, so do not grade it — conversion is the builder's third question and it runs after this review. Do **not** ask the reviewer to prove a guardrail is *absent* from the codebase either; resolving a citation and proving an absence are different reads, and only the first is owed here.
- **Report the table's provenance** — stamped in the contract's fixed form (`sections/task-breakdown.md` is the authority for that form), or first cut, in which case name "run `/plan:task-breakdown` before draining" in the Top 3 Actions. Always state which; that statement is the deliverable, since this review runs before hardening and an unstamped table here is normal rather than a defect. **WARN** when a stamp is present but does not check out — its SHA does not resolve or is not an ancestor of the RFC's branch, `<N>` disagrees with the table's own edge count, or a spot-checked edge from its per-edge record does not hold at that SHA. A stamp that does not check out is graded as no stamp: a false one converts unknown provenance into "verified" for the operator deciding whether to drain. (The **unstamped-at-drain** case cannot be graded here — this skill sees a doc path and has no way to know a drain is imminent — so it is enforced where it is observable, as a `--from-rfc` precondition in `/queue:ship-queue`.)
- **No PR-strategy / ticket / estimate leakage** into the RFC → **WARN**.
- Non-slice work (perf / migration / refactor / infra) not forced into the slice mould; it proves differently (benchmark / symmetric up+down + snapshot / green suite / deploy smoke). Forcing fake slices, or a migration with no down + no snapshot → **WARN**. Do **not** fail non-slice work for lacking a Task Breakdown of slices.

### D5. PRD-anchoring — no silent drift
- Do the goals and scope **trace to the PRD**? If the design diverges from the PRD, is the divergence surfaced (a Decisions Log row / an Open Question), or papered over? A design that silently contradicts or drifts from the PRD → **WARN**, escalating to **FAIL** if a load-bearing goal contradicts the PRD with no acknowledgement. (No PRD for an eng-initiated RFC is fine — skip this check, note it.)
- A PRD path **cited but unresolvable** (the doc references a PRD that does not exist) → **WARN** — distinct from no-PRD: the author believes one exists, so the citation is either unwritten or stale and must be settled, not leaned on.

### D6. Premise & concept-impact — was the right problem even chosen
*Applies to a net-new / product-facing RFC; skip (note it) for a pure refactor / migration / infra change.*
- **Premise** — does the RFC show it checked the ask **does not already exist** (an extension of a built system, not a greenfield duplicate) and that it designs the **full problem, not an unintended subset**? A product-facing RFC with no sign of this premise check → **WARN** (a well-built *wrong-or-duplicate* design is the costliest miss).
- **Concept-redefinition ripple** — if the RFC **redefines a core concept** (e.g. `customer` now meaning a person *or* a business), does it enumerate the shared artifacts that encode the old meaning (architecture docs, root/area `CLAUDE.md`, `.claude/rules`, other RFCs) as explicit follow-up? A redefinition with no ripple plan → **WARN**.
- **Risks grounded** — a §12 *code-level* risk asserted but never checked against the code / a real run → **WARN**; a genuinely external risk (vendor / product / rollout / adoption) kept with an owner + deadline is fine.

## Family 2 — Per-section Review hooks

For each section the RFC contains, open the matching `sections/<x>.md` and apply its **Review hooks** verbatim — that file is the contract the writer used. Map:

| RFC section | Hooks live in | Headline gate |
|---|---|---|
| §3 Goals/Non-Goals/Success | `sections/goals.md` | technical-not-business goals; non-goals split complete-vs-deferred; a measurable DoD |
| §4 HLD | `sections/hld.md` | a data-bearing diagram (ascii or mermaid, whichever displays best); reuse-vs-new justified; new infra flagged; cadence arithmetic for a scheduled per-org fan-out |
| §6 Detailed Design (LLD) | `sections/lld.md` | package table; index-per-query plus each read's cost (bound columns, call rate); stable IDs (FAIL); write-pattern + partial-write (FAIL); JSONB-proto; concurrency; **back-compat additive-or-breaking (breaking w/o migration → FAIL)** |
| §7 Cross-Cutting | `sections/concerns.md` | the seven concerns (also D3) |
| §8 Testing | `sections/testing.md` | automated local+deploy validation (not manual-by-default); concrete scenarios; test-prep |
| §9 Rollout | `sections/rollout.md` | phased rollout; rollback per phase; readiness before launch |
| §10 Feature Flags | `sections/flags.md` | each flag has default + **measurable ungate criteria (missing → FAIL)** + rollback; the repo's real per-org-then-global flag mechanism |
| §11 Operational Jobs | `sections/operational-jobs.md` | READ + EXECUTE modes; READ-before-EXECUTE for bulk; idempotent/resumable |
| Task Breakdown | `sections/task-breakdown.md` | (also D4) |

Light sections (Header name-inflation, Terminology/Key Nouns defined-once + concept-only + placed-first-when-needed, Open Questions owner+deadline) are checked inline below.

## Family 3 — Cross-cutting AI-quality

- **Right doc type** — a short decision with no detailed design → should be an ADR (`/plan:adr`); mixes general + feature-specific decisions → flag for ADR extraction.
- **Problem statement** — one sentence, no solution-words; concrete numbers; "what if we do nothing"; a clear trigger. A solution-masquerading-as-problem → WARN.
- **Self-containedness** — understandable from this doc alone; no undefined terms; no `...` truncated examples; every "see ADR-N" has a 1-line inline summary.
- **Consistent terminology & noun definitions** — one term per concept; identifiers defined once; field names consistent with existing tables. Terminology entries are **concept-only** (a parameter, decision, or codebase realization inside a definition → WARN); when the Problem leans on domain terms, the section is **placed first, before §2**. The **inverse** — one word for two concepts (an overloaded in-domain word like `schema`/`cursor`/`config`/`state` used in a sense that collides with a second in-domain meaning, undisambiguated) — is graded in the Fresh-reader pass (rubric → *Lexical precision*) → WARN.
- **Invented terminology / team vocabulary** — a *metaphorical or jargon* coinage used where a plain descriptor or an existing team term would serve ("reaper" for a cleanup job, "trait" for a column), or a name colliding with an established team term → WARN. A genuinely new concept is *expected* to introduce a name — that is not the target; the target is evocative jargon a first-time reader cannot map to the team's vocabulary. Flag the coinage and ask for the team's word. (The writing skill's Prose-register block front-loads this; this is its review-side gate.)
- **Intra-section contract consistency** — where one section carries **both** a formal block (pseudocode, a state/transition table, a contract signature) **and** prose describing the same case or its outcome, the two must agree. The high-signal tell is a hedged "X can never happen" / "that case is rejected" **rationale in the prose that the section's own formal block contradicts** (the pseudocode produces X). A false rationale shipped this way grounds the implementer against the wrong contract → **WARN** (the reviewer flags the disagreement; the author resolves which side is right — it rolls up to NEEDS WORK). This is the review-gate sibling of the writing skill's "do not narrate an undecided mechanism" guard: there the tell is a fork narrated as settled; here it is a *decided* rationale the section's own formal block contradicts. *(Example: an order router whose pseudocode sends a zero-total order to the refund path while the prose says a zero-total order "is rejected before routing".)*
- **Verbosity / fake concreteness** — comparison table where one option wins → collapse; prose re-explaining a diagram or DDL → cut; triple-stated info → keep one; "we will add monitoring" with no specifics → make concrete; **implementation artifacts** (ORM/mappers, file inventories, step-by-step build, verification checklists) → cut, that's a ticket not a design. The structural forms of this — a multi-claim paragraph (→ bullets), a multi-row correspondence written as an inline list (→ table), a reassurance repeated across a section (→ state once at its strongest place) — are graded in the Fresh-reader pass (rubric → *Structure* / *Lexical precision*, which holds the exact triggers).
- **Prose register** — human document prose, not agent shorthand: telegraphic fragments, arrow glyphs (`->`/`→`), semicolon run-ons, multi-concern paragraph dumps, `§`-pepper, in-doc process citations ("(Codex P1, PR #N)", "verified <date>"), or harness/skill jargon (`/verify`, bare skill names) in the **prose** → WARN. (Caveman/compression mode leaking into the artifact is the acute case.) **Exempt the Task Breakdown's `implementing skill` column** — it legitimately names `/skills` (that is the contract, not jargon); do not flag those. This is the **surface** layer; its **substance** sibling — grammatically-clean prose a fresh reader still cannot restate (assumed mental model, term used before defined, stacked bold run-ins that want headings) — is graded in the Fresh-reader pass against the rubric.
- **Naming inflation** — "Engine" for a batch job, "Platform" for a single service — flag early; names cascade into packages/protos/flags.
- **UI-state completeness** — if there's a frontend surface: empty/first-run, error, stale (freshness), in-progress, below-threshold states all specified, not just the happy path; provenance/timestamps on derived content.
- **Threshold & scaling sanity** — numeric thresholds justified (why 30?); do they scale with tenant size; JSONB/payload growth bounded.
- **Real numbers** — scale (rows/users/sizes), latency, cost present for a system at scale → missing → WARN.
- **Stale references** — file paths and ADR/RFC cross-refs resolve; references to moved or renamed paths flagged; "Phase 2"/"future" without an issue link.
- **Anti-patterns:** Fait Accompli — the design presented as already decided or built (WARN — incl. build-status markers / a done-vs-proposed split: status lives in the tracker, not the design); Happy-Path-Only — no failure modes (FAIL); Resume Builder — technology chosen for novelty rather than need (WARN); Scope Creep — design reaching past the stated goals (WARN); Missing Numbers — no scale, latency, or cost figures (WARN); Invisible Audience — no clear reader or decision-maker (WARN); The Implementation Plan — build steps in place of a design (WARN); PRD Leakage — product requirements restated instead of designed for (WARN); Undefined Semantics — states or terms whose meaning is never pinned down (WARN). "No Alternatives" is **not** an anti-pattern here — alternatives live in the Decisions Log, gated by D1.

## Re-derive the conclusions' numbers (findings-heavy docs only)

When the doc's conclusions rest on numbers it computed — an investigation write-up, a study, a census, a proposal justified by a measured yield — one lens re-derives those numbers **from the source artifacts**, not from the doc's own narration: open the query, the script, the sampled data, and recompute. A prose review grades whether the argument hangs together; only re-derivation catches the argument that is coherent and wrong, because a filter that silently drops a whole class of input yields numbers that agree with each other and with the prose, and are still false.

Keep it bounded, or it turns into a second audit:
- **Only** numbers a conclusion depends on — a headline, a comparison the recommendation rests on, a rate that gates a decision. Not every number in the doc.
- **Enumerate before you select, then cap.** List every number a conclusion depends on *first*; if that list exceeds ~8, re-derive the load-bearing ones and report the **full** list with each entry marked re-derived or not-checked. Selecting first and reporting only what you checked makes the omitted set uncountable — the same self-asserted shrink the not-applicable clause below is written to prevent.
- A number that does not re-derive is a **FAIL** — the doc's conclusion rests on it, so this is the same severity as a silently-resolved fork, and it feeds the verdict below like any other FAIL. A number you could not re-derive because its artifact is missing or unreadable is a **WARN**, named explicitly; "could not check" is never graded clean.
- **The not-applicable case is stated, not assumed.** A normal design RFC whose numbers are projections rather than computed findings does not need this pass — but say so by listing the numbers you classified as projections, so a wrong classification is visible in the report rather than hidden in a decision nobody sees. "No computed numbers here" with nothing named is the skip that lets a real finding through; those projections are then graded by Family 3's *Real numbers* item instead.

## Review rounds — where the comment-closing loop lives

**This skill does not change the doc or the repo.** Invoked as `/plan:tech-design-doc-review <path>`, it produces a report — no commits, no PR replies, no gate re-triggers. Its one write is its own round report under `.claude/triage/rfc-<doc-slug>/` (gitignored local run state, see the Regression rule below). Keep it that way: it is routinely run as a plain local validator, so any other write path here would fire in sessions that never asked for one.

Closing an author's comments on a doc PR is therefore a **separate, user-invoked** workflow, not a mode of this skill: `/ship:pr-feedback` fetches the comments across every GitHub surface, and `/ship:pr` owns the reply-and-push side. Two things from this skill feed that loop and are worth stating where they are owned:

- **The drift re-read below is mandatory after any rewrite round** the loop produces — that is this skill's step, and it runs on the rewrite delta whoever drove the rewrite.
- **Frontload the judgment calls.** Put your recommended answer in both the doc and the PR conversation, so each needs only a one-word confirmation from the author rather than a fresh analysis.

### Drift re-read after any readability rewrite (mandatory)

**Every plain-language or register rewrite round gets a fresh meaning-drift re-read over the rewrite delta, before the round is called done.** Rewriting for clarity changes wording at scale, and wording is where the meaning lives. The two shapes to hunt: a rewritten passage that reuses a term the doc defines in the opposite sense, and a freshly-written example that leans on a contract the untouched code no longer serves. Neither is visible to the person who did the rewriting.

Dispatch it as a **fresh reader on the diff of the rewrite**, not on the whole doc, asking one question: *does any rewritten passage now say something different from what it said before, or contradict something it did not touch?* This is the doc-side counterpart of `/review:review-panel`'s Step 4.5 re-review of a fix delta — same discipline, same reason.

Record it in the report's **Drift re-read** section, naming the delta you read (commit range or file set). A mandatory step whose only evidence is the agent saying it ran is self-asserted; naming the range is what makes "I ran it" checkable. A rewritten passage that now contradicts untouched text is at least a **WARN** and feeds the verdict.

## Verdict logic
- **FAIL** if any check returns FAIL (a D-check, a section-hook FAIL like a breaking change with no migration, a Family-3 FAIL like zero failure-mode analysis, or a number that failed to re-derive).
- **NEEDS WORK** if no FAILs but WARNs materially weaken the design (net-new feature with no Task Breakdown, missing observability/scale, untagged slices, PRD drift, a contradicted in-section contract, a cluster of Fresh-reader-pass readability/grounding WARNs — an un-grounded ownership/schema/type claim is material on its own).
- **PASS** only when all three families are clean or carry only cosmetic WARNs **across every section** — clean coverage, not a clean run. Coverage **accumulates across rounds**: a full three-family review followed by scoped re-checks of the fix deltas earns a bare `PASS` once nothing is open, provided the report names the rounds that composed it (`PASS — full coverage: round 1 all families, rounds 2-3 delta re-checks, no open FAIL`). Re-reading an unchanged section from scratch to "re-earn" a verdict is waste, not rigor.
- **SCOPED PASS** when this run graded a subset and coverage does **not** yet add up to the whole doc — name what it covered and what is still ungraded. A partial run cannot grant doc-wide clearance, and carrying one forward as if it could is how a doc reaches a human with two families never run.
- A **self-administered** fresh-reader pass (the leaf-agent fallback, no subagent fan-out) that *did* cover every section and family reports **`PASS (self-administered)`** — a real pass, because the fallback satisfies the requirement (a fresh per-section cold-read against the rubric) and a headless or leaf run must not be a dead end. The label is there because one agent re-reading its own doc is a weaker instrument than N independent readers: a later fan-out supersedes it, and it is worth re-running under fan-out when one is available. Incomplete coverage is `SCOPED PASS` whichever way it was graded — the two axes are independent.

## Output format
```
## Design Doc Review: {doc title}

### Coverage
Families graded: {1, 2, 3 | which subset}   Sections graded: {all §1-§N | the ranges}
Fresh-reader pass: {N subagents, one per range | self-administered}   Doc read: {N lines, paged}
Round: {N} — prior rounds: {what they covered, or "first round"}

### Summary
{1-2 sentences}

### Verdict: {PASS | PASS (self-administered) | SCOPED PASS ({what was covered}) | NEEDS WORK | FAIL}

### Fresh-reader pass
#### §{n} {section} — {PASS|WARN|FAIL}   {cold-read / grounding finding + fix}
...

### Decision-Workflow Integrity
#### D1 Decisions Log — {PASS|WARN|FAIL}   {line ref + finding + fix}
#### D2 Unresolved forks — {PASS|WARN|FAIL}
#### D3 Concerns — {PASS|WARN|FAIL}   {which of the seven apply}
#### D4 Task Breakdown — {PASS|WARN|FAIL}
#### D5 PRD-anchoring — {PASS|WARN|FAIL}
#### D6 Premise & concept-impact — {PASS|WARN|FAIL}   {applies to net-new/product-facing}

### Per-section hooks
#### §{n} {section} — {PASS|WARN|FAIL}   {finding + fix}
...

### Cross-cutting AI-quality
#### {check} — {PASS|WARN|FAIL}   {finding + fix}
...

### Re-derived numbers — {PASS|WARN|FAIL|n/a}
{when n/a: the numbers classified as projections, named}
{otherwise: per number — the claim, the artifact re-derived from, doc value vs re-derived value}

### Drift re-read — {PASS|WARN|FAIL|n/a}
{when n/a: no rewrite round in this review}
{otherwise: the rewrite delta reviewed (commit range or file set) + each meaning change found}

### Top 3 Actions
1. {highest impact}  2. {second}  3. {third}
```

Prefix any finding that a **previous round already filed and had fixed** with **`REGRESSION (round N)`** — the fix did not stick, or a later edit undid it. For that to be checkable across sessions, **save each round's report** to `.claude/triage/rfc-<doc-slug>/round-<N>.md` (gitignored local run state) and read the prior round's before filing a finding as new; without the file a later round has nothing to compare against and the prefix degrades to guesswork, so omit it rather than assert an unverified round number. A repeat that renders as an ordinary WARN/FAIL is invisible in any single report and only surfaces to a human reading several rounds in sequence. Two consecutive rounds carrying `REGRESSION` entries is a churn signal, not routine iteration — say so in the Summary and recommend simplifying the mechanism away rather than requesting another fix-and-re-review cycle.
