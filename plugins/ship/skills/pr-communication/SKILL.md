---
name: pr-communication
description: >-
  Writing guidelines for pull request titles and descriptions, chat messages and other written
  communication: voice, structure, what a PR description must prove, and review etiquette. Use
  when drafting or reviewing a PR description or a message to the team.

---

# Communication Style

When drafting messages, PRs, chat posts, or any written communication:

**Voice**
- Direct, no pleasantries — "Team, need your thoughts" not "Hey team, I'd appreciate your review"
- Lead with why it matters to the team/product, not what the PR contains
- Show momentum — mention what's already in progress or tested alongside what needs input

**Structure**
- Layer information: why you're posting and what you need first, specifics second
- Bullets for specifics are fine, but keep them flat — no numbering, no tables, no headers within the message
- Link to the source of truth — don't inline what the reader can find in the PR/doc

**PR Descriptions**
- Use the template in [pr-template.md](pr-template.md) — the single source for the section structure, the omit-empty / anti-slop rules, the Conventional-Commits title spec, and *why the shape is what it is in an AI-first repo* (authoring is free, reviewer trust is the bottleneck, claims must be evidence-bound). Do not restate any of that here or elsewhere; link to it.
- The Voice and Structure notes above apply to the body — lead with impact, call out non-obvious decisions, guide the reviewer on a large diff.
- Same reframe as the rest of this guide: written communication here is increasingly **read by agents too** (PR reviewers, the next session). Structure it and bind claims to evidence so a machine reader can act on it — not just a human skim.

**Numbers and future-work tables**
- Every number carries its population inline — "24 of 81 merged PRs in repo X", not "24". A reader cannot reconstruct a denominator from context, and adjacent numbers get assumed to share one.
- When two numbers come from different populations — one repo versus the whole org, PR-level versus developer-PR-level, a sample versus the total — say so explicitly at the switch. Unlabelled population changes are the single most repeated source of confusion in shared analysis; a one-line "different denominator: this is per developer-PR, the number above is per PR" prevents it.
- Any table listing future or in-flight work carries a status or confidence column per row. Without it a list of possibilities reads as a committed pipeline.
- In that table, keep deterministic deliverables and unproven improvements structurally apart — separate tables or an explicit grouping, not interleaved rows — and state the ceiling: what this cannot do even if every row lands.

**Collaboration**
- Invite, don't instruct — "let me know your thoughts" not "Do X"
- State what's needed and by when — unclear deadlines mean things slip
- Close the loop after decisions — post the outcome so reviewers see their input mattered
- Default to public channels over DMs — knowledge shared in DMs dies there
- Disagree in suggestions — "what if we used X instead" not "X is wrong"
