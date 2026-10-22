---
name: harness-education
description: >-
  Mines merged pull requests and their review threads for lessons worth keeping, and shows them as
  a table of candidates. A human picks which to keep, and only those ship, as a separate pull
  request for review. Nothing is added on its own. It runs only when the user invokes
  /review:harness-education. Suggest it when someone asks to pull lessons from recent work or to
  fold them into rules, skills or docs.
argument-hint: "[--since <date> | --prs <N,N,...>] [--author <handle>]"
disable-model-invocation: true
---

# harness-education — deliberate harness enrichment from shipped work

Shipping teaches — and because PR review is a lightweight approval, silently baking guidance
edits into the ship flow would let noise and wrong learnings ride in unexamined. So this
skill splits the concerns: detection is cheap and evidence-bound; incorporation is a
deliberate human act (the non-negotiables below carry both, normatively).

Sibling of `/learn:extract-taste` (same mine -> validate -> present -> human-promotes governance),
different substance: extract-taste surfaces an engineer's *working preferences*;
this surfaces *domain knowledge* attached to the code the team ships.

## Non-negotiables

1. **Never auto-incorporate.** The run STOPS at the presented table. No harness file is
   edited before a **human** picks — the pick must arrive as a user message (a direct reply
   or AskUserQuestion answer); a subagent, a parent agent, or the model's own continuation
   never satisfies this gate. In a headless/unattended run, persist the **full Step 5
   report** (candidate table + parked list + mining coverage) somewhere a human will find
   it — a GitHub issue titled `harness-education candidates <window>` (via
   `/ship:github-issues`) — and end without reaching Step 6; a later interactive session may
   *present* that posted table for the human pick (the same user-message gate applies),
   re-verifying anchors at current HEAD before applying (the code may have moved). An
   empty pick is a valid outcome.
2. **Evidence-bound, not introspective.** Every candidate cites the PR(s) / review thread /
   revert that evidences it. A learning with no artifact behind it is not a candidate.
3. **Dedupe before proposing.** A candidate must carry the existing-coverage verdict
   (`none` / `partial: <file>` / `full: <file>`) **bound to recorded search evidence** — the
   actual queries/patterns run and their hit-or-empty results, not just a list of files
   claimed read (a plausible file list with a bare `none` is still self-assertion; the
   recorded query + result is what a false verdict contradicts). Proposing what a loaded
   rule already says is the noise this skill exists to prevent; `full` coverage is
   reported, not re-proposed.
4. **Restraint on rules.** Guidance is load-bearing: every always-loaded line costs adherence
   everywhere else. Default to the **lightest home** that still lands where the next agent
   will actually be (taxonomy below). Prefer under-producing to rule bloat; when volume is
   high, propose fewer, stronger entries and park the tail in the run report.
5. **No hallucinated anchors.** Every file, symbol, path-glob, and rule ID a candidate edit
   references is verified to exist at current HEAD before it reaches the table.

## Target taxonomy — lightest home that fits

