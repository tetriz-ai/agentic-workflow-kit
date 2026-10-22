---
name: tech-design-doc-writing
description: >-
  Use when writing or restructuring a tech design document in the repo's RFC folder, set by
  rfc_dir. Also suggest an RFC first when the user is about to build something that spans several
  services, adds new infrastructure or needs design decisions. It grounds the design in the
  product requirements and the code, drafts one section at a time, asks the user at each real
  decision point, records the answers in a Decisions Log, and ends with a Task Breakdown of slices
  tagged human-gated or autonomous.
---

# Skill: Writing Tech Design Documents

Instructions for AI agents producing design docs — standard design-doc practice, adapted with AI-specific guardrails because agents over-explain, hedge decisions, and produce verbose prose no one reads.

RFCs live in the `rfc_dir` setting (default `docs/rfc`):

```bash
RFC_DIR=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get rfc_dir '${user_config.rfc_dir}')
```

**This skill runs as a grounded decision workflow, not a one-shot draft.** For each section you draft, **surface the genuine decisions as pointed questions to the human, record their answers in a Decisions Log, and only then move on** — so the human comprehends and decides rather than rubber-stamps a finished draft. The work converges *collaboratively*: where the human already decided something (in their brief or the PRD), you record it and don't re-ask; where it's a clean slate, you help them converge. Deep mechanics in [reference.md](reference.md); per-section guidance in [sections/](sections/) (loaded on demand). Read reference.md before your first run.

**Is this even an RFC?** If the work is a short decision with no detailed design, it's an ADR — use `/plan:adr` instead (it carries the ADR-vs-RFC framework).

## Phase 0 — Intake & Grounding (run once, before drafting)

However the author arrived, ground before you draft. Don't branch rigidly per entry mode — normalize to "what did I receive + what can I find."

1. **Collect every input** the author gave: a heavy prompt, a pasted dump, a PRD link, a mid-prompt mention, an existing RFC file to extend, a prior ADR to supersede — or nothing. If context is thin/absent, ask **once**, open-ended: "What are we designing? Paste the PRD link / brief / any dump — or describe it."
2. **Ground from all sources, in priority order:**
   - the author's prompt/dump — intent, and **what they have already decided**;
   - the **PRD** — if a link/path is given, read it; if one plausibly exists in the repo's product-docs location, find it and confirm. If its PR is open (unmerged), read it from the branch and **softly nudge**: "PRD #N is still open — worth merging so its citations resolve on the base branch." If the author **cited a PRD path that does not resolve**, treat that as distinct from "no PRD" — the author believes one exists, so flag the **dead citation** and confirm whether it is unwritten or moved before leaning on it. If no PRD exists, that is fine for an eng-initiated RFC (refactor / migration / infra) — note it and proceed; for a clearly product-facing feature with none, flag it but still proceed.
   - the **codebase** — trace the real paths the change touches, not isolated files. Verify load-bearing facts against code; never assert from memory.
   - the **access and plan model** — if the design reads or writes tenant data that plans, entitlements or a retention window limit, read the repo's doc for that model first, so the design starts inside those limits instead of reaching outside them.
   - the **build skills** — identify what the RFC actually ships (an API endpoint, a background job, a data model, a UI surface…) and read its implementing skill, so the design matches build conventions instead of floating orthogonal to them. How to find them is in [domain routing](#ground-in-the-build-skills--domain-routing) below.
   - **any POC, spike, or prior run behind the ask** — when the design's value depends on how *good* its output is (§7's output-quality concern), ask for the artifact and read it: a prototype, a notebook, a graded sample, an earlier eval. Carry its **measured numbers** into the doc rather than restating its conclusion, because a claim that the approach works is exactly what a POC exists to replace with evidence. If the author says one was run but cannot point at it, treat that like a dead PRD citation — settle whether it exists before leaning on it. If none was run, that is a legitimate answer and §7 decides what follows: a quality spike that gates the LLD.
