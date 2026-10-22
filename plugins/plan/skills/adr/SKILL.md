---
name: adr
description: >-
  Writes an Architecture Decision Record from the template, and helps decide whether a decision
  needs an ADR or a full RFC. Use when the user is creating an ADR. Also suggest one when the user
  is making a technical decision that should be written down.
---

# Skill: Writing ADRs

## ADR vs RFC — Which to Write?

**ADR** — records a decision. Short and focused. "What did we decide and why?"
**RFC** — documents a design. Longer, with detailed implementation. "How should we build this?"

Use an ADR when:
- Choosing between approaches (Redis vs Memcached, promauto vs MustRegister)
- Introducing a new dependency, service, or pattern
- The decision is concise — context, decision, alternatives, consequences
- A future engineer would ask "why did we do it this way?"

Use an RFC (`/plan:tech-design-doc-writing` skill) when:
- The change needs detailed design (schema, API, data flow)
- Multiple services or teams are affected
- You need diagrams to explain it

Use both when a complex feature needs a full design (RFC) AND records specific decisions (ADRs).

## Creating an ADR

ADRs live in the `adr_dir` setting (default `docs/adr`):

```bash
ADR_DIR=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get adr_dir '${user_config.adr_dir}')
```

1. **Create a GitHub issue** for the decision (if one doesn't exist)
2. Take the **next free number** in `$ADR_DIR` — one above the highest existing `NNNN-` prefix
3. Create `$ADR_DIR/{NNNN}-{title-slug}.md` from the template below

## Template

```markdown
# ADR-{NNNN}: [Title]

## Status
[Proposed | Accepted | Deprecated | Superseded]

## Context
What is the issue motivating this decision? Ground in evidence, not vibes.

## Decision
What is the change we're making? State it clearly in 1-2 paragraphs.

## Alternatives Considered
For each: what it is, why it was rejected, under what conditions you'd reconsider.
This section prevents future engineers from re-litigating the decision.

## Consequences
What becomes easier or harder? Be honest about the downsides.
```

## Extracting ADRs from RFCs

ADRs often emerge from RFCs. After implementing an RFC, review it for general decisions that apply beyond the specific feature. Extract those into standalone ADRs. The RFC keeps a concise summary with a link to the ADR.

**Test:** "Would another team building a different feature benefit from knowing this decision?" If yes → extract into an ADR.

**Example:** a design doc for one service that also decides how every service registers metrics and builds dashboards. Those two decisions belong in standalone ADRs (metrics conventions, dashboard infrastructure), because they apply to every future metric and dashboard, not just that one service.

## Rules

- Number every ADR with the next free number in `adr_dir` — never reuse or hand-pick one
- Never reference ADRs from source code (Go, TS, proto, SQL). ADR references belong in markdown docs, PRs, and commit messages only
- ADRs are immutable once accepted — create a new ADR to supersede, don't edit the old one's Decision section
- Keep it short — if it needs diagrams, schemas, or detailed design, it should be an RFC
- Include Alternatives Considered — this is what makes an ADR useful months later
