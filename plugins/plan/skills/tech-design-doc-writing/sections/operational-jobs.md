# §11 Operational Jobs

**What it is** — the one-off operational jobs the change needs (backfill / reprocess / data fix / data migration). Prefer a reviewed, parameterised, idempotent job over hand-run SQL.
**Applies when** — the change needs to act on existing data or trigger an operation outside the normal request path. **Intending to do it as hand-run SQL does not exit this section** — that choice is precisely what the first grill below adjudicates, so a design with any such mutation applies here whatever form the author had in mind. Skip (explicitly) only when the change has no out-of-band data operation at all.

## Claude drafts (derivable)
- Which jobs the design implies (a new column → a backfill; processor-logic change → a reprocess; etc.).

## Author decides (grill — printed question + your recommendation + "or your take")
For **each job**:
- **Job or hand-run SQL, and does a job already do it?** Inventory the repo's existing operational
  jobs first and record the outcome here: reuse / extend-by-one-arg / new job, naming the jobs
  inspected. The fork itself: a mutation keyed to an entity (an org, a user, a repo) is a job,
  whatever directory you were about to file the SQL in, because a hand-run statement skips the
  guards a reviewed job carries.
- **Two modes — READ and EXECUTE.** READ computes and prints the **blast radius** (rows/entities it *would* touch, counts, a sample) and writes nothing; EXECUTE performs the change. **READ-before-EXECUTE is mandatory for any job that does a lot** (bulk mutation, backfill, reprocess) — validate the blast radius first. A trivial single-row job can skip the gate, but READ mode must still exist.
- **Idempotent / resumable** — re-running is safe; a crash mid-run resumes, not corrupts.
- **Who runs it, when** — and any ordering vs the rollout.
- **Safety** — e.g. a forced reprocess must **not** bump the timestamps that drive live incremental processing, and must stay outside any rolling data window, so a big backfill doesn't surge into the live window.
- **If the job skips a subset, its cutover parity gate carves that subset out.** When a backfill/migration job intentionally drops rows (a size guard, a filter), the reconciliation gate that decides go/no-go must reconcile against the skipped set (**zero *unexpected* mismatch**, not zero) via a **check-time-computable** predicate — see `sections/concerns.md` §1. A strict zero-mismatch gate over a skipping job is unsatisfiable.

## Ground in (pointers — read, don't restate)
- the repo's own operational-job framework or runbook, if it has one

## Review hooks (what /plan:tech-design-doc-review checks here)
- A **new** job with no existing-job inventory outcome (which jobs were inspected, and why the
  closest one does not fit) → WARN. An unnamed "nothing existed" is the same as no inventory.
- An operational step described as a **per-entity SQL file** — keyed to a single org, person, repo,
  connector, or any other entity — whose work an existing job already does → WARN (it drops that
  job's guards). Match on any entity, not a narrower org/person pair: a per-repo or per-connector
  fixture is the same defect and must not pass the design gate on a technicality.
- Each job declares **READ and EXECUTE** modes → missing READ → WARN.
- READ-before-EXECUTE called out for any **bulk-mutating** job → missing → WARN.
- **Idempotent/resumable** stated for a backfill/reprocess → missing → WARN.
- A **bulk job that skips/filters a subset** whose cutover parity gate does not carve out the skip (or carves it via a runtime-only signal, not a check-time-computable predicate) → WARN. (The §1 data-correctness sibling — surfaced here too so an Operational Jobs section with a skip cannot pass §11 while its parity gate is unsatisfiable.)
