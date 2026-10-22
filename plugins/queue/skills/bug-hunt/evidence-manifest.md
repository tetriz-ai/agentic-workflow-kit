# bug-hunt — the canonical evidence manifest

The manifest is the **one durable source of truth** for a finding, and **both the author-review table and the filed issue body render from it** (author-gate.md, filing.md). Compiling the issue from one structured record — not from prose scattered across the hunt ledger, the decision table, and body drafts — is what makes completeness a *deterministic compile step* instead of a memory/review problem. If the compact review view and the executable draft are ever maintained separately, they drift; they must not.

Write it to `.claude/triage/hunt-manifest-<session-id>.md` (gitignored). One record per finding.

## Per-finding record (the schema `scripts/readiness-check.sh` enforces)

Each field is `key: value` on one logical line — the manifest is the *structured summary*; the full narrative lives in the rendered issue body. A record starts at a `finding_id:` line.

```text
finding_id:              short stable id (F1, F2, …)
title:                   the issue title
type:                    bug | improvement | doubt-resolved
github_target:           new | existing-#N
current_code_anchors:    ≥1 exact file:symbol or file:line per affected layer
causal_trace:            the traced request/data path → root cause
contrasting_guard_or_sibling: the correct sibling to mirror (file:line), or none + why
actor_boundary:          concurrency/tenancy/auth/async/browser → whose process, whose creds,
                         what is shared, how one request affects another; else n/a
prod_status:             active | latent | not-log-visible | dormant
prod_evidence_window_and_result: count + representative line, or "0 hits (latent)" + why,
                         or "not checked: logs_metrics blank"
prod_confirmation_or_recheck_recipe: the exact log/metric/SQL query, or a sanitized
                         parameterized recipe + the redaction reason (never a bare count)
dedupe_and_adjacent_boundary: no-match | dup-of-#N | related-#N; and the split boundary
approved_solution:       the user-visible outcome after the fix + the smallest coherent impl path
scope_in:                what the fix touches
scope_out:               what it explicitly does not
reproduce_first_test_files: existing or explicitly-new paths
exact_test_commands:     runnable from a named working dir (a test command / an API call / a read-only script …)
rollout_backfill_migration: present | not_applicable + reason
done_criterion:          past-tense "done = …"
priority:                P0 | P1 | P2 | Parked  (author-gate.md scheduling semantics)
owner:                   the GitHub login (author-gate.md distribution)
labels:                  primary area label + type + bug-hunt (+ the queue label iff ready)
handoff:                 ship-queue | human | activation | none
open_author_decisions:   none  — or exact question(s); MUST be none on a ship-queue row
local_evidence_transfer_audit: complete  (see the transfer report below)
```

Every production query executed during grounding is persisted with its **exact command/SQL or a sanitized reproducible recipe** *before* its result is summarized — a count without its derivation is not a complete cell. Tenant-sensitive predicates: store a parameterized query + the redaction reason.

## The readiness gate (before the author sees any row)

`scripts/readiness-check.sh <manifest>` fails the handoff unless every `handoff: ship-queue` record is a complete, **well-formed** executable draft — required fields non-empty, ≥1 `file.ext:line`-shaped anchor, a command-shaped test line, valid `priority`/`prod_status`, `open_author_decisions: none`, and **no** gitignored reference or fill-in placeholder anywhere. Run it and clear every BLOCK **before** rendering the author table.

**What it is, honestly:** a format + completeness lint over the agent's own manifest — it checks the required cells are present and well-shaped, which is what catches a hunt shipping thin. It does **not** verify that an anchor points at real code or that the test exists/passes; binding a claim to reality stays *your* grounded duty (filing.md's drift check) and the human author gate. So a well-formed but fabricated claim can pass the lint — the lint raises the floor, it is not the ceiling. Do not treat a green gate as "the evidence is verified".

## Renderer contract — lossless w.r.t. the manifest

The issue body (filing.md) is rendered from this record and is **lossless**: it may drop internal metadata (finding_id, the transfer audit) but may **not** collapse finding-specific content into shared/generic prose. Each body carries: observed behaviour + measured impact; the traced path + root cause; why it violates the product contract; the approved recommendation incl. edge cases; scope in/out + rollout/backfill; reproduce-first proof + tests + operational validation; only genuine unresolved decisions as exact questions.

**Per-field transfer report.** For every grounding item, the renderer records a disposition: `copied` (into the body), `intentionally omitted (reason)` (e.g. sensitive tenant detail), or `superseded (new evidence)`. Any unaccounted-for local grounding **fails filing readiness** — this is what catches a body silently thinning out relative to the accepted first canary. The GitHub read-back verifier (filing.md) parses the rendered sections back into this same schema and diffs them against the manifest.

## Run manifest — the review-ready checkpoint

The run manifest (`.claude/triage/hunt-run-<session-id>.md`, SKILL.md Step 1) additionally carries the deliverable shape, not just discovery state: target range + stop condition; completed / adversarially-verified / deduped / backlog counts; current direction/dimension coverage; the canonical manifest path (above); and an explicit `proposal only — nothing filed` state. Stopping after a batch **without** producing the requested review table is incomplete even if the findings are grounded.
