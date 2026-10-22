---
id: domain-lenses
title: A schema change pulls in the database lens, and the team's own lens
plugins: [review, review-lenses]
tags: [review-panel, lenses]
---

# Domain lenses that pick themselves

## When to use it

Some changes need a specialist's eye: a schema migration, a tenant-scoped query, a sync loop.
You want the review panel to bring that specialist in only when the diff calls for it, and you
want to add your team's own specialists without editing the kit.

## The scenario

A branch adds a migration and changes a billing handler. Your team keeps a billing lens of its
own in `.claude/review-lenses/billing.md`. Later the team writes down its architecture rules and
points the `architecture_rules_file` setting at them.

## Run it

1. Install the `review-lenses` plugin next to `review` (or install `all`).
2. Run `/review:review-panel`. It asks the `review-lenses` skill for its lens folder and passes
   that folder and `.claude/review-lenses` to its selector with the branch's changed paths.
3. Each selected lens runs as its own reviewing subagent with that lens's Focus and Grounding.
4. To add a lens, write a file with a header (`lens`, `applies-to`, `summary`) and the two
   sections. To change a plugin lens's globs, copy it into `.claude/review-lenses/` under the
   same `lens:` name: the repo's copy wins.

## What to expect

- The migration selects `database-migrations`, and the billing handler selects the team's
  `billing` lens. A README-only change selects none.
- `architecture-rules` is offered only once `architecture_rules_file` names a document.
- A lens file with no `applies-to` stops the selector with an error naming the file.

## If it goes wrong

- A lens never runs: check its `applies-to` globs against `git diff --name-only <base>`. A glob
  with no `/` matches only at the repo root.

`checks.sh` runs the selector over the fixture's changed paths with no model.
