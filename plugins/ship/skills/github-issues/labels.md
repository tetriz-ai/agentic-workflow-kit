# Issue Labels, Fields & Triage Conventions

An **example** label taxonomy, the labelling principles behind it, and the Estimate / Priority /
Version conventions. Use your repo's own labels — list them with `gh label list` — and map the
sharp tests below onto them. The principles hold whatever the label names are.

GitHub label descriptions are capped at 100 characters, so keep the full scope of each label in a
reference file like this one. Update both the file and the GitHub label description when a
definition changes.

## Single-source-of-truth contract

**This file (`labels.md`) owns:** the example taxonomy and its sharp tests, the `bug` pairing
rule, the labelling principles, anti-patterns, and the Estimate / Priority / Version convention
narratives.

**[`SKILL.md`](SKILL.md) owns:** the settings, the project field lookup, the `gh` workflow
snippets, the hygiene checklist, and a one-line summary copy of the sharp-test table for fast
scanning. SKILL.md links here for everything else.

If a fact lives in this file, do not duplicate it in SKILL.md; add a link instead. If a fact lives in SKILL.md, do not duplicate it here.

---

## Example taxonomy

### Type labels — exactly one primary per issue

| Label | Sharp test |
|---|---|
| `feature` | Does this add a net-new capability (a user-visible surface, or a backend capability product code calls)? |
| `reliability` | Does this make the system survive a bad condition it currently fails on, or fix wrong / missing data on an existing surface? |
| `performance` | Does this measurably reduce latency, cost, or resource use on a flow that already works? |
| `observability` | Does this add new visibility for humans watching the production runtime (metric, dashboard, alert, log, trace)? |
| `tooling` | Does this change what engineers or operators CAN DO (build target, hook, CI check, script, config rollout)? |
| `ux` | Visual or interaction polish on an existing surface, where the data is correct? |
| `tech-debt` | Is this subtraction or reshape with zero net-new capability? |
| `bug` | Defect in existing behaviour. A modifier: pair it with one type label above. Solo `bug` is a triage failure. |

### Area labels — one or more, from your repo's top-level areas

| Label | Covers |
|---|---|
| `area:api` | The API layer and the services behind it |
| `area:web` | The user-facing web app |
| `area:infra` | Deploy, CI, and runtime infrastructure |
| `area:docs` | Documentation |

### Priority

