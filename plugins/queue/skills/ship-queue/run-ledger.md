# ship-queue — run-ledger + token isolation

On-demand detail for **Step 0** (init) and **Step 3/4** (per-issue updates). The ledger plus the GitHub state (open issues, linked PRs, `<!-- ship-queue:blocked v1 -->` markers) are the run's **durable recovery state**. The main loop holds **only** the ledger — heavy findings, diffs, and lens output live on disk in subagent-written files, never in the token window — so after a context compaction the loop reconstructs from ledger + GitHub rather than from in-context memory.

## The ledger file

Path: `<main-checkout>/.claude/triage/run-<label>-<run-scope>.md` — under the gitignored `.claude/triage/`, so it is local run state, never committed. **`<run-scope>` is the owning Claude session: `<YYYY-MM-DD>-<session-id>`** (`$CLAUDE_CODE_SESSION_ID`, the full session UUID — never truncated, or the resume glob below would over-match; the date prefix is only for human-scannable ordering), e.g. `run-ship-queue-2026-01-15-1b2c3d4e-0000-4000-8000-000000000000.md`. One session owns one run, so the ledger name is **unique by construction for every run type** — pick-list, `--integration-branch`, plain full drain, or an interactive pick off the Step-1 table — with no dependence on the (variable-length, and for an interactive pick not-yet-known-at-init) issue set. Two sessions in separate worktrees therefore never share a ledger, whatever they drain: there is no per-run-type encoding, no hashing, and nothing to defer — the name is fixed at Step-0 init from `$CLAUDE_CODE_SESSION_ID`, and the picks (whenever chosen) just fill in rows. (If `$CLAUDE_CODE_SESSION_ID` is ever unset, substitute any per-run-unique token — e.g. a UTC timestamp — and carry it in `--session` the same way; the resume path only needs the token to match what the header records, not that it is specifically a session id.)

**Session scoping fixes ledger collisions, not double-processing.** Because each session gets its own ledger, even two concurrent full drains of the *same* label never clobber a shared file. What it does **not** prevent is two such drains doing the *same work* (double-opening PRs on the same issues) — that would need a per-`<repo>:<label>` concurrency lock, and there is none. So don't run two full drains of the same label at once — the reason is duplicated work, not a corrupted ledger.

**Resume targets the ORIGINAL session's ledger, never the resuming session's.** A cron-fired or manual `--resume` runs in a *new* session with a *new* `$CLAUDE_CODE_SESSION_ID`, so it must **not** name the ledger from its own id. The `# resume-cmd:` line and the dead-man cron both carry the original run's session id (`/queue:ship-queue --resume --session <orig-session-id> …`); a resume with it locates the ledger by globbing `.claude/triage/run-<label>-*<orig-session-id>.md` (the session id is unique, so this matches exactly one, whatever the date prefix). A bare `/queue:ship-queue --resume` with no session globs `.claude/triage/run-<label>*.md` and disambiguates by reading each candidate's `# resume-cmd` header (or asks). Never derive the ledger name from the resuming session's own id.

**Pin it to the launching/main checkout, not the cwd:** `.claude/triage/` does not cross worktree boundaries (gitignored, per-worktree), and the loop cuts a per-issue worktree in Step 3 — so resolve the dir once via `git rev-parse --git-common-dir` (the shared `.git`, whose parent is the main checkout, the same trick `statusline-capture.sh` uses) and always read/write the ledger there. A ledger written into a per-issue worktree's `.claude/triage/` is invisible to a later resume from the main checkout, which would then reconstruct from a stale ledger and redo or skip the wrong issue. One row per issue the run touches:

```markdown
# ship-queue run — label=<queue-label> scope=<author> session=<session-id> started=<ISO>
# resume-cmd: /queue:ship-queue --resume --session <session-id> <original args>
# integration=<integration/rfc-name> base=<base_branch> synced=<ISO>   ← only in --integration-branch mode

| slice | issue | PR# | gate | panel | codex | merge | blocker | status |
|---|---|---|---|---|---|---|---|---|
| — | #123 | 130 | green | lenses=[blast-radius,team-rules] skipped=[] @ a1b2c3d · clear | done-clean | — | — | done |
| — | #124 | — | — | — | — | — | scope-increase | blocked |
| — | #125 | 131 | green | lenses=[correctness,runtime-attack,simplification,security,architecture-rules,team-rules] skipped=[] @ e4f5a6b · C:1 → cleared | done-replied | — | — | done |
| F1a | #126 | 132 | green | lenses=[…] skipped=[] @ 9c8d7e6 · clear | done-clean | a1b2c3d | — | done |
| C2t | — | — | — | — | — | — | waiting-on F1a | waiting |
```
(The first three rows are pre-filed-queue mode — `slice` is `—`. The last two are a `--from-rfc` drain: a done slice `F1a` carrying its slice ID + JIT issue + merge SHA, and an **un-created** waiting slice `C2t` keyed by slice ID alone, no issue yet, waiting on `F1a`.)

