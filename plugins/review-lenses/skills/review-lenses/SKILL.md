---
name: review-lenses
description: >-
  Holds the opt-in domain review lenses that /review:review-panel picks by the paths a diff
  changes. They cover database migrations, multi-tenant isolation, sync cursors, performance and
  the team's architecture rules, which the architecture_rules_file setting names. Use when the
  review panel asks for the lens folder, or to see which domain lenses exist and how to add one.
user-invocable: true
---

# review-lenses: the opt-in lens catalog

The lens folder is `${CLAUDE_PLUGIN_ROOT}/lenses`. (On a runtime that does not fill in
`${CLAUDE_PLUGIN_ROOT}`, it is the `lenses` folder two levels above this file.)

`/review:review-panel` passes this folder to its `select-lenses.sh`, which picks the lenses whose
`applies-to` globs match a changed path. Each lens file says, in its own first paragraph, what it
checks and when to stand down; its globs only make it a candidate.

| Lens | File | Checks |
|---|---|---|
| database-migrations | `lenses/database-migrations.md` | schema changes: table and column count, value ownership, 10x breakage |
| multi-tenant-isolation | `lenses/multi-tenant-isolation.md` | backend data paths: the right tenant-scoping wrapper, no scope bleed across a transaction |
| sync-cursors | `lenses/sync-cursors.md` | resumable fetch and sync loops: the cursor advances only after its page is handed off |
| performance | `lenses/performance.md` | request fan-out, query shape, scheduled jobs, client queries |
| architecture-rules | `lenses/architecture-rules.md` | the team's own architecture rules document (offered only when the setting below is set) |

## The architecture rules document

The architecture-rules lens applies the document the `architecture_rules_file` setting names.
Resolve it and pass the path into that lens's Grounding:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get architecture_rules_file '${user_config.architecture_rules_file}'
```

Blank means the selector does not offer the lens.

## Adding or tuning a lens

Write `.claude/review-lenses/<name>.md` in the repo with the same header:

```markdown
---
lens: <name>
applies-to:
  - "src/billing/**"
summary: "One line on what it checks."
---
## Focus
What the reviewing subagent looks for, with its own scope boundary.
## Grounding
What it reads before it judges.
```

The panel reads the repo folder after this one, so a repo lens with the same `lens:` name replaces
the plugin's (copy a plugin lens there to change its globs). A lens file with no `applies-to` makes
the selector stop with an error that names it.
