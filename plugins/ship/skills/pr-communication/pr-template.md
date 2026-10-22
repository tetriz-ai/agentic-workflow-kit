# PR description template (single source)

The canonical shape for every PR raised against this repo. `/ship:pr-communication` owns it; any skill
that writes a PR body links here and never copies the structure — this file is the one home.

## Why this template is shaped the way it is (read this first)

With this kit a PR is usually **written by an agent, and increasingly reviewed by one** (Codex,
`/review:review-panel`) before a human ever opens it. That inverts the old economics of a
description, and every rule below falls out of five facts:

1. **Authoring is free; reviewer trust is the bottleneck.** A human description is disciplined by
   author fatigue — an agent has none and will emit unlimited plausible prose. So the discipline
   comes from the *reviewer's* needs, enforced here, not from effort. Every line must cut what a
   reviewer would otherwise re-derive or take on faith. **Prose an agent could regenerate from the
   diff is slop; decisions, risk, and evidence are the only signal.**
2. **An agent's claim about its own work is worth nothing until it is bound to evidence.** "Tested,
   works, safe" is exactly what a confident-but-wrong agent also writes. So **Validation is
   reproducible commands with real output**, and the author **states what it could not verify** —
   its own blind spots — rather than papering over them. This is the verify-and-flag principle
   (verify, flag what you cannot, never fabricate a green) applied to PR authorship.
3. **The description is parsed by machines.** Stable section headers, checkable claims, runnable
   commands — so a reviewer-agent can act on it, re-run the proof, and aim its attack at the
   declared nuances. Write it as an interface for that reader, not only for a human skim.
4. **Intent is ephemeral.** When the session ends, the *why* is gone unless it is written here — the
   next agent or human cannot ask the author. "Why this way, what was rejected, what it assumes" is
   durable only if it lives in the description.
5. **Sprawl is the default failure of agentic coding.** One prompt can touch forty files across four
   concerns. Scope is therefore an *active check* the author runs before opening the PR (see `/ship:pr`),
   and this description must either be **one logical change** or name the units and justify shipping
   them together.

## The three principles

- **Impact first, mechanics last.** A reviewer should grasp *what changes for the product or system,
  and why* before meeting a single file path. A description that opens with "renamed X, moved Y,
  added Z" makes the reader reverse-engineer the point.
- **A map, not a transcript.** Orient the reviewer and point them into the diff — do not re-narrate
  it. Each bullet earns its line: one logical change, fewest words a reviewer can act on. A bullet
  that grows clauses explaining *how* the code works is doing the diff's job — that belongs in the
  code or the commit. Length tracks the *understanding a reviewer needs* (decisions, traps, why),
  **not the size of the diff**: a large but mechanical change (a rote rename, generated code, a CRUD
  DAO) earns a *short* description; a small but subtle change can need more. This trims words per
  point, never a required section and never the strength of **Validation**.
- **Evidence over assertion.** An agent author's confidence is not evidence. Bind every "it works"
  to something a reviewer can re-run; state every "it's safe" with its blast radius and how to
  revert; surface every thing you could *not* prove with the exact check that would settle it. A
  description that reads as certain while resting on unverified assumptions is the AI-first failure
  mode this template guards against — the same self-assertion-isn't-trust posture as the
  verify-and-flag principle above.

## The sections

Only **What & Why** and **Validation** are required. Everything else appears **only when it carries
signal** — **omit empty sections entirely, never leave a blank header**. A one-line fix is two
sections; a cross-cutting change is several. Matching the section count to the change is what keeps
an agent-authored description from becoming slop — the author won't tire into brevity, so the
omit-empty rule is what enforces it.

```markdown
## What & Why            (required)
- Impact-worded: what this unblocks, fixes, or changes for the product or system, and why it
  matters. "Customers now see refunds in the monthly total because the report ignored them" —
  not "added includeRefunds()".

## Screenshots (before → after)  (required for any change that alters what a user sees — frontend OR backend-driven; omit only when nothing rendered changes)
- Full-page before/after screenshots, embedded here side by side. `/ship:pr`'s *Capture visual evidence*
  step owns which states to cover, the capture mechanism, and the upload/embed format (images are
  uploaded, never committed) — see it, do not restate it here.

## Scope                 (optional — surface only when the diff is more than one logical change)
- If it is one logical change, omit this. If it bundles independent units, the default is to
  split or stack (see /ship:pr); if they genuinely must ship together, name each unit and say why.
  This is the agent-sprawl guard made visible to the reviewer.

## Mental model          (optional — only when the change has structure worth a map)
- A small ascii or mermaid diagram (whichever renders more clearly in the PR) OR 3-5 bullets that
  let a reviewer build the model before reading the diff. Diagram for a flow / pipeline / state
  machine / multi-actor handoff; bullets for a set of independent facts. Skip for a dep bump or a copy fix.

## Nuances & decisions   (optional)
- The non-obvious calls and traps — see "What counts as a nuance" below.

## Risk & rollback       (optional — when the change can break things in prod)
- Include when the change touches a migration, a backfill, a flag flip, infra, auth, or live
  data. State the blast radius if it is wrong, how to revert (flag flip / revert-safe / a
  migration down-path), and what to watch after merge. Omit for a pure-logic change with no
  prod surface.

## Changes / where to look (optional — the reviewer's start-here)
- Grouped by logical change, not per file. Five files for one change is one bullet. Name the
  load-bearing file and what is mechanical, so a bandwidth-limited reviewer (human or agent)
  spends attention where it matters — not a file listing.

## Validation            (required — proof, not intent; see below)
- Reproducible commands and their real outcomes, including the independent verdicts a reviewer
  can re-check:
  - `<the repo's test command>`       -> pass
  - `<the repo's build command>`      -> green
  - merge gate (`merge_gate`) for PR NNN -> green           (blank setting: required checks pass)
  - `review-panel pre-pr`             -> 0 Critical / 0 Important
  - `/review:codex-lens`                     -> no blockers        (when run)
  - [manual] hit /api/... locally     -> returned expected X
  - [frontend] see the Screenshots section (full-page before -> after)  (rendered-surface change)

