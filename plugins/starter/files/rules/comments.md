---
# No paths: comment taste is universal, so this loads every session. Kept brief
# (treat like CLAUDE.md). A language-specific rule file you add inherits these.
---

# Comment Conventions (general)

Applies to comments in any file — Go, shell, proto, TypeScript, Python, SQL (incl. migrations), Markdown.

- **Earn the line.** A comment carries what the code cannot: the *why*, an invariant, a precondition, a sharp edge ("looks wrong, is correct because…"). Restating the code is noise — delete it. Impactful over verbose: one load-bearing sentence beats a paragraph.
- **Capture the learning, not the incident.** When a change encodes a lesson, write the lesson as a durable principle, once, where it lands — the regression guard's assertion, the rule, the changelog entry. Do not re-narrate the episode that produced it.
- **Reference stable points sparingly.** A PR / issue / rule ID is a fine anchor, but thread it through *one* comment, not many. The same `#NNNN` or instance story repeated across files and comments is over-indexing — the reader needs the principle and at most one pointer to dig deeper. The full episode belongs in the changelog / ADR / PR, not echoed in every nearby comment.
- **State current behavior, not a pending change or a rollout posture.** Describe what the code does *now*, never what another PR will change ("until X lands", "not yet available", "in a follow-up once Y merges"). The same trap in flag-gated work is **rollout-state narration** — a comment that describes the *current phase of a migration* rather than the code's contract ("stays dark until an operator flips the flag", "for now we only dual-write", "during rollout"): it reads as true today but expires silently at GA, and the reader cannot tell a durable invariant from a transient posture. State the durable contract instead (what the flag *gates*, not which phase we happen to be in). Such comments rot silently when the referenced change lands or the flag flips, and mislead the next reader — put cross-PR sequencing and rollout phases in the PR description / rollout runbook, not the code. (Runtime-temporal language like "until the transaction commits" is fine; the target is a claim that expires when *code ships* or *a flag flips*.)
