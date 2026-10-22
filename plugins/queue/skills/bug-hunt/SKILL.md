---
name: bug-hunt
description: >-
  Finds bugs, latent risks, improvements or doubts to confirm in an area the author names. It
  traces each finding through the code, and through production logs and metrics when the
  logs_metrics setting says how to read them. It then argues against each one: it tries to refute
  a bug, substantiate an improvement or resolve a doubt. It checks existing GitHub issues for
  duplicates and files each finding that holds up as a triaged issue. It files a first batch of
  the size the author picks, keeps the rest as a backlog and offers the next batch, running as a
  persistent /goal until the author approves a batch. /queue:ship-queue fixes the bug-type issues
  it files. Use when someone says "find bugs", "hunt bugs", "audit X", "look for improvements in
  Y", or wants a triage-ready batch.
argument-hint: "[first-batch count] [area/vertical/scope] [--type bug|improvement|doubt|any] [--env prod|<env>] [--label <handoff-label>]"
---

# Skill: bug-hunt

Find things that are **real and grounded**, not plausible-looking — anchored to a direction the author states up front. The output is a batch of GitHub issues a teammate can pick up cold: each one traced through the actual code, checked against prod where a signal exists, and survived an adversarial pass tuned to its type. This skill is **author-interactive**: it opens by asking the author *what they want to hunt and where*, and it never files issues without showing the drafts + dedupe results and getting a go-ahead.

It composes existing tooling rather than reinventing it: the `logs_metrics` setting for logs/metrics (blank skips that evidence class), `/ship:github-issues` for filing. Filed bug-type issues carry a handoff label the author picks at the filing gate (default: the `queue_label` setting, `ship-queue` unless changed) so `/queue:ship-queue` can pick them up one by one.

## Finding types (the lens is set by author direction, not fixed to bugs)

Every finding is tagged with one type; the type decides how it is stress-tested and where it hands off:

- **Bug** — a defect: logic/comparison error, off-by-one, nil-deref, swallowed error that drops data, idempotency/dedup failure, pagination/cursor loss, auth/authz gap, race, wrong time-window/bucketing, token/rate-limit math. Stress-test = **refute** (default NOT-A-BUG). Handoff = `ship-queue` (the queue label).
- **Improvement** — a latent-risk hardening, a correctness-preserving refactor of a sharp edge, a missing guard/observability that is not yet a defect. Stress-test = **substantiate** (is the gain real, the cost honest, and is it not already handled elsewhere?). Handoff = the label the author picks (often `none` — human triage).
- **Doubt-to-confirm** — a "this looks wrong, is it?" the hunt resolves into either a Bug, an Improvement, or *by-design (dropped)*. Stress-test = **resolve** to one of those three with file:line evidence. Only the Bug/Improvement resolutions get filed.