`P0` / `P1` / `P2` / `Parked` — see [Priority convention](#priority-convention). On a project
board it is the `Priority` field; without a board, a `priority:P1`-style label carries it if your
repo uses one.

---

## Labelling principles

- **One primary type label per issue.** If an initiative spans several work types, decompose it
  into sub-issues (`addSubIssue` linkage), each labelled by its own scope.
- **`bug` is never alone.** Pair it with the type label you would pick if this were net-new work
  in the same place: a broken retry is `bug` + `reliability`, a broken build script is `bug` +
  `tooling`, a misaligned button is `bug` + `ux`.
- **`bug` does not pair with `feature`.** A defect uncovered while building a new capability is
  usually not a `bug` — fold it into the parent feature issue. Once a feature has shipped, a
  defect against it is filed against the type where the defect lives (`bug` + `reliability`, and
  so on).
- **Label what the change does, not where it lives.** Read the issue body and the linked PR's diff;
  directory paths and title prefixes are weak hints (see the grounding section in
  [`SKILL.md`](SKILL.md)).
- **If the change leaves something new behind, it is not `tech-debt`.** New runtime visibility is
  `observability`; a new engineer or operator capability is `tooling`; pure subtraction or reshape
  is `tech-debt`. Adding a build target is `tooling`; deleting a dead one is `tech-debt`.
- **Did the flow already work end-to-end?** Speeding up a healthy flow is `performance`. Making a
  failing flow succeed is `reliability` (often `bug` + `reliability`). A timeout fix is `bug` +
  `reliability`; a p95-latency cut on a healthy endpoint is `performance`.
- **The resilience element must be the goal.** Resilience elements are retry, timeout, rate-limit
  handling, circuit breaker, kill switch, idempotency, backpressure, error classification, auth /
  access checks, health gating, and retention-window correctness. If the issue would not exist without
  the resilience aspect, it is `reliability`. If the element is only built-in mechanism of net-new
  code (a new integration that bakes in rate-limit handling), the new code is `feature`.
- **Cross-cutting concerns use the dominant work type.** Security work has no dedicated label: a
  new dependency scanner in CI is `tooling`, a dependency bump for a CVE is `tech-debt`, a logic
  fix for a CVE is `bug` + `reliability`, new audit logging is `observability`.
- **Umbrella terms are categories, not labels.** "Infrastructure work" or "dev-ex work" is too
  broad to single-label. Apply the sharp test to the specific change. A design spike or RFC is
  labelled by the implementation domain it precedes. If the concrete examples under one umbrella
  span several labels, decompose.
- **Operational actions are not separately labelled issues.** A flag flip, a per-tenant config
  rollout, a manual secret rotation with an existing pipeline, a hotfix cherry-pick, a runbook
  execution, or a "ship" ceremony uses existing tooling and has no code artifact of its own. It
  rides on the parent issue as a Status transition. Exception: a multi-week or multi-customer
  phased rollout that needs its own coordination warrants a standalone `tooling` issue. This
  should be rare.

### `chore:` commit prefix does not map to `tech-debt`

The `chore:` prefix on a title or commit is a Conventional Commits convention - it says "not a
feature, not a fix." It does not decide the label. Apply the sharp tests to the actual change:

- `chore: set up dependency scanning in CI` -> `tooling` (new CI capability, not pure cleanup)
- `chore: remove unused vendor/` -> `tech-debt` (subtraction, no new capability)
- `chore: bump dependencies` -> `tech-debt` (reshape, no new capability)

---

## Anti-patterns

- Solo `bug` label with no type-label pair.
- Issue on the project with no `Version` set, when your board tracks releases by `Version`
  (invisible to release planning).
- Label that contradicts the actual scope (e.g. `tech-debt` on net-new capability - should be `feature`).
- `bug` on a defect uncovered while building new functionality - fold into the parent feature issue instead.
- **Epic-scale initiatives filed as a single monolithic issue.** A clear signal: the body lists 3+
  distinct goals OR touches 3+ different code areas OR estimate is `>= 5` days. Decompose via
  `addSubIssue` linkage: the parent carries the dominant label; each sub-issue gets its own.
- `chore:` / `feat:` title prefixes used as a signal to apply a label - apply the sharp tests to the actual change, not the conventional-commit prefix.
- Inferring label from issue title alone without reading the body or the linked PR's file changes. See "Grounding a label in the codebase" in [`SKILL.md`](SKILL.md).

---

## Estimate convention

Estimate is optional. Use it when your board has a numeric `Estimate` field (in days). For the
field lookup, see [`SKILL.md`](SKILL.md).

**Reading:** `0.05` means 0.05 day. `0.1` means 0.1 day. `1` means 1 day. `2.5` means 2.5 days.

### What a "day" means here (AI-first reading)

**Estimate = active wall-clock the human spent in the driver's seat.** Not calendar time. Not "human-team equivalent". When the agent runs the merge gate, a review subagent, or any background task in parallel, that time does not count. When the human is unblocked and working on something else while the agent grinds, that time does not count either. The metric is: from the moment you start engaging with this issue to the moment the PR is in review, how many work-hours of your own focused attention did it consume? Divide by 8 to get days.

A "human-team week" worth of code can land in 1-3 hours of focused human attention with an AI pair. Anchors below reflect that. If your gut estimate is borrowed from a pre-AI mental model ("this is half a day of engineering"), divide by 4-8 before writing the number down.

### Anchors

Any decimal value is fine. The table is a calibration aid, not an allowed-values list. Use values between rows freely (`0.07`, `0.15`, `0.4`, etc.).

| Estimate | Active wall-clock | Shape of work |
|---|---|---|
| `~0.05` | 10-20 min | one-shot tweak; single file; zero review iteration; no design call. Examples: one-line config flip, README typo fix, one-locator test fix |
| `~0.1` | 20-60 min | 1-3 file edit + doc + PR + 1 review pass; at most one design call; tight test surface |
| `~0.25` | 1-2 hr | 3-5 files; a real design decision or two; one HITL clarification loop; multi-step test plan |
| `~0.5` | 2-4 hr (half session) | broader test surface, OR new wiring/config, OR a new architecture check, OR a small DB migration; 2+ HITL loops |
| `~1` | full session | multiple unknowns to resolve in flight; schema / API contract change; integration test surface |
| `~2-3` | multi-session | RFC-adjacent design ambiguity; multiple HITL iterations; cross-service surface |
| `>=5` | epic | initiative-scale - decompose via `addSubIssue` unless the test / ship phase is the long pole |

### Bias-down rule

Between two adjacent anchors, **pick the lower one** unless the work has already exceeded the higher anchor's wall-clock. Concretely: if you are torn between `0.1` and `0.25`, default to `0.1` and revise only if the actual elapsed time blows past 2 hours. Underestimates surface as a one-line correction comment on the issue; overestimates silently inflate sprint capacity, hide AI-pair velocity, and pad release-planning math.

### Anti-patterns

- **Rounding to `0.25` / `0.5` because the work "has a PR and a review".** PR + review are the normal cost of every change, not premium. Do not pad for them.
- **Adding fudge time for HITL or ship coordination on a one-touchpoint task.** HITL *is* the work, not overhead bolted onto it. Count it once, in the wall-clock you already used, not as a separate adder.
- **Borrowing human-week intuition.** If you find yourself thinking "this is half a day of engineering work," divide by 4-8 before writing the estimate. "Two engineers, two days" in pre-AI thinking is often ~0.5 today.
- **Estimating from lines of code or files-touched count.** A 200-line diff with zero ambiguity is `0.05`; a 20-line diff that requires three product / arch decisions is `0.25`. Files and lines are the worst available signal.
- **Defaulting to `0.25` because it sounds polite.** The default is "the lowest anchor that still fits the actual elapsed time you observed", not "the smallest number that does not feel embarrassing".

### Calibration loop

Estimates only stay honest if they get corrected. After a PR merges, if the actual wall-clock was off by **≥2x** in either direction, note the delta in the next issue you file on the same kind of work. Estimates calibrate over time only if you keep an honest score.

## Priority convention

Priority is set on the board's `Priority` field (single-select). For the field lookup, see [`SKILL.md`](SKILL.md).

Priority is a judgment about **urgency — how soon this needs solving**, not about how
much it matters or how much work it is. Anchor every call on time-to-fix:

| Value | Means |
|---|---|
| `P0` | Fix in prod **now** — an active incident, or an urgent prod issue that cannot wait for the normal cadence |
| `P1` | **Default.** The normal working priority — solve in the current cadence |
| `P2` | Can wait **longer than a P1** — real work, lower urgency, not time-pressured |
| `Parked` | Explicitly parked — not now, may revive later; not deleted |

`P1` is the sanctioned default: `gh-issue.sh` sets it automatically, so most issues land
there and that is correct. The load-bearing signal is the **deliberate deviation** — and
because the auto-default is always set, a triage check that flags only *unset* fields will
not re-surface it, so judging the deviation is the filer's job at creation time: escalate
to `P0` for a real prod-now fix, relax to `P2` when the work can genuinely wait longer,
`Parked` when it is parked. Do not reach for `P0` because the work feels important, or
down-rank to `P2` because it feels small — both are urgency calls, nothing else.

Worked examples:
- Checkout down, or customers billed the wrong amount -> `P0` (fix in prod now)
- A normal bug or feature we are working this cadence -> `P1` (default)
- A polish item or improvement that can slip a release without harm -> `P2`
- An idea we are not committing to yet -> `Parked`

**Why keep `Priority` on a small team.** It is tempting to drop `Priority` and plan by `Version` alone. That sounds simpler but loses the quick-glance signal of *what to solve when*, independent of which release it lands in. Keeping `P0 / P1 / P2 / Parked` preserves that. Use `Parked` for work you are not committing to yet; it is cheaper than closing the issue and re-opening later.

## Version convention

Version is optional. Use it when your board has a `Version` field (single-select) that tracks
target releases. For the field lookup, see [`SKILL.md`](SKILL.md).

Issues without a version are invisible to release planning, so on a board that tracks it **every issue gets a real target release** — `gh-issue.sh` auto-resolves the current release (the most common Version among recent issues) and sets it. Only when a current release genuinely cannot be resolved (e.g. a fresh board with no versioned issues yet) does it use the `github_project_version_fallback` option, or leave Version unset when that setting is blank. Override with `--version` when the work clearly targets a specific future release.

---

For the operational guide (settings, field lookup, `gh` workflow snippets, hygiene checklist, sub-issue and PR linking), see [`SKILL.md`](SKILL.md).
