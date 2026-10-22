---
lens: performance
applies-to:
  - "**/handlers/**"
  - "**/handler/**"
  - "**/api/**"
  - "**/routes/**"
  - "**/controllers/**"
  - "**/services/**"
  - "**/dao/**"
  - "**/repository/**"
  - "**/repositories/**"
  - "**/*.sql"
  - "**/migrations/**"
  - "**/jobs/**"
  - "**/cron/**"
  - "**/scheduler/**"
  - "**/queries/**"
  - "**/hooks/use*"
summary: "Performance-sensitive surfaces: request fan-out, query shape, scheduled jobs, client queries."
---
# performance lens — body (loaded on demand)

An opt-in lens. Loaded on demand by `/review:review-panel` **Step 2** when the diff touches a
performance-sensitive surface — **the Surface routing table below is the single authority for what
counts as one**, so a new surface registers here with no edit to the panel. When you select this
lens, route the diff to its surface section(s) and paste that section's **Focus** verbatim as
`{LENS_FOCUS}`, replacing the template's generic grounding paragraph with the surface's
**Grounding**. A diff spanning surfaces runs the lens once per surface touched.

Why this lens exists (rationale lives here, once): the author-agent loads a performance rule only
when its own edit matches the rule's `paths:`, and panel subagents receive no path-scoped rules
automatically — so a reviewer that does not deliberately read those rules re-approves the exact
regressions they encode. This lens is that deliberate read.

**Output contract (every surface):** the reviewer's return names which grounding files it read,
and each finding cites the rule file + section it rests on, or, where the repo has no written rule,
the mechanism from the Focus it rests on — a wrong finding is contradicted by its own citation, and
a clean verdict with no named reads is a failed run, not a pass.

**Grading (every surface):** a finding that says a read is "slow" or "expensive" without naming
the mechanism is graded **Minor** — the mechanism is what makes the finding actionable and a
wrong one refutable. On the query surfaces the mechanism is plan-level: a predicate landing in a
filter step instead of an index condition, the partitions still appended, a generic plan replacing
a specialised one, a large column decompressed or fetched per row. On `scheduled-jobs` there is no
plan to cite, so the equivalent mechanism is cadence arithmetic — the cohort (tenants ÷ phases),
the phase count or why the expression cannot stagger, firings per period, or the bucket a rate
limiter bounds — and a cadence finding that names one of those is graded on its merits, not
downgraded for lacking a plan.

## Surface routing

| Surface | Fires when the diff touches | Section |
|---|---|---|
| **request-path-fanout** | a request handler or service method that fans out to many reads (per item, per user, per team), or a migration adding large semi-structured or generated columns that a request path reads | below |
| **data-access-reads** | data-access code or a migration, **and** the matched hunks add or change **how a query is built or what SQL runs** — a query-builder chain, a raw SQL string, or index/partition DDL. Excluded: a mock regen, a pure-comment edit, and a test-only change — except where the changed test is a pin a performance rule requires (a skip pin asserting a read is never made, a rendered-SQL pin, a schema pin on index shape, a page-order or unbounded-read pin), which fires the surface on its own, since weakening the pin is how the guarantee is lost | below |
| **scheduled-jobs** | a cron expression, a scheduler registration, or a periodic job's body | below |
| **client-queries** | client-side data-fetching code — a query hook, its enable/gate predicate, its placeholder or deferral state, or a consumer of one (a pure-UI diff with no query code does not fire this surface) | below |

When the repo's own architecture rules define `paths:` globs for these surfaces, those globs decide
"touches"; otherwise route by what the hunk does. A further surface self-registers as a new row +
section once its conventions exist as a rule or doc to ground on — a surface with no written rules
and no mechanism list here is not routable (write the rule first).

## request-path-fanout

**Grounding:** read the repo's own architecture rules and schema snapshot, if any — any rules on
request fan-out budgets, batched reads, per-request memoization, and reading large columns on a
request path. These files are the source of truth — do not review from memory of them.

**Focus (`{LENS_FOCUS}`):** judge the diff against the grounding rules and flag violations with
the rule section (or mechanism) named: (1) new or widened parallel fan-out on a request path, with
the width it now reaches; (2) an **N+1** — a per-item data-access loop that should be one batched
keyed query, or a batched query whose key set is bound unsafely; (3) a request-path read of a large
semi-structured column contradicting the read-shape rules (selected or decompressed when it is not
consumed); (4) a performance refactor missing the guards the grounding rules prescribe; (5) an
**unbounded read** on a request path — no limit, no page, no window. Flag only what the diff
changes. Three more, each a known regression shape: (6) a **second serving path behind a flag**
that does not honour every request-scoping parameter the first path honours — enumerate them and
say which the new path threads; (7) a **lean / mode / lens flag** shipped without an orchestration
test asserting every read it claims to skip is never made, since the enumeration is the contract,
not the claim — and check the *default* mode's read set, not the feature mode's; (8) a **result
bound to `_`** at a call site inside a per-item fan-out, or allocation and
loop-invariant work rebuilt per item on the hot path — the call still pays for what it discards,
and the fix is a flag that skips the work plus a test proving the skip. This check lives on this
surface because the offending line is a call site in the handler, not in data-access code.

