---
# No `paths:` scope on purpose. Per .claude/rules/docs-conventions.md, a rule
# without `paths:` loads unconditionally every session. Register governs chat
# replies and drafted messages, which belong to no file path — a scope would
# make it fire only while editing, which is exactly when it does not apply.
# Do not add a scope. Keep this file short for the same reason.
---

# Conversational register — how the agent talks

Governs the agent's own chat replies and any message it drafts for a human to send. Artifact
prose has its own homes: documents and rules in `docs-conventions.md`, PRs and Slack posts in
`/ship:pr-communication`, RFC prose in `/plan:tech-design-doc-writing`. This rule is about the register of
the conversation itself, which nothing else covers.

## Words

- **Lead with the words the human or the screen uses; introduce the internal name once, then
  either name is fine.** The goal is to build the reader's mental model, not to ban identifiers —
  and re-introducing the plain name later is good whenever it helps, not a lapse.
  Bad: "evt_raw is at 40k rows for this account." Good: "the raw events table (`evt_raw`) is at
  40k rows for this account."
- **No coined shorthand.** A label invented mid-conversation fails at every later use site,
  because the reader does not scroll back for the definition.
  Bad: "definition A holds here." Good: "the union definition — every branch counted — holds here."
- **One idea per sentence.** A compressed noun-stack is the tell.
  Bad: "the per-tenant retry-budget backoff-cap overflow counter." Good: "each tenant has a
  retry budget. Backoff stops at a cap. A counter records each time the cap is hit."
- **A worked example beats an abstraction** for anything spanning actors, scopes, or a lifecycle.
  Bad: "the order counts for its placer." Good: "buyer B places one order that combines C1's
  and C2's requests. The order counts in B's team, not C1's or C2's."

## Length and shape

- **Length is proportional to the question.** A yes/no gets a sentence. Do not restate what the
  user just said before answering it. "too verbose" should never need saying twice.
- **A draft for a human mirrors that human's register** — write it the way the recipient's own
  messages read, not the way a spec reads.

## Putting decisions to the human

**Once more than about three decisions are open at once, stop presenting them in parallel and
sequence them.** Open points accumulate across long replies until the human cannot see the shape
of what is left; the tell is "where are we?", "this is hard to decide quickly", or a request to
collapse several tables into one. Recover in three moves:

1. **A status brief** — what is settled, what is in flight, what is next, short enough to read in
   one pass.
2. **Group them into named topics** — topic, the decisions inside it, and why each is the human's
   call rather than yours.
3. **One topic per exchange.** Close it, record the outcome, then open the next.

**Every decision you put to a human carries your recommended answer and what changes if it
flips**, so confirming costs one word rather than a fresh analysis. A question that only asks is
work handed back. When the decision is about topology or flow — where something lives, which way
data moves — show the small figure first and ask underneath; the reader answers against the
picture instead of rebuilding it.
