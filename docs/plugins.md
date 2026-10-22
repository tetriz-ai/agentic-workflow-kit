# Plugins

Each section covers one plugin and the scenario under [examples/](../examples/README.md) that
replays it. Each skill's full
contract is its `SKILL.md`, linked below. [settings.md](settings.md) lists every setting the
plugins read.

You or the agent invoke a skill. Hooks run on their own around the agent's commands and edits.

## review

`/review:review-panel` grades the diff so far with one fresh subagent per lens, a focus such as
correctness or security. A hook nudges it every few commits, so you fix Critical and Important
findings while the change is fresh.

Before a pull request, and on high-stakes changes, the panel also sends your committed changes to
a second model through the cross-model lenses. That is Codex, through `/review:codex-lens`, unless
Codex wrote the change, then Claude, through `/review:claude-lens`. They run whenever that model's
CLI is on your PATH, and no setting turns them off.

`/review:harness-education` proposes agent rules, review rules for `.claude/review-rules.md` and
doc edits from your merged pull requests.

Use it when you want findings on the work so far, while you still remember it.

```text
/review:review-panel
/review:review-panel pre-pr
```

- **Keep in mind:** the cross-model lenses review committed work only.
- **Keep in mind:** findings never block a commit or a merge.
- **Skills:** [`review-panel`](../plugins/review/skills/review-panel/SKILL.md),
  [`codex-lens`](../plugins/review/skills/codex-lens/SKILL.md),
  [`claude-lens`](../plugins/review/skills/claude-lens/SKILL.md),
  [`ocr-lens`](../plugins/review/skills/ocr-lens/SKILL.md),
  [`harness-education`](../plugins/review/skills/harness-education/SKILL.md).
- **Hooks:** nudge a panel run every few commits and before a pull request.
- **Hooks:** ask the agent to recheck a large edit.
- **Scenario:** [mid-feature-review](../examples/mid-feature-review/story.md) replays the
  cadence nudge, not the review.

## review-lenses

Opt-in domain lenses that the panel picks by the paths a diff changes. They cover database
migrations, multi-tenant isolation, sync cursors, performance and your own architecture rules.

Use it when some paths need a reviewer that knows your team's rules for them.

A team lens is a Markdown file in `.claude/review-lenses/` whose `applies-to` globs pick the
paths it reviews. This one is from the [domain-lenses](../examples/domain-lenses/story.md)
scenario:

```markdown
---
lens: billing
applies-to:
  - "services/billing/**"
summary: "Money is integer cents, every charge is idempotent."
---
## Focus
Amounts are integer cents end to end; a retried charge cannot charge twice.
## Grounding
Read the charge path from the handler to the payment client.
```

- **Keep in mind:** a repo lens replaces the plugin's lens of the same name.
- **Keep in mind:** the architecture-rules lens needs `architecture_rules_file` to name your rules.
- **Skills:** [`review-lenses`](../plugins/review-lenses/skills/review-lenses/SKILL.md).
- **Hooks:** none.
- **Scenario:** [domain-lenses](../examples/domain-lenses/story.md) replays which lenses are
  chosen, not their findings.

## ship

`/ship:pr` opens or updates a pull request linked to an issue. With the `/starter:setup` deny
list, the agent cannot merge, so a human merges. `/ship:pr-feedback` gathers every review
surface. `/ship:codex-sweep` fixes and answers the hosted Codex reviewer's threads.
`/ship:github-issues` files triaged issues.

Use it when a branch is ready for a pull request, or a pull request has review comments.

```text
/ship:pr
/ship:pr-feedback 42
```

- **Skills:** [`pr`](../plugins/ship/skills/pr/SKILL.md),
  [`pr-communication`](../plugins/ship/skills/pr-communication/SKILL.md),
  [`pr-feedback`](../plugins/ship/skills/pr-feedback/SKILL.md),
  [`codex-sweep`](../plugins/ship/skills/codex-sweep/SKILL.md),
  [`github-issues`](../plugins/ship/skills/github-issues/SKILL.md).
- **Hooks:** nudge a pull request step the agent skipped.
- **Hooks:** remind you when a push leaves the description behind.
- **Scenario:** [stale-pr-description](../examples/stale-pr-description/story.md) replays the
  reminder, not the rewrite.

## plan

`/plan:tech-design-doc-writing` drafts a design doc one open decision at a time. `/plan:tech-design-doc-review`
checks it, `/plan:task-breakdown` cuts it into shippable slices, and `/plan:adr` records a
decision.

Use it when a change spans several parts and needs a design before the code.

```text
/plan:tech-design-doc-writing
/plan:tech-design-doc-review docs/rfc/my-design.md
/plan:task-breakdown
```

