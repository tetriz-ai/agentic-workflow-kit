# bug-hunt — the author gate

The one mandatory pause. By the time the author sees a row, grounding is finished, every agent-owned question is resolved, and every `ship-queue` row is a complete executable draft (`scripts/readiness-check.sh` green — evidence-manifest.md). The gate presents *decisions*, not a description of findings.

## Before the gate — resolve, then present

Do **not** escalate technical uncertainty as product uncertainty. For each finding, in order:

1. State the **user-visible correctness invariant** the fix must make true.
2. Derive the recommended solution from the **RFC, product copy, API contract, and correct siblings** — not from asking the author.
3. Resolve implementation **breadth from code**; prefer one atomic product outcome even across layers.
4. Ask the author **only** if a genuine product or risk trade-off survives — two materially different product behaviours both reasonable.

An empty-group filter, a timezone boundary on an order date, an invoice total that fails validation, pagination — these have a correctness-preserving answer derivable from the contract or a sibling. Recommend it (for an empty group, a fail-closed explicit scope); do not ask the author to invent the solution.

## The decision table

Every row is a **decision**, with this minimum shape:

`What | Why | Explanation + recommendation | Priority | Owner`

The recommendation must state **what users experience after the fix** and name the **smallest coherent implementation path**. Labels and queue state are secondary metadata, shown later. For concurrency/tenancy/auth/async/browser findings, the recommendation **names the actors and boundary in plain language**: whose process, whose credentials, what is shared, how one request affects another. "Same session" that actually means a shared server-side HTTP connection pool must say so.

## No "Held" — four explicit fields

Never render a single `Held` state: it hides which of several unrelated states a row is in. Instead every row carries:

| Field | Allowed values | Meaning |
|---|---|---|
| Author decision | `none` / one exact question | Whether human product judgment is genuinely required |
| Agent grounding | `complete` / one exact remaining check | Work the agent must finish **itself**, never ask about |
| Filing readiness | `ready` / `not-ready` | Whether a self-contained issue can be written now |
| Handoff | `ship-queue` / `human` / `activation` / `none` | What happens after filing |

Never show a blocking word without the **exact unresolved question and who owns resolving it**. An `Agent grounding` value other than `complete` means *you* have work to finish, not a question for the author.

## One atomic outcome, not decomposition-by-layers

Number of layers is not the issue boundary; **independently valuable outcomes are**. Propose one issue when all the changes are necessary to make one product contract true (a webhook retry correction — retry scheduling + delivery log entry + replay of dropped events — is one atomic outcome). Split only when a slice is independently shippable and useful, or rollout/risk requires it. A fixer may use multiple PRs; that never forces the author to approve multiple partially-correct issues.

## Priority = scheduling, not severity

**Load the `/ship:github-issues` skill's priority convention before producing the first table** — it is the single source for what each priority value means; do not restate the enum here. Calibrate as **scheduling reality, not severity**. The one bug-hunt-specific nuance that convention does not cover: **never lower priority merely because a defect is latent or the path it sits on is rarely used.** Production activity, urgency, and correctness are separate facts — a latent defect can be **P1 and ship-queue-ready** when the author wants correctness established before activation.

## ship-queue eligibility ≠ production activity

Queue eligibility answers only: **"Can an autonomous fixer implement and verify this without making an unresolved product/design choice?"** Activity belongs in grounding; priority belongs in scheduling; neither silently removes `ship-queue`. Rarely used paths with little prod activity but a known solution are valid `ship-queue` work once the author chooses to fix foundational correctness now.

## Owner distribution — regenerate from row truth

Row ownership is the **source of truth**; regenerate the distribution mechanically after every edit. Validate: every row appears exactly once; per-owner ready/decision/grounding/parked counts sum to the total; excluded owners have zero rows; "me" resolves to the author's GitHub login; explicit assignments override balancing. Use **recent code-ownership first**, explicit author constraints second, raw open-issue counts only as a weak tie-breaker (never as a capacity model).

## Per-row decision log

Expand every incremental author input into explicit per-row state **immediately** — do not rely on conversation memory. Each row persists:

```text
author_decision: approved | change-requested | pending
approved_priority:
approved_owner:
approved_recommendation:
approved_handoff:
last_author_input:
```

`ack`, "21–25 same as above; P1 and ship-queue", "the backend lead takes #1 and #6" (list positions, decode against the batch), owner swaps — expand each across all the rows it covers. **After every author message, re-render one refreshed complete table** — never return only the questioned subset when the author is converging a batch.

## Candidate author questions — classify, then filter

For every candidate question, persist:

```text
question:
owner: agent | author
why_not_agent_resolvable:
options_and_product_impact:
blocking_ship_queue: true|false
```

**Reject an author-input table that contains any `agent`-owned question.** Field manifests derivable from consumers, code naming, test placement, causal checks completable from code/logs/metrics, and generic "confirm scope" after scope was approved are all agent-owned — resolve them yourself. If no genuine author question remains, render an **explicit empty table** and report the batch decision-ready; do not invent a review ceremony.

## The workflow

1. Finish grounding; resolve all agent-owned questions.
2. Calibrate priority using the scheduling semantics.
3. For every row, write the ideal product behaviour + recommended outcome into the manifest.
4. Mark any surviving author decision as one exact question (never generic `held`).
5. Recommend an owner from the allowed pool; regenerate distribution mechanically.
6. `scripts/readiness-check.sh` green on every `ship-queue` row (evidence-manifest.md).
7. Present one complete numbered decision table (+ the backlog one-liner + the manifest path).
8. Persist every `ack`/change into the per-row decision log; re-render the full table.
9. Only after all selected rows are approved → filing.md.
