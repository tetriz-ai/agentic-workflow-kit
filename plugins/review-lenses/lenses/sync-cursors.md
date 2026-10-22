---
lens: sync-cursors
applies-to:
  - "**/sync/**"
  - "**/*sync*"
  - "**/connector/**"
  - "**/connectors/**"
  - "**/ingest/**"
  - "**/ingestion/**"
  - "**/fetch/**"
  - "**/crawler/**"
  - "**/importer/**"
  - "**/importers/**"
summary: "Resumable fetch and sync loops: a cursor advances only after the page it covers is durably handed off."
---
# sync-cursors lens — body (loaded on demand)

An opt-in lens. Loaded on demand by `/review:review-panel` **Step 2** only when the diff changes a
resumable fetch/sync loop — code that pages through an external source and persists a cursor,
page token, or high-water mark so a later run can resume. When you select this lens, paste the
**Focus** block below verbatim as `{LENS_FOCUS}` in the subagent prompt template. Ground against
the changed loop and its cursor/checkpoint dataflow; the template's generic grounding paragraph
applies as written, plus the source-of-truth below.

Context: the rule this lens defends is that **a cursor advances only after the page it covers has
been durably handed off**. If the repo has a mechanical check for the common violation — a
per-record `continue` on error in a loop that advances a cursor/high-water mark — do not re-flag
what that check already blocks. This lens is the **judgment backstop** for what such a check cannot
see; flag what it structurally misses.

## Source of truth

The repo's own architecture rules on cursor advancement and resume, if any — the unsafe vs safe
patterns, the reference fixes (break on error, return on a decode error), and any convention for
clearing a stale page token. Read them before flagging. With none, ground on the rule above.

## Focus (`{LENS_FOCUS}`)

Trace the cursor/high-water dataflow of the changed sync loop and find the resume-correctness
failure modes a mechanical check cannot catch. Flag: (1) **PageToken-clear-without-Checkpoint** — an
error path that clears a stale resume page token/page cursor in memory but returns *without*
persisting the clear through the loop's checkpoint call; when the run then fails, the in-memory clear
is lost and the next run reloads the stale token and loops forever. (2) A **cursor advanced past a
skipped record** in a shape a simple check does not recognize — e.g. a helper that returns a max the
caller checkpoints, an append-to-slice cursor, or a high-water threaded through a struct field. (3)
A **misused lint-exemption marker** on such a loop — one placed on a genuinely per-record loop (the
justification does not hold: the loop advances a shared cursor, not a per-page/per-entity one). (4)
A cursor **saved on partial success** that a later run reads as complete (a loop that returns the
advanced cursor even though some records failed, masking degradation). Every finding needs the
concrete resume scenario: which record is skipped, how the cursor advances past it, and why the
next run never re-fetches it. Pairs with runtime-attack; do not restate a case a mechanical check
already gates.
