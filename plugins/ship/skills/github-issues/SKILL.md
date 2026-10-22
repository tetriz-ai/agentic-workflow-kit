---
name: github-issues
description: >-
  Use when creating GitHub issues, linking pull requests to issues, applying labels or managing
  the project board. It covers creating issues and sub-issues, linking pull requests, keeping the
  board's fields tidy, an example label set, and the Estimate, Priority and Version conventions
  for the board the github_project setting names. Without a board it files plain issues.
---

# GitHub Issue & Project Management

Operational guide for creating issues in your repo, adding them to the project board when one is set, setting the board's fields, linking PRs, and keeping backlog hygiene clean - all via the `gh` CLI.

A well-triaged issue carries: one primary type label (with `bug` paired if it is a defect), and, when a board is set, `Priority`, `Status`, and the board's optional fields (`Estimate`, `Version`) — plus an `Assignee` and a body that explains what + why. The hygiene checklist below is the canonical list.

## Settings

Resolve the repo and the board once per session:

```bash
REPO=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get repo_slug '${user_config.repo_slug}')
[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
PROJECT=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get github_project '${user_config.github_project}')
```

- `repo_slug` — `owner/name` for every `gh` call (blank: the current repo, from `gh repo view`).
- `github_project` — `owner/number` of the GitHub Project to file issues into. **Blank means no
  board:** create issues with plain `gh issue create` and skip every board step below.

## Single-source-of-truth contract

**This file (`SKILL.md`) owns:** the settings, the project field lookup, the `gh` workflow snippets, the canonical hygiene checklist, and a one-line summary copy of the sharp-test table for fast scanning.

**[`labels.md`](labels.md) owns:** the example taxonomy and its sharp tests, the `bug` pairing rule, the labelling principles for tricky boundaries, anti-patterns, and the Estimate / Priority / Version convention narratives.

If a fact lives in this file, do not duplicate it in `labels.md`; add a link instead. If a fact lives in `labels.md`, do not duplicate it here.

---

## Project board

Skip this section when `github_project` is blank.

Field and option IDs are looked up **at run time by name**, never hard-coded — a renamed board or
a new option needs no change here:

```bash
OWNER=${PROJECT%/*}; NUM=${PROJECT#*/}
gh project view "$NUM" --owner "$OWNER" --format json --jq .id          # project ID (--project-id)
gh project field-list "$NUM" --owner "$OWNER" --format json \
  --jq '.fields[] | {name, id, options: [.options[]? | {name, id}]}'     # field + option IDs by name
```

If your board has views filtered by label, the label you pick routes the issue into the right
backlog automatically. If it tracks releases by `Version`, the `Version` you pick decides which
release-planning bucket it falls in.

---

## Labels - work-type taxonomy (quick reference)

The table is the **example** taxonomy from [`labels.md`](labels.md). Use your repo's own labels
(`gh label list`) and map the sharp tests onto them. Every issue carries exactly one primary type
label. `bug` is orthogonal - never used alone, always paired.

| Label | Sharp test |
|---|---|
| `feature` | Does this add a net-new capability (a user-visible surface, or a backend capability product code calls)? |
| `reliability` | Does this make the system survive a bad condition it currently fails on, or fix wrong / missing data on an existing surface? |
| `performance` | Does this measurably reduce latency / cost / resource use on a flow that already works? |
| `observability` | Does this add new visibility for humans watching the production runtime? |
| `tooling` | Does this change what engineers or operators CAN DO with the toolchain? |
| `ux` | Visual or interaction polish on an existing surface, data is correct? |
| `tech-debt` | Is this subtraction or reshape with zero net-new capability? |
| `bug` | Defect in existing behavior. Pair with one above. Solo `bug` is a triage failure. |

