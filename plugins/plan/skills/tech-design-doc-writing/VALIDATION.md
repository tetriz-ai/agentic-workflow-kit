# Validating the tech-design SDLC skill chain

How to confirm the chain does what it intends — write an RFC as an interactive decision workflow, review it, hand off task-briefs, and ship a slice — with **proof, not assumption**. A skill change is real only if a fresh agent, given only the skill, behaves as intended. Five layers, cheapest first.

## Layer 1 — structure (automated, re-runnable)
```bash
# run the repo's docs validator too, if it has one; ignore unrelated pre-existing hits
wc -l "${CLAUDE_PLUGIN_ROOT}/skills/tech-design-doc-writing/SKILL.md"   # <= 500
wc -l "${CLAUDE_PLUGIN_ROOT}/skills/tech-design-doc-review/SKILL.md"    # <= 500
# and the ship-task skill's SKILL.md (queue plugin), if installed      # <= 500
```
Pass: every SKILL.md <= 500; frontmatter `name:`+`description:` intact; every cross-skill / `sections/` / `docs/` link resolves; the writing router's section headers match what the section files and the review skill reference (no orphan §-numbers).

## Layer 2 — writing behaviour (fresh-agent dry-run, the core proof)
A fresh agent, given only the writing skill, runs it on a real PRD. It must self-report, from what the skill instructs:
1. **Phase 0** grounds (PRD + code) and emits a grounding summary + draft-vs-decide map before drafting.
2. the **per-section router works** — it reads `sections/hld.md`, `lld.md`, `concerns.md`, etc. and gets usable draft-vs-author-fork guidance.
3. it drives **printed questions + a recommendation + an invite for the author's take**, and does **not** use `AskUserQuestion` / multiple-choice.
4. it produces a **Decisions Log** (Options = alternatives) and a **Task Breakdown** whose slices carry demoable-proof + HITL/AFK + depends-on + RFC anchor.
5. the **applicable** concerns come through (data-correctness, observability incl. the downstream watch, tenant isolation/access scope, scale, external deps, decision-ownership, output-quality), each inapplicable one carrying a defensible explicit skip — the same applies-when semantics `sections/concerns.md` grades by. Demanding all seven on any single fixture would invite a fabricated section: a fixture that computes metrics deterministically has **output-quality legitimately N/A** and a run that invents a quality bar for it has failed, not passed. Exercise output-quality against a fixture that genuinely produces graded output. DoD/GA is **not** a concern at all: it is handled via §3 + §10 Flags.
6. for a fork with no human reachable, it records `UNRESOLVED (NEEDS HUMAN)` rather than silently picking.

Pass: yes to 1–5, the AFK behaviour on 6, no dead router pointers. (A strong run also catches when the PRD's facts are stale against the code — the verify-don't-assume payoff.)

## Layer 3 — review behaviour (fresh-agent, both directions)
- **Weak feature RFC** (no Decisions Log, a silently-resolved fork, a hedged "TBD", no Task Breakdown, emits a number with no correctness treatment): a fresh reviewer returns **FAIL** citing D1/D2/D3 and the missing Task Breakdown.
- **Good migration RFC** (populated Decisions Log, symmetric up/down + snapshot + `-dry_run` proof, the analytics concern explicitly N/A, **no** Task Breakdown because it's a migration): returns **PASS** and must **not** penalise the missing Task Breakdown (D4 non-slice clause) or the N/A concern (D3 defensible skip). This false-positive guard matters as much as the FAIL case. (Use a *fixture* test where correctness matters — do not expect a golden-JSON ritual.)

## Layer 4 — cross-skill coherence
A fresh agent reads all four skills + the section files and confirms:
- the review skill's per-section headline gates **match** the `Review hooks` in each `sections/<x>.md` (single source, no drift);
- the **Task Breakdown → task-brief → shippers** field contract maps 1:1 (demoable proof, HITL/AFK, depends-on, RFC anchor, implementing skill) — consumed by `/queue:ship-task` for a single slice and `/queue:ship-queue` for the dependency-ordered drain;
- DoD/GA is consistently woven into §3 + §10 (not a standalone concern); no leftover "§7 Key Decisions / Alternatives" sections (merged into the Decisions Log);
- all cross-skill links resolve; section numbering/terms agree across files (no "Slice Plan"/"§15" drift).

## Layer 5 — skill-change vet (required before any SKILL.md ship)
One fresh, unbiased agent on the full diff: **rigidity drift** (over-prescriptive? hard-coded examples copied verbatim? — and is `ship-task`'s autonomy genuinely bounded by its gates, not over-granted?); **scope** (does anything belong in the global posture instead? is questions-here/facts-by-pointer honoured? does `ship-task` compose the *project* shippers, not a personal `/ship`?); **user-leak** (any template an agent copies verbatim to a non-engineer, leaking internal names?). Present findings; apply only approved ones.

## What "passing" looks like
- Layer 1: all SKILL.md <= 500, links resolve, no orphan §-numbers.
- Layer 2: the writing skill drives grounding + router + printed-Q + Decisions Log + Task Breakdown + the applicable concerns; old-vs-new contrast (if run) is stark.
- **Any newly-added gate is exercised in both directions before it ships** — one real RFC it must fire on, one it must stay silent on. A gate is only proven by the pair: a hook that always fires is not a gate, and the silent case is what proves its applies-when. Name the RFCs and the outcome, so the claim rests on a run rather than an assertion.
- Layer 3: weak RFC → FAIL on the right checks; good migration → PASS with no false-fire.
- Layer 4: no drift between writer, reviewer, task-brief, and the shippers (ship-task / ship-queue).
- Layer 5: vet returns no unaddressed blocker; the human signed off on applied fixes.
