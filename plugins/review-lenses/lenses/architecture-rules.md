---
lens: architecture-rules
applies-to:
  - "**/*.go"
  - "**/*.py"
  - "**/*.ts"
  - "**/*.tsx"
  - "**/*.js"
  - "**/*.jsx"
  - "**/*.java"
  - "**/*.kt"
  - "**/*.rs"
  - "**/*.rb"
  - "**/*.cs"
  - "**/*.swift"
  - "**/*.php"
  - "**/*.proto"
  - "**/*.sql"
needs-setting: architecture_rules_file
summary: "The team's own architecture rules, from the document the architecture_rules_file setting names."
---
# architecture-rules lens — body (loaded on demand)

An opt-in lens. `/review:review-panel` offers it only when the `architecture_rules_file` setting names a
document of the team's architecture rules (layering, ownership of data, which module may call
which, error and logging conventions). It applies that document to the diff. Paste the **Focus**
block below verbatim as `{LENS_FOCUS}`, and the **Grounding** block in place of the template's
default grounding paragraph.

It is a soft lens: it flags a likely violation for the author, it is not a gate. A rule the repo
already enforces mechanically (an architecture test, a linter, a CI check) is not re-flagged:
that check is the authority, and a second opinion on it is noise.

## Focus (`{LENS_FOCUS}`)

Review this diff against the team's architecture rules document (path below). For each rule:

1. Decide whether the diff can break it. Skip a rule about a surface the diff does not touch.
2. Skip a rule the document marks as mechanically enforced, or that names its own test or lint;
   say once which rules you skipped for that reason.
3. For a rule the diff can break, read the changed code and the code it calls, and report a
   violation only with: the rule's id or heading, the file and line, what the code does, and
   what the rule asks for instead.

Also report a change that the rules do not cover but that sets a precedent others will copy
(a new layer, a new cross-module call, a new way to read another module's data): name it as a
candidate rule for the team, not as a violation. Grade a violation Important when it breaks a
stated boundary (data ownership, a forbidden dependency), Minor when it is a convention.

## Grounding (paste in place of the template's default grounding paragraph)

Read the architecture rules document at the path the `architecture_rules_file` setting gives,
in full, before reading the diff; quote the rule you apply. Ground every finding in the changed
code, not in the rule's intent alone. If the document does not exist at that path, report
"architecture-rules lens: no rules document at <path>" and stop: an absent document is a
setup gap to fix, not a clean pass.