- **Keep in mind:** design docs go in `rfc_dir`, `docs/rfc` by default.
- **Keep in mind:** ADRs go in `adr_dir`, `docs/adr` by default.
- **Keep in mind:** the writing skill stops at each open decision for your answer.
- **Skills:** [`tech-design-doc-writing`](../plugins/plan/skills/tech-design-doc-writing/SKILL.md),
  [`tech-design-doc-review`](../plugins/plan/skills/tech-design-doc-review/SKILL.md),
  [`task-breakdown`](../plugins/plan/skills/task-breakdown/SKILL.md),
  [`adr`](../plugins/plan/skills/adr/SKILL.md).
- **Hooks:** none.
- **Scenario:** none, since it needs a live model. Start with `/plan:tech-design-doc-writing`.

## queue

`/queue:ship-task` ships one issue end to end. `/queue:ship-queue` drains a labelled queue, one
pull request per issue. It marks an issue that needs your decision and moves on.
`/queue:bug-hunt` finds bugs and files grounded issues.

Use it when you have labelled issues that each fit in one pull request.

```text
/queue:ship-queue --list
/queue:ship-queue --limit 3
```

- **Keep in mind:** the queue takes your assigned issues labelled `queue_label`, `ship-queue` by default.
- **Keep in mind:** usage pacing is experimental, so bound a run with `--limit N`.
- **Skills:** [`ship-task`](../plugins/queue/skills/ship-task/SKILL.md),
  [`ship-queue`](../plugins/queue/skills/ship-queue/SKILL.md),
  [`bug-hunt`](../plugins/queue/skills/bug-hunt/SKILL.md).
- **Hooks:** show the queue's state at session start.
- **Scenario:** [usage-paced-queue](../examples/usage-paced-queue/story.md) replays the
  experimental pause before the usage limit, not the drain.

## worktrees

Hooks copy the local untracked files you list in `.worktreeinclude` into each new git worktree.
They also anchor subagents to the worktree they were started from.

Use it when agents work in several git worktrees and each one needs local files such as `.env`.
List the files in `.worktreeinclude` at the repo root. Each one is copied when present, and a
`required` one is also reported when missing:

```text
optional .env
required config/local.yml
```

- **Keep in mind:** a path must stay inside the repo.
- **Keep in mind:** a folder ends in `/**`.
- **Keep in mind:** install heavy folders such as `node_modules` in the worktree instead.
- **Skills:** none.
- **Hooks:** run after `EnterWorktree` and before each subagent starts.
- **Scenario:** [worktrees-in-parallel](../examples/worktrees-in-parallel/story.md).

## guards

Hooks block an agent's commit when your test command fails or a lockfile is stale. They block
an `npx` call that would install an unpinned package, because an agent's `npx` installs a
missing package without asking. They also format edited files, and flag edits to generated files
and problems in edited `CLAUDE.md` and `SKILL.md` files.

Use it when an agent's commits must pass your checks, and its edits should be formatted. Set the
commands with `/starter:setup`, which writes them to `.agentic-workflow-kit.json`:

```json
{
  "commit_gate": "make test",
  "format_command": "prettier --write {file}"
}
```

- **Keep in mind:** the commit gate runs from the repo root.
- **Keep in mind:** it times out after `commit_gate_timeout` seconds.
- **Keep in mind:** a blank `format_command` detects gofmt, prettier with a config, ruff and more.
- **Skills:** none.
- **Hooks:** run before each Bash command and after each edit.
- **Scenarios:** [guarded-commits](../examples/guarded-commits/story.md) and
  [edit-time-checks](../examples/edit-time-checks/story.md).

## learn

`/learn:extract-taste` turns how you work with Claude Code into an abstracted profile. It opens a
pull request with it only after you confirm the push. Its scrubber blocks credential shapes, not
names or other personal details, so read the profile before you confirm.

Use it when you want to share how you work with an agent, so the team can fold it into shared
rules.

```text
/learn:extract-taste
/learn:extract-taste --confirm-push
```

- **Keep in mind:** the first run shows the profile and pushes nothing.
- **Keep in mind:** it reads your Claude Code data only.
- **Skills:** [`extract-taste`](../plugins/learn/skills/extract-taste/SKILL.md).
- **Hooks:** none.
- **Scenario:** none, since it needs a live model. Start with `/learn:extract-taste`.

## starter

`/starter:setup` writes the repo files a plugin cannot install. They are the kit's settings in
`.agentic-workflow-kit.json`, a deny list in `.claude/settings.json`, the agent rules in
`.claude/rules/` and the githooks. `/starter:guide` maps situations to
skills.

Use it once per repo, right after installing the plugins. [install.md](install.md#set-up-your-repo)
shows what it writes.

- **Skills:** [`setup`](../plugins/starter/skills/setup/SKILL.md),
  [`guide`](../plugins/starter/skills/guide/SKILL.md).
- **Hooks:** load the skill guide at session start.
- **Scenario:** [guarded-commits](../examples/guarded-commits/story.md) uses its
  `.agentic-workflow-kit.json`.

## all

Every plugin above in one install. A bundle cannot be partly switched off later, so to leave a
plugin out, install the plugins one by one, as [install.md](install.md#only-some-plugins) shows.
