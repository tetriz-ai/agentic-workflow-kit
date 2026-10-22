# Agent harness bridge

The bridge lets Codex work from the same harness as Claude Code. The Claude harness
(`CLAUDE.md`, `.claude/rules`, `.claude/skills`, and the agentic-workflow-kit plugins) stays the
single source; each other agent gets a thin adapter, never a copy.

## Install or refresh

From the root of your repo, run the sync script from a clone of the kit. It needs git, jq,
mikefarah's yq and python3.

```bash
/path/to/agentic-workflow-kit/bridge/agent-harness/sync-codex-harness.sh
```

It copies the adapters and this folder into the repo, links what it can, then runs the full
validator. A file you have edited is kept; `--force` replaces it with the kit's copy. Run the
installed `.agent-harness/sync-codex-harness.sh` later to re-check without a kit clone.

| What lands in the repo | For |
|---|---|
| `.codex/` | Codex hook adapters, `hooks.json`, execpolicy rules, `config.toml` |
| `.agent-harness/` | `rules-for-paths.sh`, the validators, budgets and helpers in this folder |
| `AGENTS.md` | When `CLAUDE.md` exists, a symlink to it, so Codex reads the same root guidance |
| `.agents/skills` | When `.claude/skills` exists, a symlink to it, for the repo's own skills |

The sync prints a note for each link it skips.

The hook adapters call the kit's plugin scripts. They find them through `AGENTIC_KIT_HOME` (a
clone of the kit) when that is set, otherwise in the newest installed copy of each plugin in the
Claude Code plugin cache. They do not look in Codex's own plugin cache, so on a machine with
only Codex, set `AGENTIC_KIT_HOME`. With neither, the adapters skip those hooks and the deny
matrix in the pre-command hooks still applies.

## Surface map

| Claude Code source | Codex |
|---|---|
| Root and area `CLAUDE.md` | `AGENTS.md` symlink plus `project_doc_fallback_filenames` in `.codex/config.toml` |
| `.claude/rules/*.md` | `.agent-harness/rules-for-paths.sh`, read live |
| `.claude/skills/*` | `.agents/skills` symlink; `agents/openai.yaml` keeps a user-only skill user-only |
| Plugin hooks | `.codex/hooks.json` and wrappers that call the plugin scripts |
| Permission deny list | `.codex/rules/default.rules` plus the pre-command hook's deny matrix |

The always-loaded `codex-compatibility` rule (from `/starter:setup`) translates Claude terms in
shared skills (subagents, background tasks, worktrees, questions, tool names) to their Codex
equivalents.

## Checks

```bash
.agent-harness/validate-codex-harness.sh --quick   # structure only; the Codex SessionStart hook runs it
.agent-harness/validate-codex-harness.sh --full    # also hook behaviour and execpolicy rules
.agent-harness/validate-context-budgets.sh         # root guidance, always-loaded rules, skill descriptions
```

`validate-context-budgets.sh` warns at 80% and 90% of each budget and fails at the cap. When the
repo commits a reviewed `.agent-harness/context-budget-baseline.json`, it also warns on growth past
25% of that baseline.

## Trust the project layer

Codex loads a repo's `.codex` folder only after the repo is trusted in your own Codex config.
`.agent-harness/print-codex-trust-config.sh` prints the stanza for this checkout; add it to your
Codex config, start a new session, and review the project hooks with `/hooks`.

## Limits

- With both the bridge's Codex hooks and the kit's Codex plugins installed, Codex fires both for
  the same event. Each side claims the event through the plugin's `scripts/hook-once.sh` before
  running a kit script, so each script runs once. A payload with no session and call id cannot be
  claimed, and then the script runs twice, never zero times. Test:
  `codex-hooks-once.test.sh`. The bridge's own deny matrix is not in the plugins, so it runs once
  anyway.
- A non-interactive `codex exec` run does not run project hooks. The validators exercise the
  wrappers directly instead.