3. **Mine the brief for already-decided forks.** A heavy prompt usually pre-answers things. Every decision the author already stated lands in the Decisions Log as `decided (author, from brief)` and is **never re-grilled**.
4. **Premise check — before you draft (surface as fork #1).** Three probes, in order: **(a) does this already exist?** grep the RFC directory + the code for a system that already covers the ask — if one does, this RFC is an *extension* (or a no-op), not a greenfield design. When it **is** an extension, two consequences: the prior RFC + the existing code become your **primary ground** (above the build skills — read them first), and **re-ask whether an RFC is still the right artifact** — finishing a stubbed branch of a built system may be an ADR or just a ticket (`/plan:adr`), not a fresh RFC. **(b) Full problem or a slice of it?** Probe subset-vs-superset: the cheap subset is often the *wrong* product (a single-user feature when the real product is shared team accounts). **(c) Prior art** — for a product-facing RFC, a quick competitive / prior-art check. Wrong-premise is the costliest miss; settle it before any section.
5. **Concept-redefinition ripple.** Does this **redefine an existing core concept** (e.g. `customer` now meaning a person *or* a business)? If so, enumerate the shared artifacts that encode the **old** meaning — the architecture docs, the root & area `CLAUDE.md`, `.claude/rules`, other RFCs — and capture updating them as **explicit follow-up work** (a Task Breakdown slice or a §12 item), so the shared mental model does not silently fork.
6. **Pattern-precedent & stale-doc reveal** *(applies to every RFC — this is **not** gated on §5's redefinition; check it even when existing concepts are left intact)*. Two more shapes of the same "don't let the shared mental model fork" logic: (a) if this RFC **establishes a new pattern others will follow** — a reusable shape, a new convention — name where the mental model gets documented (the relevant `CLAUDE.md`, the architecture or data-model doc, or a skill) and capture that as a **Task Breakdown slice**, so the precedent is set in the harness rather than left tacit for the next author to reverse-engineer; (b) does the change **reveal an existing doc now stale** — a claim that was true *before* this lands (e.g. a strategy note in an area `CLAUDE.md`)? Capture the correction as a slice too. Neither should surface only because the author happened to ask.
7. **Emit a grounding summary + draft-vs-decide map** before drafting any section: what you understood, what you'll draft, the forks you'll need them on. On a clean slate that's mostly forks-for-you; on a heavy brief it's mostly already-decided + a few gaps. This is the plan — show it before proceeding.

The RFC must stay **anchored to the PRD** and not drift from it; if the design diverges from the PRD, surface that as a fork, don't paper over it.

## Ground in the build skills — domain routing

The RFC must not float free of *how the thing is actually built*. Before drafting the LLD, identify the **build surface(s)** the RFC touches and **read the implementing skill** for each — so the design matches its conventions (the spec an integration expects, the registry a processor registers in, the contract a REST endpoint follows), not an orthogonal design the implementer has to reconcile later. Then **name that skill on each Task Breakdown slice** (§Task Breakdown); where no skill owns the surface, leave the cell empty with a one-line reason (never silent) — so `/queue:ship-task` builds the slice grounded in it. This is the RFC → implementation anchor.

**Find the skills at run time.** List the skills available in this session and the repo's own `.claude/skills/`, and route each surface to the one whose description matches. If none matches, write the section from the code.

Depth lives in each skill (read on demand) and in the section that owns the concern (data-model §6, concerns §7, tests §8). A multi-surface RFC reads several. Match a skill by its **trigger** — a genuinely *new* surface the RFC ships (a new operation / endpoint / table / processor / proto / migration) — not by a keyword: *touching* a surface's existing code (a refactor in existing code, keeping the existing test suite green) ships no new surface and needs no skill. If the RFC builds nothing a skill covers, say so — don't force one.

## The Decision Workflow (per section)

For **each section**, run this loop:

1. **Draft** the section from the PRD + the code you read.
2. **Classify each item** in it — three states:
   - **already-decided** (the brief / PRD / a prior decision settled it) → record in the Decisions Log, don't ask;
   - **derivable** (follows from PRD + code) → you draft it;
   - **open fork** (judgment / intent / scope / prod-fact / operational policy, not settled) → grill the human.
3. **Grill** each open fork (see "How to ask"). Ask in the human's language — never surface internal tool/mechanism names in a question.
4. **Record** the answer in the `## Decisions Log` before building further on it.
5. **Do not build further on an unanswered fork.** When a human is reachable, you MUST put the fork to them — batch the section's forks, keep drafting *other* sections meanwhile, don't idle. The UNRESOLVED path is only for a run where prompting is *structurally impossible* (headless / cron / non-interactive, no channel to ask) — being mid-task or the human being slow is NOT that. When the run genuinely cannot ask, don't silently pick: record the fork `UNRESOLVED (NEEDS HUMAN)` with a provisional pick + reasoning, carry it into §12 Open Questions. A surfaced open fork is fine to take to review; the review gate FAILs only a fork resolved *silently*, and `/queue:ship-task` blocks implementation until an `UNRESOLVED` one is answered. Surfacing beats guessing.
6. **Self-gate the section before moving on (cold-read + ground-check).** Do not draft-and-advance. Before the next section, re-read the one you just wrote against [rfc-readability-rubric.md](rfc-readability-rubric.md) and fix what fires **now**, not at review — the bar is *the human is the last reader, not the first*, so a readability or grounding comment a human would add is a defect to close here:
   - **Cold-read** as an engineer who did not write it and has not seen the rest of the doc. Any paragraph that assumes a mental model, uses a term before defining it, or trips one of the rubric's structure rules (a claim-dump that wants bullets, a correspondence that wants a table, stacked run-ins that want headings — the rubric holds the exact triggers) gets fixed in place.
   - **Ground every claim as you write it, across the relevant scope.** A factual, schema, ownership, or wiring statement ("X owns the DAOs", "org_id is VARCHAR", "no DB of its own") is verified against the code — the DI wiring, the data-access code, the schema snapshot, the **sibling tables in the same DB** — at the moment it is written, not asserted from the design's own internal logic and not grounded only against the local object. Then **pre-answer the obvious depth question** ("why this type; any perf/consistency implication; why not the sibling idiom?") in the decision's own Decisions Log row, so neither the reviewer nor the human has to ask it. This is where item-scope grounding (a key type across *every* sibling database, an access-policy cast implication, which service owns a database) is settled proactively, not after being prodded.

### What counts as a real fork (and what does not)

Grill only on decisions that genuinely fork — any of: the PRD is silent/ambiguous and the choice changes the design; it's hard to reverse (schema, key, stored enum, API/proto contract, wire boundary); it trades off two things the PRD cares about; a future engineer will ask "why this way?"; you debated it with yourself.

**Do not grill on obvious choices.** Pick, note in one line, move on. A workflow that interrogates on trivia trains the human to rubber-stamp — the failure this exists to stop. When unsure, lean to one sharp question over five soft ones.

### How to ask

**Print the question in chat** — the genuine options/framing, **your recommendation and its reason**, and an explicit "or give me your own take." Open text, conversational, batched per section. **Do not use a multiple-choice tool / `AskUserQuestion`** — the author usually wants to add nuance or context, not pick a chip; a forced choice loses that. Match the register to the reader: an engineer fork can name internals; a fork for a PM strips them and asks in product terms.

**Once more than about three forks are open, stop batching and sequence them** — give a short status brief (settled, in flight, next), group the forks into named topics, and take one topic per exchange, each fork carrying your recommended answer. Two RFC-specific additions on top of that: **record each closed topic's rows in the Decisions Log before opening the next**, and **on a topology or flow fork, show the diagram before the question** — where something lives, which way data moves, which branch carries what. A small ASCII figure first, question underneath, lands where prose stalls: the reader answers against the picture instead of reconstructing it. Same figure discipline as `sections/hld.md`, applied to a question rather than to the document.

### The Decisions Log

A `## Decisions Log` section in the RFC — the single record of decisions **and** alternatives. One row each:

| # | Decision | Options considered | Choice | Why (+ trade-off accepted) | Decided by | Status |
|---|----------|-------------------|--------|----------------------------|-----------|--------|

`Status` = `decided` or `UNRESOLVED (NEEDS HUMAN)`. "Options considered" **is** the alternatives — a separate Alternatives section is only needed for a rare genuine whole-design fork worth a paragraph. For a load-bearing decision, note in "Why" the **trade-off accepted** and whether the choice **leaves room for the known next step** (future-compat). See [reference.md](reference.md) for worked examples and the Log-vs-rationale relationship.

## The Conviction Rule & the Vacation Test

> **Conviction:** a design doc's job is to convince the reader the design is optimal given the constraints. If a section doesn't build that conviction, cut it.

> **Vacation:** could a teammate implement this while you're away? If not, it's missing something. If yes but bloated with repetition, it has noise.

## Budget — the doc must stay reviewable

Length is not evidence of rigor; past a point it is the opposite, because **a doc large enough to break its own reviewers stops being reviewed**. A single file read has a token ceiling, and an RFC that runs past it forces every whole-doc reviewer — human, review agent, or the cross-model lens — onto a fragment while the report still reads whole.

The binding limit is **characters, not lines** — a dense table-heavy section can run 60+ tokens per line, so a 500-line doc can breach a ceiling a 900-line prose doc clears. Treat **~100,000 characters (≈25k tokens) as the hard ceiling** and **~60,000 as the working target for one design**, and check as you go with `wc -c "$RFC_DIR/<name>.md"`, not at the end. (`wc -l` is a cheap proxy — roughly 600 lines target, 1,000 ceiling — but the character count is what decides whether a reviewer truncates.)

Approaching the ceiling means one of four things. The first three are fixed by cutting rather than continuing:
- the doc is carrying **two designs** → split it, and say in each which decisions the other owns;
- a decision is being **argued in prose** where one Decisions Log row with the trade-off would settle it → move it to the row;
- a mechanism is being **elaborated before it is needed** → state its shape in a few lines and let the slice that builds it carry the detail.

The fourth is legitimate: **one coherent design that genuinely spans many build surfaces** (an integration + a background job + an API layer + a UI + a migration), where each surface needs real HLD/LLD/concerns depth. Don't force an artificial split — splitting a single design across documents hides the forks that cross them. This valve is **not self-assertable**: it applies only when the Task Breakdown already shows **three or more distinct build surfaces** (different implementing skills / packages, not three slices of one surface). Name them when you invoke it, and say in the PR that review must page the doc and fan out per section. Below that bar, the doc is long for one of the first three reasons.

The same applies to the Log itself: a count in the high dozens usually means **derivable** choices are being logged as forks. A derivable choice belongs in the prose it governs; the Log carries what genuinely forked, plus the `already-decided` rows the brief pre-answered — those stay (one terse line each), because the classification step above requires them.

## Prose register — write a document, not agent shorthand

The RFC is read by humans. Write **flowing document prose**: full sentences, **one concern per paragraph**; an enumerable summary is **bullets**, not one run-on sentence. Specifically:
- No agent shorthand — telegraphic fragments, arrow glyphs (`->` / `→`), semicolon run-ons. **If a compression / caveman mode is active in the session, it must not leak into the artifact** — the doc stays plain prose.
- Cross-reference in plain words ("section 7"), **sparingly** — don't pepper the doc with `§`.
- **No in-doc process citations** ("(Codex P1, PR #N)", "verified <date>") — state the decision as the final design; the review or incident that produced it belongs in the PR / changelog, not the design body.
- **State the final design, not the journey** — no "pending spike → now verified" or "solved now" build-up narration (see the progress-report DO-NOT below).
- **Define or drop jargon** — an undefined term ("trait", "reaper") fails the first-time-teammate read; don't invent artifacts or roles the team doesn't have.

## Document Structure — the section router

Write sections in this order. For each, the agent **drafts the derivable part** and **grills the open forks**. Heavy sections carry their deep guidance in `sections/<file>.md` — **read that file when you reach the section** (it is the content, not this row). Light sections are inline one-liners here. Skip a section only when it genuinely doesn't apply, and justify the skip.

| # | Section | Claude drafts | Author-decides (grill) | Deep guidance |
|---|---------|---------------|------------------------|---------------|
| 1 | Header | name, date, PRD ref, status | is the **name** accurate, not inflated? | inline |
| 2 | Problem & Motivation | restate from PRD; who's affected | the real problem (not a solution); the **evidence/number**; "what if we do nothing" | inline |
| 3 | Goals, Non-Goals & Success | candidate goals from PRD | scope line (**scoped-out-completely vs deferred-to-future**); the **mid/future-term** lens so it isn't rigid; the **one measurable success signal** (the DoD) | read `sections/goals.md` |
| 4 | High-Level Architecture (HLD) | the diagram (ascii or mermaid — whichever displays best) from code + PRD | whole-system fit, reuse-vs-new, the independent moving parts | read `sections/hld.md` |
| 5 | Terminology / Key Nouns | the design's identifiers + the **domain concepts** a context-free reader needs | concept-only definitions (no params/decisions/codebase realizations); **lead with it before §2** when the Problem/HLD use such terms; naming consistency with existing terms | inline |
| 6 | Detailed Design (LLD) | API/data-model/processing from access patterns | the data-model + concurrency + **package-distribution** + back-compat forks | read `sections/lld.md` |
| 7 | Cross-Cutting Concerns | which of the 7 apply | data-correctness · observability (+downstream watch) · tenant isolation/access scope · scale · external deps · decision-ownership · output-quality | read `sections/concerns.md` |
| 8 | Testing Strategy | the test layers + edge cases | **automated** local+deploy validation (minimize manual); the scenarios; test-prep | read `sections/testing.md` |
| 9 | Rollout & Operational Readiness | the phase skeleton | per-org phased rollout; the "are we ready" answer; rollback | read `sections/rollout.md` |
| 10 | Feature Flags | the flag list from the design | per flag: default · **ungate criteria** · rollback · scope | read `sections/flags.md` |
| 11 | Operational Jobs | which one-off jobs (backfills, data fixes) the design implies | READ/EXECUTE modes; idempotent/resumable; safety | read `sections/operational-jobs.md` |
| 12 | Open Questions & Risks | surface every UNRESOLVED fork + uncertainty | owner · deadline · "what changes if the answer flips" | inline |
| — | `## Decisions Log` | accrues every fork from above | (the running record + alternatives + future-compat note) | this file (above) |
| — | `## Task Breakdown` | propose vertical slices + proofs | slice boundaries; **HITL/AFK tag**; whole-RFC completion incl. supporting work | read `sections/task-breakdown.md` |

Inline one-liners (light sections): **§1 Header** — the only fork is the name (inflated names cascade into packages/protos/flags; flag it); front-matter is a `- **Key:** value` bulleted list, never bare `Key: value` lines (rendered markdown collapses those into one paragraph — the rubric's renders-as-authored item). The **status** field takes a controlled vocabulary — `Draft` → `In Review` → `Approved` → `Implemented` (plus `Superseded` when a later RFC replaces it); start at `Draft`. Do **not** hand-edit it to `Implemented` — the drain flips it in the final integration → base-branch PR (`/queue:ship-queue`), so status reflects shipped reality, not intent. **§2 Problem** — one real problem, grounded in a number, not a solution-in-disguise. **§5 Terminology / Key Nouns** — define each identifier once and reuse existing terms; also define the **domain concepts** the reader needs (bearer token, PKCE, rotation…) as **plain concept definitions** — no parameters, decisions, or codebase realizations (table/column, internal scope/scheme names), which only duplicate their own sections. When the Problem/HLD lean on such terms, **lead the doc with this section, before §2**, so the reader meets the vocabulary before it's used. **§12 Open Questions** — only genuinely-open items, each with owner + deadline + impact-if-wrong + **a recommended answer**; carry every `UNRESOLVED` Log row here. Open questions during review are normal and expected — some need the author to think, some need a conversation with someone else on the team, and neither is a defect. Two things follow from that. First, **every row carries your recommended answer and what changes if it flips**, so confirming it costs the author one word rather than a fresh analysis; a row that only asks is work handed back. Second, the target state **at merge** is zero open rows: the RFC exists to get its points settled, so the Task Breakdown is unblocked the moment it lands. Work the rows down collaboratively across the review — resolve by grounding what grounding can settle, move what is really future scope into its own section, and put the rest to the author as a recommendation on the PR. What merges is the record of how each was closed, not a standing list of opens. **Ground each risk you can** — a *code-level* risk must be checked against the code or a real run before listing (a speculative one that grounding disproves is noise — drop it); a genuinely **external** risk (vendor, product, rollout, customer-adoption) that no local check can settle is legitimate — keep it, with an owner, a deadline, and what would resolve it.

## Close — reflect, and improve the skill

After the RFC is drafted, run a one-pass reflection: *did any section lack a prompt the author had to supply by hand? did a fork surface that no section anticipated? did grounding miss something? did an existing section's guidance prove wrong, over-rigid, or unclear for this RFC?* If so, **say it in chat**, and — only with the author's OK — append one entry to the repo's skill-gap backlog, `.claude/skill-notes/tech-design-doc-writing.md` (create it on first use; a row can *add* a prompt or *improve/correct* one a section already has). The skill's own folder is the installed plugin, so it is never written to. Never auto-edit the skill mid-run; folding a backlog entry into a `sections/*.md` is a separate, vetted skill PR. This is how the skill improves with every RFC. The reflection is **not** an RFC section — the RFC stays clean.

## RFC lifecycle tail: ADRs, harness education, status

The RFC's *general* decisions and the *harness knowledge* the build produces are not loose afterthoughts a human must remember — they ship as the two **terminal slices in the Task Breakdown** (the ADR-extraction and harness-education slices), defined in `sections/task-breakdown.md`; the drain ships them like any slice. When the drain (`/queue:ship-queue --from-rfc` / `--integration-branch`) completes, it also flips the RFC's `Status` to `Implemented` in the final PR (§1).

## DO NOT

- Silently resolve a real fork — record it, ask the human, or tag it `NEEDS HUMAN`.
- **Narrate an undecided mechanism as settled prose.** If the design asserts *how* something works and that "how" genuinely forked, it's a Decisions Log row (or `UNRESOLVED`), not a smooth confident sentence.
- **Leak harness/skill jargon into the RFC prose.** Keep tool/skill names (`/verify`, bare skill names) out of the human-facing prose; a demoable-proof *sentence* reads in plain terms ("an end-to-end run proving the DoD"), not a slash-command. (The Task Breakdown's structured `implementing skill` column is the exception — it names `/skills` by contract.)
- Grill on obvious choices, or leak internal tool/mechanism names into a question, or use `AskUserQuestion`.
- Let the RFC drift from the PRD without surfacing it as a fork.
- Restate a system fact a `docs/`/code pointer should own (it will drift) — link instead.
- Scatter noun definitions; use different terms for one concept.
- Pad a terminology entry with a parameter, a decision, or a codebase realization (table/column, internal scope/scheme name) — a definition's job is the concept; the rest duplicates its own section.
- Write the RFC as a progress report — build-status markers (`(implemented)`/`(landed)`/done-in-#PR) or a done-vs-proposed split. An RFC states the target design; status lives in the tracker.
- Design V2 (future-compat states *what* changes, not *how*).
- Add generic cross-cutting boilerplate ("we will monitor").
- Include file-by-file build steps, ORM/mapper code, or per-PR strategy — the Task Breakdown names *what proves each slice*, not the implementation steps.
- Assert a load-bearing fact (a column, a role, an index, a vendor field) you have not verified against the code or a real run.

## See also
- [reference.md](reference.md) — the workflow deep-mechanics (grilling, AFK path, Decisions-Log relationship, slicing detail).
- [rfc-readability-rubric.md](rfc-readability-rubric.md) — the shared substance/structure/grounding bar the per-section self-gate (Decision Workflow step 6) and the review skill's fresh-reader panel (O2) both grade against; the section files carry its section-specific slices.
- [sections/](sections/) — per-section guidance, loaded on demand; [sections/README.md](sections/README.md) is the contract for adding/improving one.
- `.claude/skill-notes/tech-design-doc-writing.md` in the repo — the skill-gap backlog the reflection step feeds; an entry worth sharing becomes an issue or PR on the kit's repository.
- [VALIDATION.md](VALIDATION.md) — how to validate the skill with proof.
- `/plan:tech-design-doc-review` — gates the output; `/plan:task-breakdown` — builds the grounded, machine-consumable slice table from the reviewed RFC; `/queue:ship-task` — implements a single slice e2e; `/queue:ship-queue --integration-branch` — drains the whole Task Breakdown in dependency order.
- `/review:review-panel` — the soft cadence panel **re-reviews an RFC diff automatically** (on its commit/line cadence and pre-PR) by routing it to `/plan:tech-design-doc-review`, so these sectional learnings apply continuously while the RFC is being written, not only when the review skill is invoked by hand.
