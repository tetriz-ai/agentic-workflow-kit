---
# No paths: Codex reads the same skills and agents as Claude Code, so these
# translations apply whenever shared harness guidance is in use.
---

# Codex translations for the shared harness

When the active runtime is Codex, preserve the intent of Claude-specific terms instead of treating their exact names as missing capabilities:

- A `/skill-name` reference or an instruction to use the Skill tool means load and follow that project skill from `.agents/skills/` (the Codex view of `.claude/skills/`). `$ARGUMENTS` means the text supplied after the skill name. Keep user-only skills user-only according to their `agents/openai.yaml` policy.
- `Agent` / `Task`, `general-purpose`, and "fresh subagent" mean a Codex subagent with a bounded prompt and only the context the shared workflow permits. `Explore` means the built-in read-heavy explorer; a named project agent means its matching `.codex/agents/*.toml` adapter. Claude model labels such as Haiku/Sonnet/Opus express speed-versus-judgment intent; use the closest available Codex agent/model without weakening the requested independence or review rigor. Parallelize only independent work, respect the runtime thread cap, wait for every required result, and use the skill's direct fallback when running as a leaf that cannot spawn.
- `run_in_background: true` means a Codex background terminal, not a relay subagent. Claude's `/tasks` maps to the runtime's background-process controls (`/ps` in the Codex CLI); poll or resume there and read the compact digest the skill names. Never orphan a long-running command just because the initiating turn ends.
- Claude's `EnterWorktree` means use the Codex worktree environment or create the named Git worktree the workflow specifies. For a manually created worktree, run the worktrees plugin's `worktree-hydrate.sh` exactly where the owning skill requires it: it copies the files `.worktreeinclude` lists (its `required`/`optional` lines are read only by that script), and the Codex `SubagentStart` hook keeps the active-worktree anchor.
- `AskUserQuestion` means Codex's structured input UI when available, otherwise a concise question in chat. Preserve explicit pause/gating requirements. `/goal` means the runtime goal mechanism when available; otherwise use the skill's stated persistence fallback.
- Claude `ToolSearch` means Codex's lazy tool discovery. Claude-qualified MCP names describe capabilities, not a requirement to find that literal tool name. Route Slack operations through the installed Slack connector/skill and Playwright/browser operations through the installed browser capability, preserving the original read/write authorization and "skip if unavailable" behavior. Treat `claude mcp add/list` commands as Claude-only environment setup; in Codex, use the supported plugin/connector manager for the same capability instead of running those commands.
- Claude `Monitor` / `PushNotification` references map to Codex's recurring monitor and native notification mechanisms when available; otherwise use the fallback the owning skill specifies.
- For unattended local agent commands, `claude -p` maps to `codex exec`; invoke project skills as `$skill-name`, choose the least-privileged sandbox that can complete the job, and rely on an external wall-clock bound because a non-interactive run cannot answer a new approval prompt.

For repository commands, resolve the checkout with `git rev-parse --show-toplevel`; do not assume `CLAUDE_PROJECT_DIR` exists outside hook processes.

Codex does not consume Claude's `.claude/agent-memory/` store. Treat it as generated local state, never as the only home for a team convention; promote durable learning into the canonical agent, skill, rule, or area `CLAUDE.md`.
