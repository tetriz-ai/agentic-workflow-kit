# bug-hunt — filing (transactional, from the manifest)

After the author approves, filing is **mechanical** — the executable drafts already exist (evidence-manifest.md), so filing does not re-derive anything. It renders each issue from its manifest record, files it transactionally, and reads it back.

## After approval, filing does only three things

1. A cheap **drift check** — the anchored symbols/lines still exist (`grep`/LSP the `current_code_anchors`).
2. Apply the author's **row changes** to the already-complete drafts.
3. Invoke `/ship:github-issues` mechanically.

Do **not** re-read broad code paths, re-derive solutions, or rebuild acceptance criteria after approval. If current-code drift invalidates an anchor, re-ground **only that row** and disclose the drift — the exception, not the workflow.

## The open-decision set is frozen at approval

A filing pass may add implementation detail (an exact field manifest derivable from approved consumers, names consistent with existing code, the tests) but **must not** add `held`, add a `decision needed`, remove `ship-queue`, or invent a new fork merely because the body is being made more precise. Deriving detail whose outcome and boundary are already approved is implementation work, not a product blocker. A post-approval blocker is permitted **only** on new evidence or real code drift that contradicts an approved assumption, recorded as:

```text
new_evidence:
invalidated_approved_assumption:
exact_author_question:
affected_rows:
```

and only those rows return to the author. "The filing pass wants more detail" is **not** new evidence. Every author-review table is generated from the final issue draft, so the author never discovers a queue blocker for the first time in the GitHub description.

## Lossless render + no inaccessible references

Render each body from the manifest per the **renderer contract** in evidence-manifest.md (lossless, per-field transfer report, content-checks not section-presence). Validate every link/path **from the assignee's perspective**: a gitignored `.claude/triage` ledger, a session-only artifact, a cookie-authed URL is **summarized inside the issue**, never cited as required reading. `scripts/readiness-check.sh` already fails a manifest that references such artifacts — but re-scan the *rendered body* too, because rendering can introduce a reference the manifest did not have.

## Transactional preflight — before the FIRST GitHub mutation

1. Render **every** selected issue body from its manifest record.
2. Validate labels, owner, priority, estimate, version, and `ship-queue` eligibility against the **approved row record**.
3. Scan for inaccessible references and unresolved placeholders (`readiness-check.sh` on the manifest + a body scan).
4. Verify every `ship-queue` body satisfies the current queue contract (`${CLAUDE_PLUGIN_ROOT}/skills/ship-queue/blocker-protocol.md`).
5. Show one representative **high-risk body as a canary** when the renderer/template changed.
6. **Require the canary to pass before processing the batch.**

## Per-issue: create → read back → compare

Create or enrich **one** issue, then immediately **read it back from GitHub** and compare title, body digest, labels, assignee, and project fields against the approved record. **Stop on the first mismatch** and record that issue `created_partial` — later issues stay uncreated. The verifier compares **semantic sections**, not just body length or a hash: all finding-specific prod evidence survived; every approved recommendation + scope boundary present; acceptance includes the **causal proof**, not only an output snapshot; `ship-queue` appears iff the final body has no unresolved author decision; an **enrichment preserved** the prior issue context (never silently overwrote earlier accepted scope); project fields + assignee match.

**Process-completion before any retry.** Never infer a command finished from a yielded/completed wrapper — an issue-creation script's child process (such as the one `/ship:github-issues` runs) can keep creating issues after the wrapper returns. Prefer **exactly one issue mutation per process**; persist the returned issue number immediately, then read it back before starting the next. A timed-out/ambiguous command enters **`unknown_outcome`** — its row may **not** be retried until reconciled against GitHub (search for the expected title/body digest; adopt the created issue rather than filing a duplicate).

Filing state machine: `not_started → created_partial → verified → failed`, plus **`unknown_outcome`**. Persist per issue:

```text
render_validated_at:
github_issue_number:
body_digest_expected:
body_digest_read_back:
fields_verified: true|false
filing_state: not_started|created_partial|verified|failed|unknown_outcome
```

A cancellation must leave the in-flight issue either `verified` or explicitly `created_partial` — never a detached loop that outran read-back.

## Labels, owner, priority

Via the `/ship:github-issues` skill (its issue script owns the field IDs; do not hand-roll `gh` field edits). Per issue:

- `--assignee <owner>` and `--priority <value>` from the approved manifest row.
- Primary area label + the type label (e.g. `bug` for a defect) + the **`bug-hunt` provenance label on every filed finding** (independent of readiness — the label's own definition).
- Stamp **the queue label** (the `queue_label` setting) iff `Filing readiness = ready` **and** `Handoff = ship-queue` **and** `open_author_decisions = none`. A finding with an open decision gets `bug-hunt` but **not** the queue label — the exact signal `/queue:ship-queue` and the session-start nudge read to surface "these need your call". Do **not** auto-stamp any other triage label. Create a missing label first (`gh label create`).
- Set Estimate, Version, Status=Todo per `/ship:github-issues` (when `github_project` names a board).

## Recovery quality is the normal quality

The full causal narrative — prod measurements, request ownership, backend dispatch, assembler fan-out, product boundary, explicit solution, exclusions, reproduce-first tests, dependency-call proof, operational validation — is the **minimum executable draft that exists before the author sees the row**, not special recovery work. A later, smaller finding may have a shorter body, but each preserves its own complete reasoning: an assignee must not need to rediscover why the bug exists, decide the product outcome again, or infer what proof closes the task. The **monotonic-quality check**: render an early and a late finding from the same run, grade both against the same rubric — the later one may be shorter but may not drop required fields (anchors, test command, dedupe boundary, PoC detail) because the batch is long.