## Unverified & assumptions (optional — expected whenever something is claimed but not proven)
- What this change asserts that the author could NOT prove from source or a local run — and the
  exact check that settles each (a prod query, a vendor call, a load test). These are the
  author's declared blind spots, so the reviewer attacks them instead of trusting a clean-looking
  diff. A check that cannot run before merge is named here with its gate, not silently dropped.

## Follow-ups            (optional)
- Deliberately out of scope, new issues filed (#NNN), what comes next.

## <Task-specific>       (optional — only if it adds signal)
- query optimisation: EXPLAIN ANALYZE before/after, latency numbers.
- docs: references, how this will evolve.

Closes #NNN
```

## Title — the machine-parseable handle

The title becomes the squash commit subject and feeds changelogs, release notes, and bots/agents
that parse history, so it is **Conventional Commits**: `type(scope): imperative subject`.

- **type** — `feat` `fix` `docs` `chore` `refactor` `perf` `test` `ci` `build`.
- **scope** — your repo's scopes (top-level areas): the domain or tool the change lives in — the
  package/tool, not the architectural layer. Omit only for a genuinely repo-wide change.
- **subject** — imperative mood ("add", not "added"/"adds"), lowercase, no trailing period.
- **breaking change** — append `!` after the scope (`feat(api)!: …`) and explain in the body.
- **length** — keep the whole title under ~70 characters.
- Examples: `fix(billing): skip zero-amount invoices in the monthly export` ·
  `feat(orders): show refunds per customer`.

## What counts as a nuance

A nuance is something a reviewer would **not** discover by reading the diff top to bottom, and would
either waste time rediscovering or get wrong by assuming the obvious:

- A decision with a rejected alternative ("chose X over Y because Z").
- An ordering or sequencing constraint (migrate before deploy, flag-flip order).
- A non-local effect — the change relies on, or affects, code that is **not** in the diff.
- A deliberate trade-off and its blast radius.
- A sharp edge ("this looks wrong but is correct, because…").
- An assumption the change bakes in, and what breaks it.

If nothing fits, omit the section. Do not manufacture nuances to fill it.

## Validation is proof, not intent

Validation records **what was actually done to prove the change works** — past tense, with results.
An agent author can assert a green it never ran; the antidote is that everything here is a command a
reviewer can re-run and a verdict (the merge gate result, the `review-panel` verdict) a reviewer
can re-check.

- Not a test plan of intentions. "Will test the migration on staging" is not validation.
- A check that genuinely cannot run before merge is **not** pending validation — it is an
  **Unverified & assumptions** item (with its gate) or a **Follow-up**. Forward-looking items do not
  live here.
- If the change cannot be credibly proven, that is a signal to verify it before raising the PR — and
  to record the residue under **Unverified & assumptions** — not to soften this section. Soft
  tooling does not make this step optional.

## Formatting

PR-body specifics only. For the team voice (tone, no filler, invite-don't-instruct), follow
`/ship:pr-communication` — the single owner of voice. This file does not restate it.

- Title: see the **Title** section above (Conventional Commits, < ~70 chars).
- Readable prose plus real bullet lists; never semicolon- or middot-glued run-ons. Omit empty
  sections — never leave a blank header.
- Lead with why it matters, then the specifics. Link to the source of truth instead of inlining it.
- **Never use a bare `#N` to number items, steps, or sections.** GitHub renders `#N` in a PR body
  (and an issue body or comment) as a **live reference to issue/PR N** — so enumerating "`#1` … `#8`"
  silently links eight unrelated tickets, pollutes their timelines, and misleads every reader. Reserve
  `#N` for a *genuine* reference (`Closes #NNN`, `Related #NNN`, `Ref #NNN`). To enumerate, use a plain
  ordinal with no hash — `1.` / `(1)` / `item 1` / `[1]`. Same care for `@name` (auto-mentions) and a
  bare `GH-1234`-style token.

## See also

- `/ship:pr-communication` — the voice guide this file belongs to.
- `/ship:pr` — raises and reconciles a PR following `/ship:pr-communication`, so it uses this template; it
  also owns the pre-flight **scope check** that decides whether this is one PR or several.
