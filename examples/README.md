# Examples

Each folder is one scenario. `story.md` says when to use it, what happens and what to expect.
`setup.sh <dir>` builds a fixture repo, and `checks.sh <dir>` replays the scenario's hook part
with no model and asserts on it. `scripts/run-examples.sh` runs them all, and CI runs it on every change.

| Scenario | Plugins | Shows |
|---|---|---|
| [mid-feature-review](mid-feature-review/story.md) | review | the cadence nudge mid-feature, once per crossing, and before a PR |
| [stale-pr-description](stale-pr-description/story.md) | ship | the reminder when a push leaves a PR description behind |
| [worktrees-in-parallel](worktrees-in-parallel/story.md) | worktrees, starter | local files copied into each new worktree, and subagents anchored to theirs |
| [guarded-commits](guarded-commits/story.md) | guards, starter | the commit gate, the lockfile gate and the npx pin |
| [domain-lenses](domain-lenses/story.md) | review, review-lenses | domain lenses chosen by the changed paths, and a team's own lens |
| [usage-paced-queue](usage-paced-queue/story.md) | queue | the 5h usage capture from a worktree, and the guard that pauses a queue before the limit |
| [edit-time-checks](edit-time-checks/story.md) | guards | the formatter run on each edit, the generated-file and doc-health advisories, and one run per edit on Codex |

The model's part of each scenario, such as the review findings or the rewritten PR description,
is not replayed here, because it needs a live model.
