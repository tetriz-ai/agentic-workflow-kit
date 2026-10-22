# Section guidance — the iteration contract

Each file here is the **deep guidance for one RFC section**, loaded **on demand** when the writing skill reaches that section (the `SKILL.md` router row says `read sections/<file>.md`). Splitting per section is what lets anyone improve one section in isolation, every RFC iteration, without touching the spine — and it's what `/plan:tech-design-doc-review` validates against, so the writer and the reviewer never drift.

## The one rule: questions here, facts by pointer

- **Skill-owned (stays here, may be detailed):** *how to design this section well* — what Claude drafts, the open forks the workflow grills the human on, the recurring review-asks-as-prompts. This is about *how to write an RFC*; it doesn't drift when the code changes.
- **Docs/code-owned (pointer only, never restated):** *how our system works* — the data layer's tenant-scoping mechanics, the change-data-capture pipeline, the feature-flag object, the architecture doc. Link to it; do not copy it. A restated fact drifts the moment the code moves; a pointer doesn't. (`/review:review-panel`'s blast-radius lens flags a skill restating a fact that should be a pointer.)

If you can't tell which a line is: if it would change when the codebase changes, it's a fact → pointer. If it's a question you'd ask any author of any RFC, it's skill-owned → keep it.

## The shape every section file follows

```
# §N <Section name>

**What it is** — one line.
**Applies when** — when this section / its forks are relevant (so the agent can skip with justification).

## Claude drafts (derivable)
- the parts that follow from PRD + code.

## Author decides (grill — printed question + your recommendation + "or your take")
- each open fork, phrased as the question to put to the human. Lead with your recommendation.

## Ground in (pointers — read, don't restate)
- docs/code links that hold the system facts this section needs.

## Review hooks (what /plan:tech-design-doc-review checks here)
- the gate(s): what makes this section PASS / WARN / FAIL.
```

Keep "Author decides" the heart of the file — it's the collaborative grilling. Keep "Ground in" a list of links, not prose. Keep "Review hooks" tight so the review skill can lift it directly.

## How the two skills use these files
- **`tech-design-doc-writing`** reads `sections/<x>.md` when it reaches section x, drafts the derivable, grills the forks.
- **`tech-design-doc-review`** validates the produced section against the same file's **Review hooks** — one contract, two consumers, no drift.

## Adding or improving a section
- **New section:** add `sections/<name>.md` in this shape + a router row in `SKILL.md` marked `read sections/<name>.md`. The router drives off that marker — nothing else to keep in sync.
- **Improve a section:** edit its one file. Every change to a `SKILL.md`/section file is a guidance change an agent acts on — it gets the skill-change vet ([../VALIDATION.md](../VALIDATION.md) Layer 5: rigidity / scope / user-leak) before commit.
- **Source of new prompts:** the closing reflection step appends skill-gaps to the repo's `.claude/skill-notes/tech-design-doc-writing.md`; approved ones are folded into the right section file here.
