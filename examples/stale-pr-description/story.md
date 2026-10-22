---
id: stale-pr-description
title: A PR description goes stale after a push
plugins: [ship]
tags: [pr, pr-description, hooks]
---

# A PR description goes stale after a push

## When to use it

A pull request is open, and you keep pushing fixes from review. The description still says what
the first version did.

## The scenario

You opened PR #127 with `/ship:pr`. A reviewer asked for a change to the retry policy, and you made it
and pushed. The description still says "retries three times", the code now retries five.

## Run it

1. Push as usual. After `git push`, the ship plugin's drift hook compares the PR description's
   last edit with the newest commit and adds a passive reminder to the agent's context.
2. At a checkpoint (not on every push), the agent refreshes the description with `/ship:pr`'s
   "Reconcile an existing PR" step: it reads the current body and rewrites it for the whole diff.
3. A human pushing outside an agent gets the same reminder from the starter's `pre-push`
   githook, on stderr. It never blocks the push.

## What to expect

- One reminder per stale description: a second push with the same description is quiet.
- A `--dry-run` push, a push from the base branch, or a branch with no open PR is quiet.
- After the description is edited, the next push that leaves it behind reminds again.

## If it goes wrong

- No reminder: `gh` must be installed and logged in. The hook is silent when it cannot ask
  GitHub, by design.
- A reminder right after editing the description: commits within `PR_DRIFT_GRACE_SECONDS`
  (default 60) of the edit are not drift.

`checks.sh` replays this with a stub `gh` and no network.
