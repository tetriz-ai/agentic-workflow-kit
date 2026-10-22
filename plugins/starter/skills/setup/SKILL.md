---
name: setup
description: >-
  Sets up a repository for the agentic-workflow-kit plugins. It writes the repo settings file
  .agentic-workflow-kit.json, which is the settings channel Codex reads, the permission deny list,
  the always-on rules, the rule index and its CI check, githooks, .gitignore entries and a
  .worktreeinclude example. It shows the plan and asks before writing anything. Use when the user
  says set up the kit or onboard this repo, or after installing the plugins.
disable-model-invocation: true
user-invocable: true
argument-hint: "[part...]"
---

# setup: prepare this repo for the kit

A plugin cannot write files into a repo when it is installed, so this skill does, on the user's
explicit yes (step 3). The
engine is `setup.sh` in this plugin's `scripts/` folder (`${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh`;
on a runtime that does not fill in `${CLAUDE_PLUGIN_ROOT}`, the `scripts` folder two levels above
this file). Run it from the repo root.

## 1. Show the plan

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" plan
```

Show the user the parts and what each writes:

| Part | Writes | Why |
|---|---|---|
| `config` | `.agentic-workflow-kit.json` | the settings every plugin reads; the only channel Codex has |
| `deny` | `.claude/settings.json` `permissions.deny` (merged) | blocks pipe-to-shell installs, merges, and pushes to the base branch |
| `rules` | `.claude/rules/*.md` | the always-on working principles the skills assume |
| `rule-index` | `.claude/rules/rule-index.md`, `scripts/check-rule-index.sh` | the map of which rule is enforced how, and its CI guard |
| `githooks` | `.githooks/post-checkout`, `.githooks/pre-push` | worktree hydration on `git worktree add`; the PR-description drift reminder on push |
| `gitignore` | `.gitignore` (lines appended) | keeps the kit's local state out of git |
| `worktreeinclude` | `.worktreeinclude` | the list of local files a new worktree needs |

## 2. Ask for the settings that matter

Ask only for the values this repo needs, with the default shown (the full list and defaults are in
the kit's `docs/settings.md`; `files/settings.json` in this plugin is the same list):

- `base_branch` (default `main`), `repo_slug` (default: from the git remote);
- `merge_gate`: a command or label that must pass before a PR is merge-ready (blank: the
  required GitHub checks);
- `commit_gate`: a command to run before an agent commits, for example the test suite (blank: none);
- `announce_channel`, `github_project`, `queue_label`, `team_rules_file`: only if the user uses
  those plugins.

Never guess a value. Leave a setting out when the user has no answer: its default applies.

## 3. Stop for the user's answer

Writing files into the repo needs the user's yes, given in this session after they have seen the
plan: which parts, and the setting values. Invoking `/starter:setup` is not that yes. End your turn
after steps 1 and 2 and wait. In a session with no one to answer (a headless or scheduled run),
stop here: report the plan and the command the user would run, and write nothing.

## 4. Apply what the user picked

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" apply config deny rules rule-index githooks gitignore worktreeinclude \
  --set base_branch=main --set commit_gate='make test'
```

Settings, the deny list and `.gitignore` are merged, never replaced. A file the repo already has
with different content is kept and reported (exit 1); replace it only if the user asks
(`--force`). Applying twice changes nothing.

## 5. Hand over

Tell the user, in this order:

1. what was written (the `write` and `merge` lines) and what was kept;
2. to commit the written files on a branch;
3. on Codex: trust the plugin hooks once with `/hooks`, since Codex runs them only after that;
4. the next command: `/review:review-panel` after the first commits, or `/ship:pr` to open a PR.
   The `starter:guide` skill maps other situations to the right skill.
