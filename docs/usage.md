# Usage

The plugins chain into one loop, from a design to a reviewed pull request. [plugins.md](plugins.md)
covers each plugin on its own.

## The loop

1. **Plan.** Draft the design with the plan skills, then cut it into slices.
2. **Build.** Commit as usual. Every five commits or 200 changed lines, a hook nudges `/review:review-panel`. Fix Critical and Important findings.
3. **Open the PR.** `/review:review-panel pre-pr` reviews the whole branch, then `/ship:pr` opens the pull request.
4. **Answer the review.** `/ship:codex-sweep` fixes clear-cut Codex findings and replies. `/ship:pr-feedback` gathers everything else.
5. **Scale out.** Drain a labelled queue through the same steps with `/queue:ship-queue`. Turn
   repeated review comments into rules with `/review:harness-education`.

When the hosted Codex reviewer is installed on the repository, `/ship:pr` also starts a background
wait. It wakes the agent to run `/ship:codex-sweep` once Codex posts its review. After a push, the
drift hook reminds you to refresh the description.

## The review loop

```mermaid
flowchart LR
  commit[commit] --> cadence{"cadence hook:<br>threshold reached?"}
  cadence -- no --> commit
  cadence -- yes --> panel["/review:review-panel:<br>one subagent per lens, findings graded"]
  panel --> fix["fix Critical and Important,<br>and the panel resets the cadence"] --> commit
```

The thresholds are the `review_cadence_commits` and `review_cadence_lines` settings.

## The pull request flow

```mermaid
flowchart LR
  pre["/review:review-panel pre-pr"] --> pr["/ship:pr"] --> open[PR open]
  open --> sweep["/ship:codex-sweep: fix and reply"]
  open --> push[push] --> drift{"description older<br>than the newest commit?"}
  drift -- yes --> refresh[refresh the description]
  drift -- no --> quiet[no reminder]
  open --> human[human review and merge]
```

## A queue drain

```mermaid
flowchart TD
  label[issues with the queue label] --> ground[a subagent reads the issue and the code it touches] --> build[fix in a worktree]
  build --> panel[review panel] --> pr[open the PR] --> gate[merge gate] --> sweep[Codex sweep] --> next{another issue?}
  build -. needs a decision .-> blocked[marker comment, ask the author, move on]
  next -- yes --> ground
  next -- queue empty --> done[done]
```

A pull request is merge-ready when your `merge_gate` command passes. With no `merge_gate`, your
required GitHub checks decide.