Add one or more area labels (`area:*`, from your repo's top-level areas) for where the change lands.

**For area labels, the `bug` pairing rule, the labelling principles for tricky boundaries** (e.g. `tech-debt` vs `tooling`, `reliability` vs `performance`, `chore:`-prefix mistakes, security work) **and anti-patterns - see [`labels.md`](labels.md).**

---

## Grounding a label in the codebase

Sharp tests answer the conceptual question; the actual change tells you which test applies. Before applying any label:

1. **Read the issue body fully.** Most labels become obvious from a careful read.
2. **Read the linked PR if any** - `gh pr view <N> --repo "$REPO" --json files,body --jq '{files: [.files[].path], body: .body}'`. The diff is ground truth; the issue body may be aspirational.
3. **Ask what the change DOES to the system** (not where the code lives in the tree). Then apply the sharp test in `labels.md`.

Directory paths are a weak hint, not a decision. A frontend directory often holds both user-facing code AND engineer-facing test infra; a backend directory often holds both internal-only services AND the API layer that powers user-visible endpoints. Branching on directory is just a fancier version of branching on title prefix - both miss the actual change.

### Grounding anti-patterns

- Inferring label from title prefix alone (`chore:` does not mean `tech-debt`; `feat:` does not mean `feature`).
- Inferring label from directory path alone (end-to-end tests live next to the frontend but are not product work).
- Labeling without reading the issue body or linked PR diff.
- Picking a label because it sounds about right instead of running the sharp test against the actual change.
- Picking the first label that fits when a multi-domain issue would be better decomposed into sub-issues.

---

## Label decision flow

Use this flow on every issue, mapped onto your repo's labels.

**Q0 - Decompose check.** Is the issue epic-scale (≥5 days OR 3+ distinct goals OR 3+ code areas)?
- Yes -> DECOMPOSE via `addSubIssue` linkage. Parent carries the dominant label; each sub-issue is labelled independently by its own scope. **Split along distinct shippable goals** — one sub-issue per independently-mergeable goal (a sub-issue spanning 2 code areas is fine; a sub-issue carrying 2 goals should split again). On a board, the **parent** carries `Version` (release-tracking) but leaves `Estimate` unset — the estimate lives on the sub-issues, summing it on the parent double-counts. STOP.
- No -> continue.

**Q1 - Ground in code.** Read the issue body, the linked PR's diff, and what the change actually does to the system. Do not skip this step.

**Q2 to Q8 - Type label (first YES wins; order is intentional).**

- **Q2** Is the work PRIMARILY about a resilience element (retry / timeout / rate-limit / circuit-breaker / kill-switch / idempotency / backpressure / error-classification / auth / health-gate / retention-window correctness), or about an existing surface showing wrong / missing data? "Primarily" means: would the issue exist if the resilience aspect wasn't broken or missing? If the element is only built-in mechanism of net-new code (e.g. a new integration that bakes in rate-limit handling), the answer is NO. -> `reliability`
- **Q3** Net-new capability — a user-visible one, or a backend one product code calls? -> `feature`
- **Q4** Adds new production-runtime visibility (metric / dashboard / alert / log enrichment / trace)? -> `observability`
- **Q5** Changes what engineers or operators CAN DO (build target, hook, CI check, config rollout, dev script)? -> `tooling`
- **Q6** Measurably faster / cheaper on a flow that already works? -> `performance`
- **Q7** Visual / interaction polish on an existing surface, data correct? -> `ux`
- **Q8** Pure reshape / subtraction with zero net-new capability? -> `tech-debt`

**Q9 - Defect check.** Is this fixing a defect in existing behaviour? Yes -> also add `bug`. A defect uncovered while building a new capability folds into the feature issue instead.

**Q10 - Area.** Add the area label(s) for where the change lands.

**Q11 - Final sanity check.** `bug` is never alone. If you have `bug`, you must have one of the type labels too.

---

## Project fields - quick reference

Board fields, looked up by name with the snippet in *Project board*. Your board's names may
differ; map them.

| Field | Type | Notes |
|---|---|---|
| Status | SingleSelect | See the status names below |
| Priority | SingleSelect | `P0` / `P1` / `P2` / `Parked` - meaning in [`labels.md`](labels.md#priority-convention) |
| Estimate | Number (optional) | Decimal days, AI-first reading - see [`labels.md`](labels.md#estimate-convention) |
| Version | SingleSelect (optional) | Release tracking - see [`labels.md`](labels.md#version-convention) |
| Labels | n/a (on issue, not project) | Set via `gh issue create --label ...` or `gh issue edit --add-label ...` |

### Status names

| Status | When to use |
|---|---|
| Todo | Newly created, not started |
| In Progress | Work has begun |
| Blocked | Dependency or decision pending |
| In Review | PR raised |
| Done | PR merged / work complete |
| Invalid | Won't fix / not real work |
| On Hold | Paused, expected to resume |

Use your board's own option names; look up their IDs with the field-list snippet.

### Estimate

Optional. Decimal days, measuring **active wall-clock the human spent in the driver's seat** (not calendar time, not human-team-equivalent). Any value is valid (`0.05`, `0.1`, `0.25`, `0.5`, `1`, `2.5`, …). Bias DOWN between adjacent anchors. AI-first reading, anchor table, bias-down rule, anti-patterns, and the calibration loop: see [`labels.md`](labels.md#estimate-convention).

---

## Workflow

### Before filing - is this a labeled work-item at all?

Some work does not warrant a separate labeled issue. Run this check first:

- Is this just a Status transition or "ship" ceremony on an existing tracked feature? -> No new issue; update the parent's Status.
- Is this an operational action that uses existing tooling rather than producing new code (flag flip, per-tenant config rollout, manual secret rotation, runbook execution, cherry-pick)? -> No new issue unless it requires multi-week / multi-customer coordination of its own (rare). See "Operational actions are not separately labelled issues" in [`labels.md`](labels.md#labelling-principles).
- Is this a question, support request, or feature request from outside the engineering org? -> Capture in the appropriate intake channel, not as a labeled engineering issue.
- Is this a sub-aspect of work already tracked elsewhere? -> Add as a sub-issue of the parent, or fold into the parent's body.

If none of the above apply, continue to Step 1.

### 1. Ground the label and write the body

Run the label decision flow above to pick the primary type label
(+ `bug` if it is a defect). Title convention: conventional-commit prefix (`feat:`,
`fix:`, `chore:`, `docs:`, `refactor:`, `test:`), under 70 chars, imperative mood.
The `chore:` prefix does NOT decide the label — apply the sharp tests to the actual
change (see [`labels.md`](labels.md#chore-commit-prefix-does-not-map-to-tech-debt)).

Body — for a normal issue, a `## Summary` (what + why, 2-3 sentences) and a
`### Requirements` list, plus a `### References` section (PR / ADR / related). For an
**implementable task issue** (an RFC slice, or any standalone task `/queue:ship-task` takes
end-to-end), the lean body is not enough — use the richer **task-brief** body from the
task-brief template in the `task-breakdown` skill; it doubles as the agent brief
`/queue:ship-task` feeds its sub-agents, so it must carry the grounding (PRD / RFC + slice /
parent / related), the scope, the acceptance / demoable proof, the HITL/AFK tag, and
depends-on. An RFC's Task Breakdown maps 1:1 onto that template.

### 2. Create + triage in ONE call — `gh-issue.sh`

**With a board** (`github_project` set), use the engine
`"${CLAUDE_PLUGIN_ROOT}/skills/github-issues/gh-issue.sh"` — it creates the issue, adds
it to the board, and sets Status / Priority / Version / Estimate in one call, printing a
single compact result line (`ISSUE: #N <url>` + the fields it set). Do not hand-run the
create → item-add → item-id → field-edit sequence (the script header explains what that costs).

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/github-issues/gh-issue.sh" create \
  --title "feat: short descriptive title" \
  --label "tooling" \
  --body-file /path/to/body.md
```

- Repeat `--label` for a paired `bug` (or another axis, such as an area label). `--body-file` (or `--body "…"`) is optional — it defaults to the title.
- Optional flags: `--assignee <user>` (default `@me`) · `--priority P0|P1|P2|Parked` (default `P1`) · `--version <name>` (default: current release, auto-resolved) · `--estimate <days>` (default `0.1`) · `--status <name>` (default `Todo`; pass `In Review` if a PR already exists).

**Without a board** (`github_project` blank), create a plain issue:

```bash
gh issue create --repo "$REPO" --title "feat: short descriptive title" \
  --label "tooling" --assignee @me --body-file /path/to/body.md
```

The defaults make routine filing round-trip-free, but two fields still take your judgment
when the case is not routine — pass the flag then, do not lean on the default:

- **Priority defaults to `P1`** — correct for normal-cadence work. The default cannot
  judge urgency, so **pass `--priority`** when the work is plausibly `P0` (fix in prod
  *now* — active incident / urgent prod issue) or `Parked` (not committing to it yet); `P2` is for work
  that can wait longer than a P1. See [`labels.md`](labels.md#priority-convention).
- **Version auto-resolves to the current release** (the most common Version among the
  most-recent issues) and is set — a real version. It is a
  **lagging** signal: right after a release is cut, or for work targeting a future release
  / backport, it names the *old* release, so **pass `--version`** at release boundaries or
  when the target differs. Preview it with `gh-issue.sh version`. Only when no current
  release can be resolved at all does the engine use the `github_project_version_fallback`
  setting, or leave Version unset when that setting is blank.
- **Estimate defaults to `0.1` day** — bias DOWN (see [`labels.md`](labels.md#estimate-convention)); pass `--estimate` for anything larger.

The engine fetches field and option IDs **live** from the board by name (a new Version option
needs no change), validates an explicit `--version` against a real option *before*
creating the issue (no orphan on a typo), and resolves the item via the issue's own O(1)
`projectItems` edge (never a board scan). If any field cannot be set it prints a `WARN`
line naming the field(s) **and exits non-zero** — the `ISSUE: #N` line prints first, so
the URL is never lost; fix the flagged field by hand. For fields the engine does not set,
or manual edits, look up the field and option IDs by name (see *Project board*) and use
`gh project item-edit`.

Fix a wrong label, or retro-label a batch, later:

```bash
gh issue edit <N> --repo "$REPO" --remove-label "<old>" --add-label "<new>"
gh issue list --repo "$REPO" --label "<old>" --state open --limit 100 --json number --jq '.[].number' \
  | xargs -I {} gh issue edit {} --repo "$REPO" --remove-label "<old>" --add-label "<new>"
```

### 3. Create sub-issues

Create the child issue first (Step 2), then link to its parent (substitute the
real issue numbers for `<PARENT>` / `<CHILD>`; re-running on an already-linked
pair, or a sub-issue that already has a different parent, returns a GraphQL error):

```bash
gh api graphql -f query='
mutation {
  addSubIssue(input: {
    issueId: "'$(gh issue view <PARENT> --repo "$REPO" --json id --jq .id)'"
    subIssueId: "'$(gh issue view <CHILD> --repo "$REPO" --json id --jq .id)'"
  }) {
    issue { number }
    subIssue { number }
  }
}'
```

Each sub-issue gets its own label, Priority, Estimate, and Version - they are not inherited.

**When all sub-issues of a parent are deprioritized.** Move the parent out of `Version` tracking (clear `Version`). Set `Status` to `On Hold` if the parent may revive later, or close as `Invalid` / `Done` with an explanatory comment if not. Closing while sub-issues remain `On Hold` is also fine - the parent's role is to group; sub-issues track their own state.

### 4. Link a PR to its issue

Add `Closes #NNN` to the PR body - GitHub auto-closes the issue on merge and, on a board, moves it to Done. Treat this link as **mandatory for any PR targeting the base branch** (`/ship:pr` asks for it every time); your merge gate, if it has one, may block the merge without it. There is no `no-issue` escape hatch.

```bash
BODY=$(gh pr view <PR> --repo "$REPO" --json body --jq .body)
gh pr edit <PR> --repo "$REPO" --body "${BODY}

Closes #NNN"
```

For PRs that relate to but don't fully resolve an issue, use `Ref #NNN` instead.

---

## Hygiene checklist

A well-triaged issue carries:

- [ ] **Label** - exactly one primary type label; `bug` paired if defect (see [`labels.md`](labels.md))
- [ ] **Priority** - P0 / P1 / P2 / Parked (board field, or your repo's priority label)
- [ ] **Estimate** - optional; decimal days, AI-first reading
- [ ] **Version** - optional; a real target release (auto-resolved by `gh-issue.sh`); the `github_project_version_fallback` value only as a last resort
- [ ] **Status** - on a board: Todo for new, In Progress when started, In Review when PR is up
- [ ] **Assignee** - owner identified
- [ ] **Sub-issues** linked if there are child tasks
- [ ] **PR linked** via `Closes #N` when PR exists
- [ ] **Body** - Summary section explaining what and why

A triage check that flags incomplete issues should treat the anti-patterns in [`labels.md`](labels.md#anti-patterns) (solo `bug`, contradictory labels, and so on) as triage failures.