A run can mix types; `--type` (or the author's Step 0 direction) narrows the lens. Default lens when the author gives no steer: **bug**, broad fan-out.

## Operating principles (do not skip)

- **Verify, do not narrate.** Every claim is traced through the real functions, callers, and callees — not memory, not a summary. A finding you cannot trace is not a finding.
- **Honest grounding.** `0 prod hits` is a result, not a weakness: it means *code-confirmed but latent* (a landmine to fix preemptively), and you say exactly that. Never discount a real defect for being latent, and never inflate a latent one into an active incident.
- **Stress-test before you trust.** Default every candidate to not-real until a fresh, adversarial pass — refute / substantiate / resolve per type — fails to break it.
- **Fewer, stronger — uncapped does not lower the bar.** Every filed finding is grounded and survives its adversarial pass. Uncapped means more real findings are captured as a backlog — never that weak ones are padded in to hit a number. Drop style, naming, missing-tests, and generated code.

## Step 0 — Scope intake (author direction; the explicit-thinking gate)

Open by getting the author to **say what they are hunting**, so the hunt is steered, not blind. Ask once, compactly, for:

- **Direction / thesis** — the area, vertical, subsystem, problem-statement, doubt, or improvement they have in mind (free-form; "the sync cursor logic feels fragile", "anything that drops webhook events", "audit the authz layer", "is our rate-limit math right?").
- **Type lens** — bug / improvement / doubt / any (default **bug** if they only give an area).
- **First-batch target X** — how many to file *now* (default **5**); discovery beyond X is captured as a grounded backlog, not dropped.
- **Env** — `prod` (default) or another environment name.

If the author gives nothing (e.g. a bare `find bugs`), fall back to the broad bug lens across the default subsystems — do not block. The point is to *let* the author steer, not to force a form. Echo the resolved scope back in one line before hunting so they can correct it.

## Step 1 — Lock persistence + write the run manifest

Invoke `/goal` so the Stop hook holds the session to a finished batch, e.g.:

> `/goal hunt grounded findings in <author's area/thesis> (<type lens>), file the top <X> after grounding + adversarial pass + dedupe + author approval via /ship:github-issues, and report the remaining grounded backlog`

`<X>` = the first-batch target from Step 0 (default 5). The goal targets the *first batch* — discovery itself is uncapped, and the backlog is part of the finished state. The goal auto-clears once the batch is filed (or the author stops early). `/goal` is a built-in persistence command (it sets a session-scoped Stop hook); if your harness does not have it, the steps below still drive the batch — persistence is then best-effort, not enforced.

**Then write the run manifest — before any preflight or fan-out.** Write `.claude/triage/hunt-run-<session-id>.md` (session-id-named so concurrent hunts never collide) carrying: the exact author prompt; the resolved thesis / type lens / first-batch target / env / exclusions; the prior-run dedupe baseline (Step 7 artefacts + issue ranges); status `discovery` (advance it `discovery` -> `filing` -> `complete`); and the **review-ready checkpoint** (target range/stop condition, verified/deduped/backlog counts, dimension coverage, the canonical evidence-manifest path, and an explicit `proposal only — nothing filed` state — [evidence-manifest.md](evidence-manifest.md)), so a resumed run recovers the *deliverable shape*, not just discovery state. **Tell the author the manifest path** so a later session can be pointed straight at it. This is the record Resume discovers first.

## Resume — recovering an interrupted or compacted run

A hunt can be interrupted mid-flight, or its request can fall out of context after compaction — often in a **new session with a different id**, so never assume the current session id names the prior manifest. Recover the scope in this **strict precedence order**; and where a *later* explicit author correction or a run manifest contradicts the `/goal` objective, the correction/manifest wins (a goal can carry a scope the author has since superseded — trust the correction and record the supersession in the manifest):

1. **A manifest the author names**, else the active `/goal` objective's thesis.
2. **A run manifest** — scan `.claude/triage/hunt-run-*.md`, take the one whose status is not `complete` and whose recorded prompt/thesis matches the request. **Match on content, never on filename or mtime** — a prior session's manifest is not named for the current session, and that directory holds many concurrent tasks' artefacts. If several active manifests match, ask which.
3. **Local session history** — search it for the author's exact interrupted prompt.
4. **Ask the author.**

**Self-check before any prod / GitHub work:** echo the recovered thesis + exclusions + batch target and confirm they match the chosen manifest or the author's exact prompt; if they cannot be reconciled, stop and ask.

## Step 2 — Tooling preflight

Resolve the settings this skill reads:

```bash
CFG="${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh"
REPO=$("$CFG" get repo_slug '${user_config.repo_slug}')
[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
QUEUE_LABEL=$("$CFG" get queue_label '${user_config.queue_label}')
LOGS_METRICS=$("$CFG" get logs_metrics '${user_config.logs_metrics}')
```

`LOGS_METRICS` names the command(s) this skill may use to read logs and metrics for the target env. Do not re-document those tools here — point at them. **If it is blank, skip the logs/metrics evidence class**: record `logs/metrics: skipped (logs_metrics blank)` in the run manifest, ground on code alone, and say so in every finding's evidence cells (Step 5). Otherwise, before hunting (so grounding is not blocked later), **confirm access**: run a cheap probe through `LOGS_METRICS` for the target env, and if prod is unreachable, surface the exact unblock step the tool reports (VPN, login, token) and fall back to another environment for grounding, noting the gap — never silently skip grounding.

## Step 3 — Fan out hunters

Split the author's scope into subsystems, derived from the repo's own layout (e.g. request handling, domain services, auth, data access, background jobs — **narrowed by the Step 0 direction**: a focused thesis may be one or two subsystems, a broad audit all of them). Launch one `general-purpose` subagent per subsystem **in parallel**, each instructed to:

- hunt against the **author's thesis and type lens** — find genuine findings by **tracing the actual code path**; for the bug lens that is the defect catalogue above, for the improvement lens it is latent risks / sharp edges / missing guards, for the doubt lens it is the code bearing on the author's specific question — **surface it as `type: doubt` with the question restated and the relevant evidence; do not resolve it here, Step 6 resolves each doubt against source**;
- find as many *genuine* findings as the code warrants (no per-agent cap) — but each must be traced, not speculative; skip style, naming, missing tests, and generated code;
- return a structured candidate per finding: **title · type (bug/improvement/doubt) · file:line · failure-or-gap mode (trigger + wrong/weak outcome) · code evidence (why, ideally a contrasting correct-sibling) · blast radius (silent/loud, security?) · confidence (high/medium only) · how to confirm in logs/metrics** (a concrete log/metric query in the form `LOGS_METRICS` accepts; when it is blank, the query a reader with log access would run).

Keep heavy reading in the subagents: return only the **compact** structured candidates (no file dumps). On a wide run, write the full candidate list to `.claude/triage/` and return the strongest inline plus a one-line count of the rest, so an uncapped hunt does not flood the main context.

## Step 4 — Select & batch (uncapped, prioritized first batch)

Pool the candidates and rank them by strength × diversity (spread across data-loss, security, correctness, reliability, improvement — not all of one flavour). Then split, do not truncate:

- **First batch** — the strongest `<X>` (Step 0 target). These go through full grounding + adversarial verify and get filed this run.
- **Backlog** — every *remaining grounded* candidate, kept in the artefact (Step 8). Not padding: drop weak/speculative ones here too. The backlog is the "remaining N later" the author is nudged about at the end.

Prefer high confidence in the first batch. Note the count of each so the author sees "filing top X now, N more queued".

## Step 5 — Ground in the target env

Use the env from Step 0 / `--env` (default `prod`; another env for a non-prod audit) — the same env the Step 2 preflight probed. Do not hard-code prod: a non-prod audit grounds against that env's logs/metrics, and the status you record is for that env. For each **first-batch** finalist with a log/metric signal, run the confirm query (through `LOGS_METRICS`) against the selected env. When `LOGS_METRICS` is blank, run no query: record `not-log-visible`, set the evidence cell to `not checked: logs_metrics blank`, and keep the recheck recipe. Otherwise record one of:

- **Active** — N hits over the window; quote the count and a representative line.
- **Latent** — 0 hits; state it is code-confirmed but not currently firing (fix preemptively).
- **Not log-visible** — silent by nature (e.g. an absent filter, a security gap that looks like a normal request, an improvement that has no failure signal yet); say why and give the reconciliation/probe that *would* show it.

## Step 6 — Adversarial verify (tuned to the type)

For each first-batch finalist, launch a fresh `general-purpose` subagent as a skeptic, with the prompt matched to its type:

- **Bug → refute.** *"Default to NOT-A-BUG. Re-derive from source. Attack from every angle — is the path reachable, is there a guard elsewhere, is the contrasting sibling actually analogous, is it by-design? Then attack the REMEDIATION this finding implies, not just the bug — scoped to the finding's evidence: **when it cites prod evidence**, would the remediation actually move it (the exact status / vendor / site the report names), or only a plausible-but-unobserved variant, and is the root cause the **confirmed** mechanism from that evidence rather than a code path that merely could produce the symptom? Is the symptom vendor/site-agnostic while the remediation is single-site? **For a `Latent` finding (0 prod hits *by design*) there is no prod evidence to move — do not drop it for that; instead attack source reachability and the concrete failure mode: can the path actually be hit, and does the stated failure follow?** A remediation that moves neither the cited evidence nor a reachable failure mode is as good as no bug — say so."*
- **Improvement → substantiate.** *"Default to NOT-WORTH-IT. Is the risk/gain real and not already mitigated elsewhere? Is the proposed change correctness-preserving? Is the cost stated honestly?"*
- **Doubt → resolve.** *"Re-derive from source and resolve this to exactly one of: it IS a bug (give the failure mode), it IS an improvement (give the gain), or it is BY-DESIGN (give the reason)."*

Require a verdict (VALID / INVALID / PARTIAL, or the doubt's resolution) with file:line evidence. **Drop anything refuted / found not-worth-it / resolved to by-design**; downgrade PARTIAL. Fold the corroborating evidence into the draft. If a doubt resolves to a bug or improvement, re-tag it and carry it forward.

## Step 7 — Dedupe vs existing issues

Before drafting, check the tracker so you do not file a duplicate:

```bash
gh issue list --repo "$REPO" --state all --search "<keywords from the finding>" --limit 20 --json number,title,state,labels
```

Search by the symptom, the file/function name, and the area label. For each finalist, record: no match / likely-dup of #N (skip, or file as a comment on #N) / related-to #N (cross-link). Surface dup findings to the author in Step 9 — do not auto-skip silently.

## Step 8 — Compile the canonical evidence manifest

Compile one **canonical evidence manifest** — the single source of truth from which **both** the author table (Step 9) and the issue bodies (Step 10) render, so the review view and the executable drafts cannot drift apart. **Read [evidence-manifest.md](evidence-manifest.md) and follow it** — that file is the contract (the per-finding schema, the lossless renderer + transfer report, the run-manifest review-ready checkpoint); this line is not a substitute for the read. Write it to `.claude/triage/hunt-manifest-<session-id>.md` (gitignored) with the backlog alongside so a later batch files without re-hunting; `/queue:ship-queue` never reads it, so every finding's grounding must be complete in the manifest before it is rendered.

**Then run the readiness gate before the author sees anything** — ship-queue readiness is checked HERE, not after approval:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/bug-hunt/scripts/readiness-check.sh" .claude/triage/hunt-manifest-<session-id>.md
```

Clear every BLOCK before Step 9. What the gate does and does **not** verify (a format/completeness lint, not proof the anchor is real): evidence-manifest.md "The readiness gate".

## Step 9 — Author gate (the human gate)

Present the batch as **decisions, not descriptions**. **Read [author-gate.md](author-gate.md) and follow it** — that file is the contract (the decision-table shape, the four fields that replace `held`, resolve-technical-uncertainty-yourself, priority-as-scheduling, ship-queue eligibility ≠ prod activity, mechanical owner distribution, the per-row decision log); this line is not a substitute for the read. Two things fire here: **load the `/ship:github-issues` skill's priority convention before the first table**, and **ask the handoff-label question once for the whole batch** (bug default `$QUEUE_LABEL`; improvement/doubt default `none`; or a custom `--label` — separate from the per-finding area and type labels). **Do not file until the author approves — the one mandatory pause.** Close by nudging the backlog ("filing top `<X>` now; `N` more queued — next batch?").

## Step 10 — File (transactional, from the manifest)

After approval, filing is **mechanical** — the executable drafts already exist (Step 8), so filing re-derives nothing. **Read [filing.md](filing.md) and follow it** — that file is the contract (drift-check → apply row changes → `/ship:github-issues`; the frozen decision set; the lossless renderer with no inaccessible references; the transactional preflight + canary; create → read back → compare with the `unknown_outcome` state machine; and the `--assignee`/`--priority` + label-stamping mechanics); this line is not a substitute for the read. The one cross-skill invariant to hold in mind: a finding with an open author decision gets the **`bug-hunt`** provenance label but **not the queue label** — the signal `/queue:ship-queue` and the session-start nudge read to surface "these need your call".

## Handoff

Report the filed issue numbers, their types, the handoff label, and the **backlog count carried forward**. If the default queue label was used for bugs, the author (or a teammate) runs **`/queue:ship-queue`** (no `--label` needed) to fix them one by one; for a custom label, `/queue:ship-queue --label <label>`. If the author wants the backlog filed, re-run from Step 5 on the next batch (no re-hunting — the candidates are already in the artefact).

## See also
- [evidence-manifest.md](evidence-manifest.md) — Step 8: the canonical per-finding manifest schema, the lossless renderer contract + transfer report, and the run-manifest review-ready checkpoint.
- [author-gate.md](author-gate.md) — Step 9: the decision-table shape, the four fields that replace `held`, priority scheduling semantics, ship-queue eligibility, owner distribution, and the per-row decision log.
- [filing.md](filing.md) — Step 10: mechanical post-approval filing, the frozen decision set, the lossless renderer, the transactional preflight/canary/read-back, and the `unknown_outcome` state machine.
- [scripts/readiness-check.sh](scripts/readiness-check.sh) — the pre-author-gate readiness lint (format + completeness, not content verification) that fails the handoff on a malformed/incomplete `ship-queue` draft (tests: `scripts/readiness-check.test.sh`).
- [regression-scenarios.md](regression-scenarios.md) — the 13 author-gate/filing regression scenarios this contract must satisfy.
