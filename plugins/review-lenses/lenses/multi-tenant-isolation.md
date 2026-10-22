---
lens: multi-tenant-isolation
applies-to:
  - "**/dao/**"
  - "**/repository/**"
  - "**/repositories/**"
  - "**/models/**"
  - "**/db/**"
  - "**/store/**"
  - "**/storage/**"
  - "**/*.sql"
  - "**/migrations/**"
  - "**/services/**"
  - "**/handlers/**"
  - "**/api/**"
  - "**/server/**"
summary: "Backend data paths: the right tenant-scoping wrapper for the flow, and no scope bleeding across a transaction."
---
# multi-tenant-isolation lens — body (loaded on demand)

An opt-in lens. Loaded on demand by `/review:review-panel` **Step 2** on any diff that touches a backend
data path (not a frontend-only diff). When you select it, paste the **Focus** block below verbatim
as `{LENS_FOCUS}`, and paste the **Grounding** block in place of the template's default grounding
paragraph. It stays a **soft** review lens — it *flags* a wrong scoping choice for the author to
fix, it is **not** a hard gate. Any deterministic gate is the repo's own architecture tests; this
lens catches the judgment they cannot — picking the wrong scoping wrapper for the flow, or a scope
setting that bleeds across a transaction.

## Focus (`{LENS_FOCUS}`)

tenant isolation and scoping correctness on every data path the diff touches:

- **Tenant isolation:** every data access runs through the repo's tenant-scoped access layer (never
  a raw connection or ORM handle that bypasses it); background / cross-process work with no inbound
  tenant context establishes the tenant scope explicitly before it touches data, and keeps it for
  the whole unit of work. A lookup keyed on an entity ID alone (no tenant key) is a cross-tenant
  leak.
- **No open transaction across a slow external call:** flag any tenant-scoped transaction whose
  closure makes a slow external call — an LLM request, an outbound HTTP call, an object-store read —
  *between* data accesses. When a scoped transaction opens on the first data access, a read/write
  followed by such a call (then more data work in the same scope) leaves the transaction idle across
  the call; the database may kill it on its idle-in-transaction timeout and poison the rest of the
  handler. The remedy is phased scopes: short data scopes on either side, the external call outside
  any scope. Grade **Important** (a reliability defect, not a data leak).
- **Secondary scoping within a tenant (row-level security, per-user or per-plan visibility), where
  the repo uses it — grade the wrapper choice against the repo's own rules.** When the diff reads
  from or writes to a table under such a policy, **read the repo's rule for which access wrapper
  fits which flow now and grade the diff against it** — do not grade from memory. The failure modes
  to attack:
  - **Wrong wrapper for the flow** — a user-facing read that skips the visibility filter leaks rows
    the viewer may not see; an ingestion write on a read-filtered wrapper; a status write-back that
    re-filters when it should bypass. Flag the inverse too: a filtering wrapper on an UPDATE/DELETE
    silently drops the rows it filters out.
  - **Scope-setting bleed** — flag a session-level setting (for example a row-level-security
    variable or a session time zone) set or bypassed for one statement that can bleed into a
    *subsequent* read in the same transaction.
  - **Write-back not fail-loud** — flag a single-row write-back (UPDATE by id) that does not check
    rows affected / return a typed not-found error on 0; a zero-row write returns nil and hides the
    failure.
- **New scoped table:** it is registered wherever the repo enumerates scoped tables (a registry,
  a policy list, a migration that enables row-level security), or carries the repo's explicit
  not-scoped marker.

Grade **Critical** for a real cross-tenant or cross-scope leak (out-of-scope data reaches a user,
or a tenant sees another tenant's rows); **Important** for a wrong wrapper that fails closed
(silently drops rows / re-queues forever) or a scope setting that can bleed across a transaction;
**Minor** for a missing marker or comment where the behavior is already correct.

## Grounding (paste in place of the template's default grounding paragraph)

Confirm each scoping claim against the repo's own architecture rules and schema snapshot, if any —
its tenant-scoping rules, its row-level security policies, and its rule for *which wrapper for
which flow*; do not assert a rule from memory. Where the repo's architecture tests enforce the
mechanical parts (which wrapper a data-access file uses, that a new scoped table is registered),
do **not** re-flag what they already gate. This lens covers the judgment they cannot: the
*flow → wrapper* match, a scope setting that bleeds across a transaction, and the rows-affected
fail-loud contract. For the external-call-in-scope bullet, the defect is a single scope whose
closure both touches the database and makes a slow external call; if the repo has a runtime
tripwire for open transactions, check which paths it actually covers — on paths it does not cover
this lens is the sole enforcement, so flag them all the harder. If a conclusion depends on runtime
state not in the diff (the database role a service connects as, whether a write uses `RETURNING`),
follow the template's `requires-runtime` path rather than grading it clean.