Pick per candidate by what the learning **is** (placement test: the repo's own docs placement conventions, if any),
biased down this list — reach higher only when the learning genuinely must hold for any
matching change:

| Learning shape | Home |
|---|---|
| mechanically checkable invariant | the repo's own lint rule or architecture test |
| must-hold constraint on a domain | **path-scoped** `.claude/rules/` entry (`paths:` = the surface's files) |
| arrival orientation for an area | one line in the area `CLAUDE.md` |
| a step agents skip in an existing procedure | a line in the owning skill's checklist |
| a reviewer blind spot — the rule exists (or ships with this batch) but the review layer never loads it | a review rule appended to the team rules file (the `team_rules_file` setting, which `/review:review-panel`'s team-rules lens reads), grounded on those rules |
| a judgment call reviewers made on two or more PRs (the same review comment, the same fix asked for) that no gate can check | a **review rule** appended to the team rules file, so the panel's team-rules lens asks for it on the next diff before a human has to |
| durable reference knowledge | the owning doc (e.g. the repo's data-model doc) |
| sharp edge at one code site | a *why* comment at that site (per the repo's comment conventions, if any) |

A candidate may also be "add a cross-link/pointer" — often the cheapest fix is making an
existing doc findable from where agents actually look.

## Procedure

### Step 1 — Resolve scope
- Window: `--since <date>` or `--prs <list>`; default the last 7 days. Author: `--author`
  or the invoker (`gh api user --jq .login`).
- Inventory (`<repo>` from `gh repo view --json nameWithOwner --jq .nameWithOwner`): `gh pr list --repo <repo> --author <handle> --state merged --json number,title,mergedAt --limit 200`
  filtered to the window — an explicit `--limit` well above the window's plausible PR count
  (`gh pr list` silently caps at 30 by default, dropping older PRs *before* the window
  filter runs); if the **raw fetch** returns exactly the limit (before the window filter),
  raise the limit and re-fetch — the filtered count is never evidence of coverage. **Always show the inventory (window + count + titles) before
  mining starts** — the operator redirects scope from the shown list, not from the agent's
  own "looks fine" judgment.

### Step 2 — Mine (fresh subagents, thematic fan-out)
- Group the PRs by theme/domain from their titles (e.g. frontend fetch-gating, DB modelling,
  query shape). One **fresh subagent per theme**, in parallel. Fresh matters: the author-agent
  pattern-matches to what it expects to find; a cold reader mines what is there.
- Each miner reads, per PR: the **body** (`gh pr view`), a **skim** of the diff (the file
  list plus the hunks the body and review threads point at — never dump it whole, never
  cap it at an arbitrary line count), and **all three review surfaces** — inline comments,
  review bodies, conversation — via the `/ship:pr-feedback` skill's fetch for PR `<n>` (the
  single fetch that drops none of them; a bare `pulls/<n>/comments` call silently loses
  review bodies). **Heed both of that fetch's truncation modes**: it warns when a surface
  overflowed its page size — a miner seeing that warning must paginate the remainder — and
  it cuts long comment bodies with an inline `[truncated` marker (full string:
  `… [truncated — open the comment for the rest]`) that fires no warning;
  a marked comment must be fetched in full (`gh api` / `gh pr view`) before the per-PR
  coverage note may claim the thread was read. Unpaginated overflow and truncated bodies
  are unread review data, not covered data. Reviewer/Codex findings are the highest-value friction signals. If a PR
  pair is an introduce-then-revert arc, extract the **decision rule** (when does the
  technique help vs hurt), not the episode.
- Each miner extracts **learnings, not summaries**: imperative do/don'ts that generalize
  beyond the one PR, each with evidence PR#s and a recurrence count. Each miner also dedupes
  against the existing coverage for its theme (the relevant `.claude/rules/*`, the team rules
  file, area `CLAUDE.md`s, owning skills — recording the queries run and their hit-or-empty results,
  per non-negotiable 3) and returns a compact table:
  `learning | evidence | recurrence | existing coverage (+ recorded queries/results) | suggested home | suggested paths: scope`
  **plus per-PR coverage**: every PR it was assigned, and for each that yielded nothing, a
  one-line note stating **what was read, by name** (the review-thread authors/IDs seen and
  the hunk file paths skimmed — checkable against the fetchable PR data, where a bare
  "body + N findings" count is a fillable template) — a "no durable learning" with no
  named read trail is self-assertion, same as a bare coverage `none` (non-negotiable 3),
  and an empty table with no coverage trail is a failed mine, not a clean one.

### Step 3 — Consolidate + rank
Merge the tables in this main context. Rank by: cross-PR recurrence (≥2 is the strong
signal — the RFC-drain's "caught more than once -> must graduate" trigger, applied across
PRs), then severity of the miss a future agent would repeat (a regression / false-green
trap outranks a nicety). A single-PR learning survives only if its **evidence artifact**
is one of: an introduce-then-revert pair, a reviewer-flagged regression / false-green, or
a constraint the diff itself enforces — the artifact type decides, not the miner's own
judgment of "sharpness". Everything else is parked, not proposed.

### Step 4 — Validate
Per surviving candidate:
- **Anchor check:** every referenced file / symbol / glob / rule ID exists at HEAD
  (`ls`, Grep, or LSP — actually run the check, and **record the lookup + result in the
  candidate's row**; a "verified" with no recorded evidence is contradicted by its own row.
  Non-negotiable 5). One deliberate carve-out: an anchor that is itself another of this
  batch's drafted edits (e.g. a lens grounding on a rule the batch introduces) is checked
  against that drafted edit, and the row records which candidate supplies it — the
  dependency then rides or falls with that candidate's pick.
- **Claim check:** re-read the evidencing PR's diff enough to confirm the learning states
  what actually happened (not a plausible paraphrase), and **record what supports it in the
  row**: the PR/thread link plus the specific hunk, comment, or excerpt that carries the
  proposition — so the human can spot-check a candidate without re-mining. For a candidate
  whose *truth* is a doc-style claim (a stated decision rule, a threshold), prefer a
  cross-model read — the same-model panel is weakest on doc-claim correctness; record its
  verdict in the row when used.
- Draft the **exact edit** (the rule body + `paths:`, the CLAUDE.md line, the checklist
  line, the comment) — the human picks from concrete edits, not abstractions. A review-rule
  candidate is drafted as an append to the team rules file, keeping the wording the file
  already has:
  `RULES=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get team_rules_file '${user_config.team_rules_file}')`

### Step 5 — Present + STOP (the conscious gate)
Present the curated table: candidate | exact proposed edit | home | evidence (PR#s +
recurrence) | existing-coverage verdict (+ recorded queries/results) | anchor-check evidence |
blast radius (what loads it, when). The report also carries **mining coverage** (N PRs
inventoried / read / yielding candidates, from the miners' per-PR trails) and lists what
was parked and why — transparency against silent dropping. Offer (as part of the pick,
never auto-filed) to record parked ≥2-recurrence candidates as normal GitHub issues so
they survive the session. Then **STOP for the human pick** (non-negotiable 1: a user
message, never a self-answer; headless runs end here).

### Step 6 — Apply the picks (separate PR, normal gates)
- Append each picked **review rule** with the helper, which gives it the next free id in its
  prefix, keeps the lens format, and refuses a duplicate title:
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/skills/harness-education/scripts/append-review-rule.sh" --file "$RULES" \
    --prefix DB --title "<title>" --statement "<one-line rule>" --apply-to "<files or diff shapes>" \
    --evidence "PR #<n>, PR #<m>"
  ```
- Apply only the selected edits, in a worktree, as **one focused harness-education PR**
  (`/queue:ship-task` with a just-in-time issue, or `/ship:pr` + the merge gate directly). Never fold them
  into an unrelated feature PR.
- Guidance edits have wide blast radius: the `/review:review-panel` pre-pr run (its blast-radius +
  judgment lenses) applies as usual; a new/changed SKILL.md additionally gets an
  unbiased **fresh-subagent vetting pass** (rigidity drift, scope, user-leak,
  review-by-attack) before commit — and the pass leaves an **auditable artifact in the PR
  body**: the reviewed commit SHA plus the vetting subagent's **verbatim returned findings**
  (pasted, not summarized — a zero-finding pass still lists what it attacked), and each
  finding's disposition (fixed / accepted-with-reason). A self-authored "vetting passed"
  summary is the self-assertion this artifact exists to contradict.
- The PR body carries the provenance table (learning -> evidence PRs) so the education is
  auditable back to the work that taught it.

## Boundaries (do not drift)
- **Not a backlog channel.** An improvement idea *unrelated to what the mined work taught*
  (a feature wish, a refactor itch) is filed as a normal issue, not smuggled in here.
- **Not `/learn:extract-taste`.** Personal working preferences go there; this skill carries only
  team-facing domain knowledge and needs no privacy scrub (inputs are team-visible PRs in
  this repo, and the outputs land in the same repo).
- **Not the RFC drain's terminal slice.** An RFC's Task Breakdown already owns its own
  harness-education slice; this skill covers everything that ships *outside* an RFC drain,
  and can also be run wider (a window of mixed work).
- Composes `/ship:pr`, the merge gate, `/queue:ship-task`, `/ship:github-issues` — never reimplements shipping.

## See also
- `/learn:extract-taste` — the preferences sibling; the repo's own docs placement conventions, if
  any — the placement test the taxonomy applies; the `/plan:tech-design-doc-writing` skill's Task
  Breakdown contract — the RFC-drain harness-education slice this ports to standalone work.
