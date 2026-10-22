---
paths:
  - "**/CLAUDE.md"
  - "**/.claude/rules/*.md"
  - "**/.claude/skills/**/SKILL.md"
  - "docs/**/README.md"
  - "docs/README.md"
---

# Docs Conventions

Applies when editing CLAUDE.md files, .claude/rules/ files, SKILL.md files, or the drift-prone docs that point at them (guides and README/index docs, which are where one artifact tends to re-list another's content).

## Content placement — which home does it go in?

Three homes, one test each. Decide by what the content **is**, not what it is about (a topic
may legitimately span all three).

- **`.claude/skills/`** — a how-to workflow the agent **executes** to produce or change
  something (imperative, on demand). Test: *"is this a procedure the agent runs to do a task?"*
- **`.claude/rules/`** — a constraint the agent must **obey** while working (auto-loaded,
  always or path-scoped). Test: *"must this hold for any matching change?"*
- **`docs/`** — reference knowledge humans and agents **read** (declarative, linked). Test:
  *"is this durable knowledge that is consulted, not executed?"*

The relationships keep these from collapsing into each other:

- **Single source — point, don't copy (any direction).** A skill points *into* `docs/` and never
  copies the facts (skill = verb, docs = noun); equally, a doc points *at* a skill / code / another
  doc and never reproduces a list, table, enum, or section-set that authoritatively lives there.
  Whichever way it goes, a restated fact drifts — **the urge to copy a block is the signal to link
  instead.** If duplication is genuinely unavoidable (a generated or tooling-fixed block that
  cannot link out), keep the copy minimal and next to a pointer at its source, so a reviewer can
  spot drift; never hand-maintain a silent copy.
- `docs/` never carries step-by-step agent procedure. That is a skill — procedure left in a doc
  rots because nothing runs it.
- When a topic spans homes, the **names must signal the home** and the homes must cross-link
  (e.g. local-debugging setup is a doc; a production debug investigation the agent runs is
  a skill, and they reference each other).

Placement is a judgment call, so it is enforced as **guidance plus a soft reviewer-panel lens,
never a hard gate** — there is no mechanical test for "is this misfiled". This rule auto-loads
whenever you edit a CLAUDE.md, a rule, a SKILL.md, or a drift-prone doc (a guide or a README/index
that points at them), which is the shift-left that keeps the layout — and the pointers between
homes — from drifting after a cleanup. If the repo keeps a human-facing map of its docs (for
example `docs/README.md`), that map is the on-demand form of this one.

Placement is one axis; **substance is the other.** A rule / SKILL.md / CLAUDE.md edit is guidance
an agent will *act on*, so the always-loaded **review-by-attack** posture (`operational-principles.md`)
applies at edit time, and the `/review:review-panel` blast-radius lens is the standing check that runs it
on guidance-artifact diffs.

### README.md vs CLAUDE.md in the same directory

Both can sit in one directory; the split is decided by the **loading mechanism**, and content
follows from that:

- **`CLAUDE.md`** is auto-loaded into every session that touches the directory, so every line
  costs tokens and dilutes adherence. Keep it to orientation, hard constraints, and **pointers**
  (see the size and content rules below). It carries the agent's standing orders.
- **`README.md`** is read only on demand (opened, or a link followed), so it can be the richer
  artifact: the map of what lives here, reading order, and a glossary. It carries navigation.

Litmus for a single line: *needed in context every time the agent works here?* -> `CLAUDE.md`.
*Orientation read once on arrival?* -> `README.md`. *A how-to procedure?* -> neither, a skill.
`CLAUDE.md` points at `README.md`; never duplicate between them.

## CLAUDE.md — What belongs here

CLAUDE.md is loaded into every session and consumed as context, not enforced configuration. Every line costs tokens and reduces adherence for everything else. Keep it minimal.

**Include only:**
- Non-obvious, project-specific commands (e.g. `make serve PORT=8080`)
- Security rules that must never be violated (tenant-scoped queries, service boundaries)
- Naming conventions that contradict general language defaults (e.g. Go all-lowercase, no hyphens)
- Architectural constraints Claude can't infer from reading the code
- Pointers to skills for how-to workflows

**Never include:**
- Step-by-step how-to content — extract to a skill and add a one-liner pointer
- Content derivable from reading the code (file counts, obvious directory structure, standard conventions)
- Duplicate content already in a subdirectory's own CLAUDE.md
- Long descriptions of services that have their own CLAUDE.md

**Size limit: 200 lines.** If you're approaching this, split into `.claude/rules/` (path-scoped) or extract to skills.

## CLAUDE.md — Skill references

Always use backtick-wrapped slash-command style:

```
See `/skill-name` skill for <topic>.         ✓
See `.claude/skills/skill-name/SKILL.md`     ✗  (file path style — avoid)
```

Every skill referenced must have a matching `.claude/skills/<skill-name>/` directory or come from an installed plugin. The guards plugin's `validate-docs.sh --all` checks this.

## SKILL.md — Required frontmatter

Every SKILL.md must start with a YAML frontmatter block:

```yaml
---
name: skill-name
description: Third-person description of what the skill does and when Claude should invoke it. Be specific — include trigger conditions and what the skill produces. (max 1024 chars)
---
```

Both `name` and `description` are required. Claude uses `description` to decide when to auto-invoke the skill; without it, the skill is invisible to auto-detection.

Additional frontmatter fields to consider:

| Field | When to use |
|---|---|
| `disable-model-invocation: true` | Skills with side effects (deploy, commit, send Slack) — prevents Claude from triggering automatically. Exception: a skill whose resumption re-enters through the model calling the Skill tool — a `ScheduleWakeup` prompt, or acting on a background task's completion (e.g. `codex-sweep`'s `await` handoff) — cannot carry it, since this flag blocks exactly that path. See `codex-sweep`, `pr`, `ship-queue`. |
| `user-invocable: false` | Background reference skills users shouldn't invoke directly (e.g. legacy system context) |
| `context: fork` | Long-running isolated tasks — runs in subagent, doesn't consume main conversation context |
| `allowed-tools: Read, Grep` | Skills that should be read-only — restricts Claude to listed tools |
| `argument-hint: [issue-number]` | Skills that take arguments — shown in autocomplete |

