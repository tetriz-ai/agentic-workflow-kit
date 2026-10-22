---
lens: database-migrations
applies-to:
  - "**/migrations/**"
  - "**/migrate/**"
  - "**/*.sql"
  - "**/schema.rb"
  - "**/*.prisma"
  - "**/models/**"
  - "**/model/**"
  - "**/entities/**"
  - "**/dao/**"
  - "**/repository/**"
  - "**/repositories/**"
summary: "Schema changes: table and column count, value ownership, and what breaks at 10x the data."
---
# database-migrations lens — body (loaded on demand)

An opt-in lens. Loaded by `/review:review-panel` **Step 2** when the diff changes a migration, a schema
snapshot, or an ORM model struct. Paste the **Focus** block verbatim as `{LENS_FOCUS}` and the
**Grounding** block in place of the template's default grounding.

The Focus below carries its own scope boundary, because only Focus and Grounding reach the
reviewing subagent — a boundary written outside them would be read by the dispatcher and dropped
before the reviewer ever saw it.

## Focus (`{LENS_FOCUS}`)

**the shape of the schema: whether these tables should exist, in this number, what happens to
them as they grow, and whether the migration that creates them is safe to run.** Four dimensions —
and a hard scope boundary, because other lenses and gates already cover parts of schema review and
duplicating them wastes the author's triage:

**1. Table-count minimalism — could these N tables be N−1?** Name the specific collapse and say
whether it is warranted:
- a **1:1 satellite** that always joins back to its parent — fold into the parent unless it earns
  separation by storage pressure on a fat column (TOAST or its equivalent), a materially different
  write rate, or a distinct retention/lifecycle;
- a **per-variant table family** (`payments_card`, `payments_bank`, …) where one table plus an enum `kind`
  column carries it — and check whether the relation already has an owner elsewhere before adding
  any of them;
- a **narrow single-metric table** — usually a column on an existing row, and a monotonic counter
  additionally answers no windowed question ("how many last week") and cannot be backfilled;
- an **EAV / key-value table** standing in for columns whose key set is known and closed.

**Apply the inverse guard with equal force — this lens is not "fewer tables wins."** Do *not* push
a collapse when row counts, retention, or write rates genuinely diverge; a legitimately-separate
family is the common case, and a wrong collapse is more expensive to undo than a wrong split. And
flag the mirror defect: one wide table whose column groups are mutually exclusive (half NULL for
any given row, or a set meaningful for only one value of a `kind` column) is the same modelling
failure inverted.

**2. Normalization ownership.** A denormalized copy of a value that already has an owner elsewhere
— especially across databases — owes exactly two things stated somewhere durable: the read path
that justifies avoiding the hop, and what reconciles it when the source of truth changes. A copy
missing **either** of them is the finding — one without the other still drifts. Also: repeated groups, and a partial or transitive dependency on a
composite key.

**3. Growth class.** Assign each new table one — bounded / per-tenant / per-person / per-event /
per-day — then name *the first thing that breaks* at 10× that class: an unpartitioned time-series
table, a fan-out join, a hot row every write contends on, a counter that serializes concurrent
writers. A per-event or per-day table with no retention or partitioning answer is a finding on its
own. Claims that depend on production row counts you cannot see are `requires-runtime` findings
naming the check an operator should run — never a number you inferred.

**4. Migration safety.** Will this migration run safely against a live database of production size?
Flag DDL that takes a long or table-wide lock on a large table (adding a non-nullable column with a
default the engine rewrites, building an index without the concurrent option, changing a column
type), a backfill done inside the schema migration instead of in bounded batches, a rename or drop
that breaks code still deployed (no expand-then-contract), a missing or lossy down migration where
the repo expects one, and an edit to a migration that has already been applied. Name the lock or
the failure and the order of operations that avoids it.

**SCOPE BOUNDARY — do not raise these; they are already covered on this same diff and a duplicate
costs the author a second triage for nothing.** Anything the team's own review rules already cover
(the team-rules lens applies them to migration / model / SQL files, and the whole database category
there is its territory, not yours). Tenant scoping and row-level security policy correctness (the
`multi-tenant-isolation` lens). Query-plan and latency work on an existing surface (the
`performance` lens). Migration filename conventions and other checks the repo gates mechanically.
SQL comment taste (the `simplification` lens). If your finding maps onto any rule or lens named in
this paragraph, **drop it silently** — omit it from your output entirely rather than mentioning it.
What is left, and what this lens exists for, is the question none of them ask: *how many tables, do
they earn their separation, who owns each denormalized value, what breaks at 10×, and is the
migration safe to run.*

## Grounding (paste in place of the template's default grounding paragraph)

Read these before grading. Start with the team's rules — they are the list you must check every
candidate finding against in order to honour the scope boundary above:

- The repo's own architecture rules and team review rules, if any — the database rules the
  boundary defers to.
- The repo's data-model doc, if any — every existing table and its writer. **The cheapest finding
  in this lens is a new table duplicating an existing one's role**, and it is invisible without a
  map of the existing tables.
- The repo's own schema-design guidance, if any, for storage / write-rate / retention economics
  when judging whether a 1:1 split earns itself.

Ground every claim in the actual DDL. The repo's committed schema snapshot, if any, is the current
schema — read it for the sibling tables rather than reconstructing from migration history, which
shows changes and not the current state (with no snapshot, read the migrations in order). **When
the diff changes an ORM model struct with no migration in the same diff, the schema will not
contain the new table or column** — treat the struct as the *proposed* schema and review its shape
on that basis, and flag the absent DDL: a model the schema does not have fails at runtime, not at
review. When you assert a table "always joins back to" its parent, confirm it by finding the reads
(`grep` the data-access code for the table name): a 1:1 with an independent read path is not a
satellite, and a divergent retention sweep is positive evidence it should stay separate.