## data-access-reads

**Grounding:** read the repo's own architecture rules on query cost, if any — mandatory when
present, they are the mechanism reference this surface reviews against. Add its rules on migration
locks when a migration is in the diff. These files are the source of truth — do not review from
memory of them.

**Focus (`{LENS_FOCUS}`):** judge the diff against the grounding rules and flag violations with the
rule section (or mechanism) named, working in this order — each check needs the query text plus the
table's shape in the repo's schema snapshot (or its migrations), so read both:

1. **Bound columns.** List the columns the changed query binds in its `WHERE`. Is the tenant
   column among them, or does it reach the query only through a row-level security policy?
   Policy-only is the finding: row-level security is not an index boundary, so bind the tenant
   column in the query text.
2. **Partition key.** Is the table partitioned (check the schema, not the name)? If so, is the
   partition column itself bounded, and from both sides? A bound on a correlated timestamp prunes
   nothing. A floor that changes the row set is a per-caller call — the finding is a floor left
   implicit or a comment claiming a bound the query lacks; a floor declined on a caller that cannot
   lose the tail is fine when a comment names that population and a test pins the unbounded read.
3. **Index support.** Does an index lead on the bound equality columns and then the sort tuple, in
   that order? An index with the same columns in another order does not serve it. A **missing
   index** for a new access pattern at scale is the finding here. An **expression** index is
   stricter again — the predicate must normalise to the indexed expression exactly and ship with a
   test pinning that the index is used, rather than "there is an index on that column".
4. **A read that touches a large column it does not consume.** The table has a large
   semi-structured or unbounded text column and the changed query **selects** it (`SELECT *`, a
   scan into the whole model struct) or **evaluates** it (a `WHERE` on the blob), reached from a
   queue consumer, a per-row loop, or a request fan-out. A read already projected to the columns it
   consumes is not a finding. If the diff narrows a shared method rather than adding a new one,
   name whose other callers it regresses.
5. **Key-set binds.** A data-dependent slice expanded into an `IN (...)` list or similar is the
   finding when the engine re-plans per list length; prefer one array parameter, unnested.
6. **Offset paging inside a loop** — a drain or batch loop paging by offset instead of a keyset.
   Its exception is a read bounded to one page, with that bound stated in the method comment and
   pinned by a test; a business sort order is not an exception, since a keyset on that column plus
   `id` preserves it.
7. **An index drop or replacement** — the diff must name every reader of the dropped index and the
   columns each binds, and a "redundant" drop must rest on index-usage statistics rather than
   static reasoning.
8. **An EXPLAIN or plan claim in the PR body or a test** — ask whether the fixture can actually
   discriminate the two plans (many distinct partition-key values, a forced generic plan, index-only
   scans off), because a single-value fixture is not proof. Query cost at scale is a
   `requires-runtime` claim unless the fixture shows it.

Flag only what the diff changes.

## scheduled-jobs

**Grounding:** read the repo's own architecture rules on scheduler cadence and query cost, if any.
These files are the source of truth — do not review from memory of them.

**Focus (`{LENS_FOCUS}`):** judge the diff against the grounding rules and flag violations with the
rule section (or mechanism) named: (1) a new or changed cron string with no cohort arithmetic stated
(tenants ÷ phases, and what lands on phase 0), or a per-minute expression not justified by a
freshness target plus a window-free selector; (2) a per-tenant schedule emitted on a path that
bypasses the repo's staggering helper, if it has one, with no stated reason; (3) operations sharing
a rate-limit bucket that do not share a stagger group — a limiter caps a window's count without
spacing requests inside it; (4) a per-tenant job whose first read does not bind its tenant, even
under a system-wide scope; (5) a lookback or fan-out walk not bounded by what the tenant actually
has (enabled features, plan, active records) before the read, or loop-invariant work rebuilt inside a
per-date loop; (6) a scope gate whose lookup can fail and defaults to the union rather than
erroring; (7) a cadence, phase, or scope change shipping with no observation metric in this diff
and no prior PR named. Flag only what the diff changes.

## client-queries

**Grounding:** read the repo's own architecture rules on client data fetching, if any — query
enable/gate predicates and placeholder or deferral state. These files are the source of truth — do
not review from memory of them.

**Focus (`{LENS_FOCUS}`):** judge the diff against the grounding rules and flag violations with
the rule section (or mechanism) named: (1) a query shipped ungated to its consumers, or gated on
the wrong signal, so it fires before its inputs are ready or fires twice; (2) placeholder/deferral
state handled contrary to the readiness rules; (3) an over-fetch a lean backend projection should
absorb. Flag only what the diff changes.