## SKILL.md — Size and structure

**Size limit: 500 lines.** Move reference material, API docs, or example collections to supporting files:

```
.claude/skills/my-skill/
├── SKILL.md          # Overview and navigation (≤500 lines)
├── reference.md      # Full API/option reference — loaded on demand
└── examples/
    └── sample.md     # Example output — loaded on demand
```

Reference supporting files from SKILL.md so Claude knows they exist:
```markdown
For full API reference see [reference.md](reference.md).
```

### On-demand is not only a size escape-hatch

The 500-line limit is the *backstop*. The *primary* reason to move a block into a supporting
file is **conditional relevance**, not length. A SKILL.md is loaded **whole** every time the
skill is invoked, so per-case detail that applies to only a *subset* of the skill's runs — one
lens body when the diff is not that shape, one provider's reference when another is in use, one
branch of a router — is dead weight on every other run, and it dilutes adherence to the parts
that always apply.

So keep the **router** in SKILL.md (which case fires when — a thin selection table or
descriptor) and put each case's **detail** in its own file, loaded on demand only when the
router selects it:

```
.claude/skills/my-skill/
├── SKILL.md            # procedure + router (loaded whole on invocation)
└── cases/
    ├── frontend.md     # one case's detail — read only when that case fires
    └── matcher.md
```

**Extract when a block is BOTH detailed AND conditional — even well under 500 lines.** A block
that is detailed but *always* relevant (it fires on every run) stays inline; a block that is
conditional but a one-liner is cheap enough to leave inline. The cost to avoid is a fat,
rarely-fired block riding in context on every invocation. Worked example: `/review:review-panel` runs
each lens only on a matching diff shape, so the diff-shape-specific lens bodies (`matcher`,
`stale-comment`) live in the skill's `lenses/*.md` and the SKILL.md routing table loads only
the ones a given diff selects — a diff that changes no matcher never pulls in the matcher
body. This is the same loading-mechanism logic as `CLAUDE.md` vs `README.md` above,
applied within a skill.

Two cautions when you extract:

- **Keep the explanation in one place — the always-loaded body is for the workflow, not the
  rationale.** A SKILL.md is workflow orchestration: the imperative steps the agent runs. The
  *why* a block was extracted, when to extract the next one, the loading model — that is editor
  guidance, and it belongs here in this rule (which auto-loads exactly when someone edits a
  SKILL.md), not repeated in the SKILL.md the runtime agent loads every invocation. The SKILL.md
  carries only the operational pointer ("read `cases/foo.md` for this step"); a one-line "why
  this lives here: see docs-conventions" link is the most rationale it should hold.
- **Make the read unmissable — the inline router entry is a pure pointer, not a substitutable
  summary.** If the thin row left behind still reads like a usable instruction, an agent will
  use *it* and skip the file — a hollow run that still looks like the step fired, silently
  missing everything the summary dropped. Reduce the router entry to a forward-only pointer
  ("on-demand — read `cases/foo.md`; this row is not the content") and state in the procedure
  that the file read is mandatory.
- **Drive the behavior off the entry's own marker, never a second list of names.** The procedure
  should dispatch on the router entry itself ("if the entry is marked `on-demand`, read its
  file"), so a new conditional case self-registers just by marking its entry. Do not also
  enumerate *which* cases are on-demand somewhere else in the body — that second list duplicates
  the entries and goes stale the moment a case is added (the classic drift this whole rule
  exists to prevent).

## .claude/rules/ — Path-scoped rules

Rules in `.claude/rules/` load into context only when Claude works with matching files, saving context space. Use `paths:` frontmatter to scope them:

```markdown
---
paths:
  - "src/api/**/*.ts"
  - "src/api/**/*.tsx"
---
```

Rules without `paths:` load unconditionally every session — treat them like CLAUDE.md (keep them brief).

## What belongs in the always-loaded posture rule

`operational-principles.md` is the always-loaded "how we work" rule (no `paths:`, loads every session). Keep it to **non-gateable posture only**. The litmus: if a hook or a gate could enforce it, it does NOT belong here — build the hook or gate instead, because an advisory line rots while a gate holds.

**Belongs here** — posture nothing can mechanically check or auto-fire:
- Verify before you assert; find the root cause; plan before non-trivial work; keep the human able to review.

**Does NOT belong here**, with where it goes instead:
- Something that should run automatically on a cadence → a **hook**. (The "review every few commits" workhorse is the during-coding cadence hook, not a posture line.)
- Something enforceable at the merge gate → a **gate**. (Architecture tests, lint, and any readability check run in CI, not here.)
- Mechanically checkable rules (no secrets, inputs validated, tests cover edges) → a **gate or linter**.
- "Ask before committing" → **Claude Code permissions**.
- A how-to procedure → a **skill**. A path-specific convention → a **path-scoped rule** (with `paths:`).
