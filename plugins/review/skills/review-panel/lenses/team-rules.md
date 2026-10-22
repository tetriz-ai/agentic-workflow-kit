# team-rules lens — body (loaded on demand)

Loaded on demand by `/review:review-panel` **Step 2**. It runs on every non-docs diff (source logic and
config or tooling alike) and on a routed design doc, but only when the team rules file exists.
The file is the `team_rules_file` setting, default `.claude/review-rules.md`, resolved against
the repo root. When the file is missing or has no rules, skip the lens and log
`review-panel: team-rules skipped (no rules at <path>)`. When you select it, paste the **Focus**
block below verbatim as `{LENS_FOCUS}`, with `<RULES_FILE>` replaced by the resolved path, and
paste the **Grounding** block in place of the template's default grounding paragraph.

## The rules file

A Markdown file the team owns. Each rule is a `##` heading with an ID and a title, a one-line
statement, and an `Apply to:` line naming the files or diff shapes it covers:

```markdown
## DB-001: New tables carry an owner column

Every new table names the service or team that owns its rows.

Apply to: migrations, schema files
```

IDs are the team's own; a prefix per category (`DB-`, `API-`, `TEST-`, `OPS-`) keeps them
grouped. The `harness-education` skill appends new candidates to this file when the team agrees
on a rule in review.

## Focus (`{LENS_FOCUS}`)

the team's own review rules in `<RULES_FILE>`. **Read the file now and apply it to the diff**;
it is the single source and is deliberately not copied into this lens, so do not work from
memory. These are the judgment calls automated gates cannot catch: design and abstraction,
contract and schema choices, test structure, operational readiness, and code clarity, as the team
wrote them. **Dispatch by the diff's file types**: read every rule's `Apply to:` line and apply
each rule whose line matches a changed file or what the diff proposes; work off those lines, not
a fixed list here, so a rule added later is picked up automatically. A rule about tests also
applies when the diff adds non-trivial code with no peer test. Apply every rule in a matched
group, not a hand-picked subset. **Do not re-flag anything a deterministic gate already
enforces** (a linter, a type check, a test the repo runs in CI): this lens covers only the
judgment layer on top of those gates. Every finding must cite the rule ID it maps to in the
`rule` field.

## Grounding (paste in place of the template's default grounding paragraph)

Ground each finding in `<RULES_FILE>`: confirm the rule's text before citing its ID, and never
invent an ID that is not in the file. These are judgment rules with no test of their own, so
never claim a test enforces one. If the diff touches state not derivable from source (a table's
owner, the role a service connects as at runtime, live data), follow the template's
`requires-runtime` path rather than grading it clean.
