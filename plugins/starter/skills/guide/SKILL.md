---
name: guide
description: "Maps a situation to the agentic-workflow-kit skill that handles it: designing, reviewing mid-feature, opening a PR, answering review comments, shipping an issue or a queue, hunting bugs, recording a decision, turning review lessons into rules. Use when unsure which kit skill fits, or when the user asks what the kit can do."
user-invocable: true
---

# agentic-workflow-kit: which skill when

Only the installed plugins' skills exist; skip a line whose plugin is not installed.

| Situation | Skill |
|---|---|
| A feature needs a design first | `/plan:tech-design-doc-writing`, then `/plan:tech-design-doc-review`, then `/plan:task-breakdown` |
| A few commits into a change (the review cadence hook nudges) | `/review:review-panel` |
| Ready to open a pull request | `/review:review-panel pre-pr`, then `/ship:pr` |
| A PR has review comments | `/ship:pr-feedback`; Codex threads: `/ship:codex-sweep` (armed by `/ship:pr`) |
| One issue to ship end to end | `/queue:ship-task <issue>` |
| A labelled queue of issues | `/queue:ship-queue --list`, then `/queue:ship-queue` |
| Find bugs worth filing | `/queue:bug-hunt` |
| File an issue | `/ship:github-issues` |
| A decision worth keeping | `/plan:adr` |
| The same review comment keeps coming back | `/review:harness-education` |
| Share how you work with the team | `/learn:extract-taste` |
| This repo is not set up for the kit | `/starter:setup` |

Hooks run on their own: review and self-check nudges, PR nudges, worktree hydration, and the
commit, lockfile and npx guards. A nudge is advisory unless it says a command was blocked.

On Codex, `${CLAUDE_PLUGIN_ROOT}` in a kit skill means that skill's plugin folder, two levels
above its `SKILL.md`; settings come from `.agentic-workflow-kit.json` at the repo root.
