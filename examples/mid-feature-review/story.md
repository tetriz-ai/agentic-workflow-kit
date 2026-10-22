---
id: mid-feature-review
title: A review panel is nudged mid-feature
plugins: [review]
tags: [review-panel, review-cadence]
---

# A review panel fires mid-feature

## When to use it

You are a few commits into a change and nobody has looked at it yet. You want a review while the
context is fresh, not one big review at the end.

## The scenario

You are adding a pagination helper. Five commits in, the last page is computed with an
off-by-one error. You have not noticed, because the tests you wrote never ask for the last
page.

## Run it

1. Keep working and commit as usual. On the fifth commit since the last panel run, the review
   plugin's cadence hook adds a note to the agent's context: `[review-cadence] 5 commit(s) ...
   run the soft reviewer panel`.
2. The agent runs `/review:review-panel` (cadence mode). The panel picks the lenses that fit the
   diff (here the code-quality lenses and the runtime-attack lens), and grades findings
   Critical, Important or Minor.
3. Fix what is Critical or Important, then carry on. The panel resets the cadence when it runs.
4. Before opening the pull request, `/review:review-panel pre-pr` runs once more over the whole
   branch, then `/ship:pr` opens it.

## What to expect

- The nudge appears once per crossing: commit six does not repeat it.
- After the panel runs, the next commit is quiet until the threshold is crossed again.
- `gh pr create` with unreviewed commits gets its own pre-PR nudge.
- The thresholds are the `review_cadence_commits` (default 5) and `review_cadence_lines`
  (default 200) settings.

## If it goes wrong

- No nudge at all: check the review plugin is enabled (`/plugin`), and that the commits are on a
  branch the hook can see (it follows `git -C <dir>` and a leading `cd <dir>`).
- A nudge on every commit: the panel did not reset the cadence. Run
  `"${CLAUDE_PLUGIN_ROOT}/scripts/review-cadence.sh" reset` from the repo, or let the panel run.

`checks.sh` replays the hook part of this story with no model: it feeds recorded hook payloads to
the cadence hook and asserts on its replies.