Columns:
- **slice** — (`--from-rfc` mode) the RFC Task-Breakdown **slice ID** (e.g. `F1a`, `C2t`). It is the **durable key for a slice before its issue exists**, and what lets a later promotion translate a slice-ID dep (`F1a`) into the already-created issue's `#N`, and lets Step-6.5 self-verification match RFC table rows to ledger rows after context loss. A `waiting` from-rfc row may have `slice` set with `issue` still `—` (un-created). `—` in pre-filed-queue mode.
- **issue** — the issue number (`—` for an un-created `--from-rfc` slice that is still `waiting`; keyed by `slice` until created).
- **PR#** — the PR once opened (`—` until then).
- **gate** — the merge gate: `green` only when fully green; otherwise the failing check(s).
- **panel** — the per-PR **lens manifest** plus the reviewed SHA and the finding count: `lenses=[…] skipped=[…] @ <reviewed-sha> · C:<n> I:<n>` (→ `cleared` once C/I fixed; `clear` if the panel found nothing). The `lenses=`/`skipped=` manifest (SKILL.md Step 3) is the audit trail that the **full fitting set** actually ran — the routing read from `/review:review-panel` Step 2, not a hand-picked subset. `skipped=[]` is the norm; any entry must carry its review-panel skip-whitelist reason. **A row cannot flip `done` if the manifest shows a fitting lens silently dropped** (e.g. the judgment lens absent on a non-docs diff, `matcher` absent on a regex/glob change). The trailing **`@ <reviewed-sha>` is the HEAD commit the panel last reviewed** — `/review:review-panel` itself **does not post to the PR** (its soft boundary), so this cell is the only durable record of *which* commit was reviewed; a resume or a human compares it against the PR HEAD to detect a **stale panel** (HEAD moved past the reviewed SHA). `/ship:pr` surfaces the same SHA in the PR Validation section (so the durable record is PR-visible without review-panel posting).
- **codex** — the sweep stop-state (`done-clean` / `done-reviewed` / `done-replied` / `codex-limited`; the authority for this set is the `/ship:codex-sweep` skill's fetch signal) — **plus `no-show`**, the loop's own terminal written when `await`'s bounded wait is exhausted with no Codex review (Codex never picked the PR up). `no-show` is a degraded-but-safe stop-state: the PR shipped behind the merge gate + the panel, and it keeps the next-issue gate (SKILL.md Step 3.5) from wedging on a PR Codex never reviews. **A manual `skipped (usage-capped)` is *not* a valid value of this cell** — a usage cap resolves to `codex-limited` (the detector catches a cap notice in a review body too) or, if the wait is exhausted, `no-show`; the merge step (Step 3.6) treats only the genuine terminals above as settled, so a `skipped` note never `⚙`-merges.
- **merge** — **`--integration-branch` mode only:** the **merge-commit SHA** of this slice onto the integration branch (Step 3.6), `—` until merged. This is the **durable, git-checkable proof** a dependent's dep is satisfied — readiness and self-verification re-derive from reachability of this SHA, never from a `done` string alone. Flat mode leaves it `—`.
- **blocker** — the `blocker-protocol.md` tag if blocked; **or, in integration mode, `waiting-on #M[,#K]`** (the unmet deps) for a `waiting` row, or `waiting-on #M (unresolved: …)` for a missing/out-of-scope dep; else `—`. `waiting-on …` is **not** a `blocker-protocol` tag — it posts no marker and auto-promotes (below).
- **status** — `in-progress` / `done` / `blocked` / `skipped` / **`waiting`** (integration mode: deps not yet satisfied — parked, marker-free, auto-promotes) / **`excluded`** (an operator removed the slice from this drain — e.g. a terminal testing or rollout slice deferred to "something separate"). An `excluded` slice never ships here, but it is **not silent**: Step 6.5 surfaces it as an explicit **coverage gap** in the final report, so shipping without that slice's coverage (an integration suite, a rollout runbook) is a conscious operator decision, not an omission no one sees. **`excluded` must be bound to operator evidence, never self-granted** — it is set only from an explicit `--exclude <slice>` run flag or a durable operator marker on the slice's issue/RFC row (a git/GitHub-checkable artefact), so the loop cannot mark a slice `excluded` to dodge a hard terminal. Step 6.5 verifies that backing exists; an `excluded` row with no flag/marker is itself a **divergence** (flag it), not an accepted gap.

## The flip rule (what makes a row `done`)

A row flips to `done` **only** when all three hold — this is the per-issue quality gate, enforced by this checklist + the ledger, **not** by `/goal` (which only keeps the loop alive):

1. **panel** Critical **and** Important findings are cleared (fixed, or refuted with evidence) — Minor may remain.
2. **gate** (the merge gate) is fully `green`.
3. **codex** sweep reached a stop-state.

A row that does not meet all three is **not** `done` — it is `in-progress` (still working), `blocked` (marker posted, moved on), `skipped` (already had an open PR / was `In Review`), or — integration mode only — `waiting` (deps not yet satisfied). Never write `done` on a partial pass.

**`--integration-branch` mode adds a fourth condition:** a slice is not `done` until it is also **merged onto the integration branch with its `merge` SHA recorded** (Step 3.6). A dependent may treat this slice's dependency as *satisfied* only once that SHA is reachable from the integration branch — not on the three-condition `done` alone. So in integration mode, "gated" (panel+gate+codex green) and "done" are distinct moments: gated → merge onto integration → record SHA → `done`.

## Token isolation — bounded subagent returns

The cheap-trigger-in-main / expensive-cognition-in-subagent split is the SKILL.md "execution model" — do not restate it here. This section owns only the **on-disk mechanics** that make the bounded returns work.

### Panel findings on disk

When the review-cadence nudge fires, run the panel with **full-lens rigor** (SKILL.md Step 3 — `/review:review-panel` owns which lenses fit the diff; do not hand-pick a subset). Bound the returns: each lens subagent **writes its findings to `.claude/triage/panel-<issue>/<lens>-<round>.json`** (`/review:review-panel` Step 3 owns the naming) (keyed on the issue — the panel fires before the PR exists) and **returns a one-line count** (`<lens>: C<n>/I<n>/M<n>`). The main loop reads only the **consolidated Critical/Important set** — for each lens, the **highest-numbered** `<lens>-*.json` only, filtered to C/I. Earlier rounds stay on disk solely for `/review:review-panel`'s regression diff; re-reading them would resurface findings a later round already verified fixed and the slice could never clear — the full finding bodies never enter the main context.

```
.claude/triage/panel-<issue>/
├── correctness-1.json   # [{severity, regression_of, file, line, finding, ...}, ...]
├── security-1.json
└── simplification-1.json
```

A **converged finding** (≥2 independent lenses flag the same thing) is **not** self-clearable — verify it against source or build a repro before the row's panel column may read `cleared` (SKILL.md Step 3).

## Adjacent findings — out-of-slice escalation channel

A grounding or panel subagent often spots an **initiative-relevant defect outside its slice's diff** — a pre-existing bug in a sibling file, a systemic auth gap, a race the slice brushes against. Keeping the change surgical correctly stops it from *fixing* that out-of-scope — but with no channel to *report* it, the finding gets dropped or buried in prose and is only re-discovered by hand later. The brief is a capped four-field template with **no fifth field** (SKILL.md Step 2), so the escalation is a **separate structured return, not a brief field**:

- **The subagent emits, the main loop files.** A grounding/panel subagent that finds an out-of-slice initiative-relevant defect it must *not* fix in-slice **appends a structured row to `.claude/triage/adjacent-<issue>.json`** (a JSON array, in the main-checkout `.claude/triage/` — same pinning as the ledger) and notes the count in its bounded return (`adjacent: N`). It does **not** file the issue itself — filing is a write op, and writes stay in the main loop (the execution model). Empty is the norm; the channel exists so a real out-of-scope finding is never silently dropped.
- **Row shape** — `{ at, found_by (issue + "grounding"|"<lens>"), symbol (grep-able file:line + identifier), what (the defect, one line), why_initiative_relevant (why it matters to *this* initiative, not a generic nit), filed_issue ("—" until filed) }`. `why_initiative_relevant` is the gate against noise: a generic style nit is **not** an adjacent finding; an initiative-relevant defect is.
- **Auto-file under the parent, idempotently.** At the next clean checkpoint the main loop reads each in-flight `adjacent-<issue>.json`, and for every row whose `filed_issue` is `—` **files a follow-up issue** via `/ship:github-issues` (task-brief template, the row as its grounding) **linked to the parent** — a sub-issue of the slice's issue, or `Part of #<parent>` when sub-issue linkage is unavailable — then writes the new `#N` back into the row. Idempotency is the `filed_issue` cell: a row already carrying a `#N` is never re-filed (so a resume/compaction never double-files). Mirror each filed row into the ledger `## adjacent findings` table so the durable run-state carries it.
- **Ledger mirror:**
  ```markdown
  ## adjacent findings
  | at (ISO) | found-by | symbol | what | filed-issue |
  |----------|----------|--------|------|-------------|
  | 2026-01-15T09:10 | #123 grounding | orders.go:254 logger.Warn | swallows a lifecycle error where fail-loud is expected | #130 |
  ```
- **Self-verification (Step 6.5):** a row whose `filed_issue` is still `—` after its `found_by` issue has shipped is a **dropped escalation** — surface it (the finding was emitted but never filed); a row carrying a `#N` must point at a real issue (open or closed), not a phantom number. **Honest limit:** this guards only an *emitted-but-unfiled* finding; whether a real out-of-scope defect was emitted **at all** is not verifiable here — "no adjacent findings" rests on the subagent's grounding rigor, not a falsifiable check.

## Reconstruct after compaction / on resume

If the main context was compacted (or this is a `--resume`), rebuild loop state from disk + GitHub — do **not** trust in-context memory:

0. **Self-verify first (SKILL.md Step 6.5).** Before trusting any row, run the unbiased re-derivation below ("self-verification") — a ledger written before a crash can be stale, and a wave must never advance on an unverified `done`. Correct the ledger to ground truth, *then* proceed.
1. Read the ledger — locate it by the **original** run's session id carried in `--resume --session <id>` (glob `.claude/triage/run-<label>-*<id>.md` — the id is unique, so exactly one match); a bare `--resume` instead globs `.claude/triage/run-<label>*.md` and disambiguates by the `# resume-cmd` header (see "The ledger file"). Never use the *resuming* session's own id. Only `done` and `skipped` rows are **settled**; do not redo them. A `blocked` row is **not** settled: a human may have answered the blocker since, so it must be re-evaluated every resume (treating it as settled would strand a resolved blocker until someone hand-edits the ledger — defeating the durable-state resume). A **`waiting` row is also not settled** — re-derive its readiness every resume (a dep may have merged); unlike `blocked` it needs **no** human reply to promote (see below).
2. Re-resolve the queue (SKILL.md Step 1, same label/scope). For each open in-scope issue that is **not** a settled (`done`/`skipped`) ledger row — including every `blocked` row: apply the Step 1 precheck (skip if it has an open PR / is `In Review`/`Done`) and the `blocker-protocol.md` resume rule (a `blocked` issue is picked up only if a resolving human reply postdates its marker; otherwise it skips again and stays `Blocked`).
3. An issue that is `in-progress` in the ledger was interrupted — and its resume artifacts are all **issue-keyed and derivable**, so nothing extra need be stored per row: brief `brief-<issue>.md`, panel dir `panel-<issue>/`, and worktree `.claude/worktrees/ship-queue-<issue>/` (the deterministic name SKILL.md Step 3 pins — without it the interrupted worktree is unfindable after compaction, so the loop would cut a second one and strand the uncommitted fix). Then, by whether that worktree exists yet: **if it does**, `cd` in and inspect `git status` / `git stash list` for partly-applied **uncommitted** work, then resume where it left off; **if it does not** — the run was interrupted after Step 2 wrote the brief but before Step 3 cut the worktree — that is a valid checkpoint, not an error: cut the worktree now (Step 3) and resume from the brief. Either way, don't re-ground from scratch or cut a *second* worktree/PR.
4. **`--integration-branch` mode:** re-derive every `waiting` row's readiness from git reachability of its deps' `merge` SHAs (below), promote any now-satisfied, and apply any pending operator directive (course-correction below). If a full pass promotes zero rows AND the ready set is empty AND `waiting` is non-empty ⇒ **stop and report a dependency cycle / unmet external dep** (SKILL.md Step 4) — never spin.
5. Continue the loop. The ledger is also the **Done report** (SKILL.md "Done").

## Integration-branch drain — model + the `git merge` mechanism

`--integration-branch <name>` drains a whole RFC Task Breakdown (many `Depends-on`-chained slices) onto one long-lived **integration branch** cut from the base branch, then opens **one** human-reviewed integration→base-branch PR. Slice branches are cut **off integration**, slice PRs target it, and a gated slice is **merged onto it by ship-queue itself** so dependents unblock in the same run (SKILL.md Step 3.6 / Step 4 cascade).

**Why `git merge`, not `gh pr merge` (given the permission rules this skill expects):** permission rules **deny** `gh pr merge`, `gh api …/pulls/N/merge*`, `gh api …/merges*`, and pushes to the base branch (the `git push * <base>` / `*:<base>` forms) — but **allow** `git merge` and `git push` to a branch **other than the base branch**. So merging a slice onto integration uses plain `git merge` + `git push origin <integration>` (permitted), and the **base-branch boundary stays human by construction**: the loop never pushes to the base branch in any form, the only path to it is the final integration→base-branch PR, and `gh pr merge` is denied to the agent, so a human reviews+merges it. (The deny is glob-based, so don't *improvise* an exotic push spelling at the base-branch boundary — the loop has no reason to; the integration→base-branch PR is the only sanctioned path.)

**What `git merge` does not do (and the loop must, Step 3.6):** `Closes #N` does not fire (non-default base) and the slice PR shows **Closed, not Merged** — so the loop **explicitly** closes the slice PR + issue (noting the merge SHA) and deletes the slice branch. We lose the native "Merged" badge / auto-close / per-slice squash-on-integration — all low-value, since integration squashes into **one** commit at the base-branch boundary (its internal history is throwaway) and explicit close is two cheap non-denied `gh` calls. **Satisfied = the slice's `merge` SHA is reachable from the integration branch** — never keyed on the base branch (slices never touch it until the final PR).

**`gh pr merge` cannot be allowed for integration only:** a settings glob cannot base-scope it (the base branch is not in the command string), and a base-inspecting hook would be safety-critical merge-gating code. So the mechanism is `git merge`.

## `--from-rfc` — RFC-table-as-queue + JIT issue creation

`--from-rfc <path>` (composes with `--integration-branch`) makes the RFC's `## Task Breakdown` table the queue instead of a pre-filed `gh issue list`. Mechanics:

- **Identifier space.** The table's `#` column is the **slice ID** (e.g. `F1a`, `C2t`), and a row's `Depends-on` lists **slice IDs**. Readiness uses the same *satisfied = dep's `merge` SHA reachable from the integration branch* rule, matched on slice ID. (Contrast the pre-filed-queue mode, which parses `Depends-on` as `#N` issue numbers from the issue body; the `/plan:tech-design-doc-writing` Task Breakdown contract defines the column as slice IDs, and a *filed* issue carries the same deps translated to `#N`.)
- **JIT creation, on promotion.** A slice's GitHub issue is created only when it flips `waiting → ready` (SKILL.md Step 4), from its table row via the task-brief template (`/ship:github-issues`). At that moment every dep slice has shipped, so each dep's issue exists; the creation step **translates the row's slice-ID deps into those dep issues' `#N`** and writes them into the new issue's `## Execution` → `Depends-on`, so from creation on the issue is well-formed for the ordinary (pre-filed-mode) machinery. **Record the slice-ID → `#N` mapping in the ledger row** so resume + self-verification can re-derive it.
- **Resume / reconstruct.** A slice promoted in a prior wave has a JIT issue + ledger row + (if merged) a `merge` SHA — resume it from those, identically to a pre-filed slice. A **not-yet-promoted** slice has *no* issue and *no* ledger row — re-derive it by **re-reading the RFC table** (`--from-rfc <path>`) and recomputing readiness from the slice-ID DAG against the integration branch's merged SHAs. So the durable state for un-created slices is the RFC table itself (in-repo on the integration base), not `.claude/triage/`.
- **Self-verification (Step 6.5).** Give the fresh subagent the RFC path too: it re-derives the slice-ID DAG from the table and the per-slice `#N`/merge state from git + GitHub. An un-created slice having **no issue is expected, not a divergence**; a slice the ledger calls `done`/merged must still pass the reachability + closed checks below.

## Self-verification — unbiased re-derivation from ground truth

The durable artefacts (ledger + issue-keyed brief/panel/worktree + the `merge` SHAs) are **strong and self-describing** so the run state is **re-checkable by an agent that has seen none of the run's history**. SKILL.md Step 6.5 spawns that fresh `general-purpose` subagent on every resume / after compaction, and once before the final integration→base-branch PR. Contract:

**Inputs given:** ledger path, queue label + scope, integration branch name (if any), **RFC path (if `--from-rfc`)**. **Nothing from in-context memory.** The agent re-derives truth from git + the GitHub API **first** (and, for `--from-rfc`, the slice-ID DAG from the RFC table — un-created slices having no issue is expected, not a divergence), then diffs against the ledger.

**Per-row checks (reachability commands):**
```bash
# integration `done`: merge SHA reachable + slice PR closed + issue closed + branch gone
git merge-base --is-ancestor <merge-sha> origin/<integration> && echo reachable || echo MISSING
gh pr view <pr> --json state --jq .state            # expect CLOSED (commits are in integration)
gh issue view <issue> --json state --jq .state      # expect CLOSED
git ls-remote --exit-code origin refs/heads/ship-queue-<issue> && echo BRANCH-STILL-THERE || echo gone
# waiting `#M`: its merge SHA must NOT be reachable (else it is a missed promotion)
# flat `done`: PR open-or-merged to the base branch with Closes wired
# cross-slice re-scope: for every row whose `to` slice has MERGED (pending OR landed — the ledger is untrusted),
# its item (an exact symbol) must be in `to`'s first-parent merge diff. `to` not yet merged = in-flight, NOT a failure.
# `^1 <merge>` = what the merge brought onto integration (incl. conflict resolutions); `^1 ^2` diffs the two
# parents and misses them (and shows the advanced first parent as deletions). `to=follow-up:#N` exempt iff open + not-a-slice.
git diff <to-merge-sha>^1 <to-merge-sha> | grep -Fq "<item>" && echo landed || echo DROPPED   # DROPPED = dropped hand-off
```

**Divergence report (verdict-only, returned to the main loop):**
```
| row | ledger says | ground truth | action |
|-----|-------------|--------------|--------|
| #123 | done merge=a1b2c3d | a1b2c3d reachable, PR/issue closed | OK |
| #124 | waiting-on #123 | #123 reachable → deps satisfied | PROMOTE (missed) |
| #125 | done merge=ffff | ffff NOT reachable, issue still open | DOWNGRADE to in-progress (phantom merge) |
| (orphan) | — | merge commit on integration, no row | ADD row / investigate |
| ExportWidget W3→O2 | rescope pending | ExportWidget present in O2's merged diff | FLIP landed |
| ExportWidgetInvoice W3→B1 | rescope pending | ExportWidgetInvoice ABSENT from B1's merged diff | FAIL drain (scope dropped) — surface |
| WidgetDraft W2→O1 | rescope landed | WidgetDraft ABSENT from O1's merged diff | DOWNGRADE to pending (wrongly-landed) — surface |
| feed I2→O1 | rescope landed | O1 has no reachable merge SHA | CONTRADICTED-landed — flag, do not diff a blank SHA |
```

**Ground truth wins:** correct the **ledger** to match git+GitHub, record what changed, re-evaluate readiness from the corrected state. A `done` that fails its check is **downgraded** so the loop re-ships rather than advancing a wave on a phantom merge. The agent corrects **our model** (the ledger) only — it does **not** merge/close/push to reconcile GitHub; a real divergence (a `done` row whose merge vanished, an orphan merge) is **surfaced to the operator**, not silently healed.

## Cross-slice re-scopes — structured handoff record (`--integration-branch`)

A slice sometimes **defers part of its scope to another slice** — a re-scope handoff (e.g. a `W3 (primitive only)` slice hands the widget-export surface to `O2` and `B1`; a `W2` slice absorbed-first into `O1`). Tracked only in a free-text "handoffs" prose table, the operator must re-read prose on every resume and self-verification never checks the handoff actually landed — so the deferred scope can be silently dropped. Record each re-scope as a **structured row the instant the deferral is decided** (before the source slice ships), in the ledger:

```markdown
## cross-slice re-scopes
| at (ISO) | item | from | to | landed? |
|----------|------|------|----|---------|
| 2026-01-15T11:02 | ExportWidget | W3 | O2 | pending |
| 2026-01-15T11:02 | ExportWidgetInvoice | W3 | B1 | pending |
| 2026-01-15T12:40 | WidgetDraft | W2 | O1 | landed |
| 2026-01-15T09:10 | RetryOrderSync | W3 | follow-up:#130 | pending |
```

- **item** — the deferred unit, named as the **exact grep-able symbol** the destination diff will contain (a function, type, field, or constant — e.g. `ExportWidget`), not a vague theme: Step 6.5's check is a fixed-string `grep -F` for this token in `to`'s diff, so record the literal identifier you will grep, the moment you write the row. When one concept splits across **heterogeneous destinations** (an FE slice that *renders* a pending state, an enable slice that *flips* it), name the **destination-specific** symbol per row, so each row's check matches that destination's actual change.
- **from / to** — slice IDs (`--from-rfc` identifier space; in a pre-filed `--integration-branch` run, the dep `#N`). **A deferral to work *outside* this drain** — a future follow-up that is not a slice (an infra fix, a follow-up in another component) — uses **`to = follow-up:#NNNN`** (the tracking issue), which has no integration merge to grep and is **exempt from the in-diff check below**. The exemption is **bound to evidence, not self-granted**: it holds only if `#NNNN` exists, is **open**, and is **not itself a slice in this drain** (no ledger/RFC-table row) — otherwise the in-diff check applies, so a dropped in-drain item cannot be relabelled a follow-up to dodge the grep.
- **landed?** — `pending` until destination slice `to` merges **with the item in its diff**; flipped to `landed` **only when verified against `to`'s merged diff**, never on assertion.

**Step 6.5 self-verification asserts — for every re-scope row whose `to` slice has merged onto integration (`pending` *or* `landed`, since a stale or hand-edited ledger can mis-claim `landed` too) — that the `item` symbol is present in `to`'s first-parent merge diff**: `git diff <to-merge-sha>^1 <to-merge-sha> | grep -Fq '<item>'` (first-parent diff = what the merge actually brought onto integration, including conflict resolutions; `<merge>^1 <merge>^2` would diff the two *parents* and is wrong once a base-branch sync or sibling merge has advanced the first parent — it shows that advance as deletions and misses the merge's own changes). **Item absent ⇒ a dropped hand-off** — fail the drain (or downgrade a wrongly-`landed` row), surfaced to the operator, never silently kept `landed`. **Decide "has `to` merged?" from `to`'s own ledger `merge` SHA being present *and reachable* (`git merge-base --is-ancestor <sha> origin/<integration>`), never from the re-scope row's `landed?` string** (the string is untrusted, which is the whole reason `landed` rows are re-checked). A re-scope row whose `to` has **no reachable merge SHA** is **not yet merged** ⇒ legitimately **in-flight** — **not** a failure (it is checked when `to` merges, and at final completion every `to` must be merged anyway), so a resume/compaction *mid-drain* never false-fails an in-flight handoff. The one inconsistent state this distinguishes: a row claiming `landed?=landed` while its `to` has no reachable merge SHA is a **contradicted-`landed` divergence** — flag it to the operator and do **not** run the diff (there is no SHA to diff against), never silently trust the `landed`. A **`follow-up:#NNNN`** destination is **exempt** from the grep only when bound to evidence (above): `#NNNN` exists, is **open**, and is **not a slice in this drain**; otherwise the in-diff check applies. Ground truth is the diff, not a ledger string — the same posture as the rest of self-verification.

## Course-correction — mid-run operator directives (durable)

An author can redirect an in-flight drain ("skip #X", "also do #Y", "#C no longer depends on #A", "that slice went to the wrong branch", "redo #X", "stop"). Handle it **gracefully, at a clean checkpoint, durably** — full behaviour in SKILL.md "Course-correction"; the **durable mechanism** lives here:

- **Record the directive as a ledger row the instant it arrives**, before acting, so a compaction mid-fix cannot lose it:
  ```
  ## operator-directives
  | at (ISO) | directive | applied? |
  |----------|-----------|----------|
  | 2026-01-15T10:14 | drop #X from this run | pending |
  | 2026-01-15T10:31 | #C depends-on #D now (was #A) | applied |
  ```
- **Apply at the next clean checkpoint** (between issues, never mid-fix) — a fix in flight finishes or is explicitly abandoned first — then flip `pending → applied`. A `pending` directive is replayed on resume (it is durable state, like a `waiting` row).
- **A dep/scope/skip/add change re-derives readiness and re-runs self-verification** — e.g. dropping the dep on `#A` may promote a `waiting` row; adding `#Y` inserts a new row the strategy then orders.
- **Irreversibility guard:** a directive touching an **already-merged-to-integration** slice (drop it, move its branch) **cannot be silently un-merged** — integration history is not rewritten autonomously. Surface it: the merge is in integration, a revert is an explicit operator-confirmed step (a new revert slice or `git revert <merge-sha>`), never an auto-rewrite. The operator's go-ahead is itself **recorded durably as a directive row** (`revert #X — confirmed-by <human> at <ISO>`, then `applied`) — so the confirmation survives compaction and is auditable, not a self-assertion an agent could grant itself post-hoc. This mirrors self-verification: we change our model freely, we change *merged reality* only with a recorded human go-ahead.

## Carry-forwards — per-slice must-include / must-verify (non-re-derivable)

Step 6.5 re-derives *merge state* from git + GitHub, but a long drain also accumulates **narrative that has no git artefact to re-derive from**: a must-verify a reviewer attached to a *later* slice ("O4's export path must include only non-secret order fields — the export file is sent to customers"), a must-include carried out of one slice's PR review into a not-yet-built one ("B2 must add the failed-invoice alert on the counter O2 emits"), a standing rule the operator set mid-run. Left in free-form ledger prose, a compaction loses it. Record each as a **structured row the instant it is decided**:

```markdown
## carry-forwards
| at (ISO) | for-slice | kind | detail | resolved? |
|----------|-----------|------|--------|-----------|
| 2026-01-15T13:05 | O4 | must-verify | the export includes only non-secret order fields (the file is sent to customers) | no |
| 2026-01-15T12:20 | B2 | must-include | add the failed-invoice alert rule on the counter O2 emits | no |
| 2026-01-15T14:30 | (all) | standing-rule | run a cross-model adversarial review on big slices | no |
```
- **kind** — `must-include` (a deliverable owed to a future slice), `must-verify` (a check that slice's build must run), or `standing-rule` (a directive that applies to every subsequent slice; `for-slice` = `(all)`).
- **resolved?** — flip to `yes` when the target slice ships having honoured it (or the rule stops applying). A `standing-rule` stays `no` for the whole run.
- Unlike a `## operator-directives` row (a course-correction *action*), a carry-forward is a *constraint carried forward to a slice not yet built* — the thing per-slice review cannot see and Step 6.5 cannot re-derive.

## Compaction survival — the non-re-derivable narrative lives in the ledger

The ledger's per-slice rows are git-re-derivable (Step 6.5). What is **not** re-derivable is the narrative — the `## operator-directives`, `## cross-slice re-scopes`, and `## carry-forwards` sections, plus the `# resume-cmd:` header line. Keeping it in the ledger is what makes it survive a context compaction: compaction compresses the *conversation*, not the *filesystem*, so the ledger file outlives it. On resume the agent reads that narrative straight from the ledger — no hand-authored resume-prompt, no copy-paste.

- **The ledger header carries the resume command** — Step 0 writes a `# resume-cmd: /queue:ship-queue --resume --session <session-id> <the run's exact args>` line (the `--session` is the *original* run's id, so a fresh session can locate this ledger; updated by course-correction if the args change, e.g. a renamed integration branch), so a fresh session has the exact command to re-enter with.
- **On resume** (SKILL.md Step 6), read the `# resume-cmd:` line and the three narrative sections for context, then run Step 6.5 to re-derive slice state from git + GitHub — never trust the ledger over ground truth for merge state.
