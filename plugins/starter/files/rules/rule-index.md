---
# Scoped on purpose: this is a consulted reference, not an always-loaded rule. A rule with no
# `paths:` loads every session; a full rule ledger in context every session would bloat it. It
# auto-loads when a rule source or this index is edited, where "is the index still in sync?"
# matters most, and is otherwise reached on demand.
paths:
  - ".claude/rules/**"
  - "docs/architecture-rules.md"
---

# Rule-enforcement index

The single map over the repo's rules: where each rule lives, what enforces it, and how hard.
It is a thin index over the sources (the always-loaded and path-scoped rules in `.claude/rules/`,
the repo's own architecture rules document, its tests and linters, and the agentic-workflow-kit
hooks). It does not restate rule text. Its point is to make the unenforced rules visible, so they
are tracked candidates, not silent gaps.

## How to read the Hardness column

| Hardness | Meaning |
|---|---|
| `ci-hard` | A deterministic check (a test, a linter, a type check) that runs in CI and blocks the merge. The row names the check. |
| `hook` | A Claude Code hook that warns or blocks at edit or commit time. |
| `soft` | A pattern a test cannot easily catch, caught by the review panel or an advisory hook. |
| `always-loaded` | Posture loaded into every session by an unscoped `.claude/rules/` file. |
| `path-scoped` | A rule that loads when matching files are edited. |
| `human` | A judgment call decided at a human review. |
| `UNENFORCED` | No mechanism yet. A candidate for a test or a hook. |

Each `ci-hard` row names its check in the "Enforced by" column, and the guard below checks that
the name resolves.

## Starter rules

| Rule | Requires | Enforced by | Hardness |
|---|---|---|---|
| operational-principles | verify claims, find root causes, plan, keep changes surgical, keep the human able to review | `.claude/rules/operational-principles.md` | always-loaded |
| comments | comments carry the why, state current behaviour, no pending-change narration | `.claude/rules/comments.md`; the review panel's simplification and stale-comment lenses | always-loaded |
| conversational-register | plain words first, no coined shorthand, sequence open decisions | `.claude/rules/conversational-register.md` | always-loaded |
| parallel-agent-worktrees | one build per tree, commit or isolate before delegating, no tree-wide discard | `.claude/rules/parallel-agent-worktrees.md`; the worktrees plugin's subagent anchor hook | always-loaded |
| codex-compatibility | Claude terms translate to Codex equivalents | `.claude/rules/codex-compatibility.md` | always-loaded |
| docs-conventions | content placement, CLAUDE.md and SKILL.md size and frontmatter | `.claude/rules/docs-conventions.md`; the guards plugin's post-edit dispatcher (DOC-001 to DOC-004) | path-scoped |
| surviving-mutants | a surviving mutant is weak test, redundant code, or a wrong explanation | `.claude/rules/surviving-mutants.md` | path-scoped |

## Kit guards

| Rule | Requires | Enforced by | Hardness |
|---|---|---|---|
| review cadence | a review panel run every few commits and before a PR | review plugin `review-cadence.sh` | hook |
| generated files | no hand edits to a file whose header marks it generated | guards plugin `post-edit-dispatcher.sh` | hook |
| commit gate | the configured `commit_gate` command passes before a commit | guards plugin `commit-gate.sh` | hook |
| lockfile sync | a staged package.json leaves its lockfile in sync | guards plugin `lockfile-gate.sh` | hook |
| pinned npx | `npx -y` only with an exact version | guards plugin `block-unpinned-npx.sh` | hook |
| permission deny list | no pipe-to-shell installs, no direct merge or push to the base branch | `.claude/settings.json` deny list from `/starter:setup` | hook |

## Your repo's rules

Add one row per rule the team writes, under a heading per area. Number rules in the source
document as `## <ID>: <title>` (for example `## API-003: Every endpoint declares its auth level`)
and start the row with the same ID. A row looks like this (inside a code fence here, so the guard
reads it as an example, not a rule):

```markdown
| Rule | Requires | Enforced by | Hardness |
|---|---|---|---|
| API-003 Endpoints declare auth | every endpoint names its auth level | `TestEveryEndpointDeclaresAuth` | ci-hard |
```

## Keeping this index honest

The guard `check-rule-index.sh` (written by `/starter:setup` to `scripts/check-rule-index.sh`)
fails on three kinds of drift. Run it in CI next to the tests:

```bash
scripts/check-rule-index.sh --rules docs/architecture-rules.md --index .claude/rules/rule-index.md --enforcers .
```

1. **Rule coverage.** Every `## <ID>:` heading in the rules document has a table row here that
   starts with that ID. A rule named only in prose does not count.
2. **Referential integrity.** Every test name in an "Enforced by" cell (a backticked identifier
   starting with `Test` or `test_`) is declared somewhere under the enforcer roots.
3. **Hard rows name an enforcer.** Every row whose Hardness cell is `ci-hard` names a test or a
   backticked command in its "Enforced by" cell.

The guard does not judge whether a row's hardness is right, or whether the index is complete for
areas without numbered rules. Those are review calls.
