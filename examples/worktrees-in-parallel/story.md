---
id: worktrees-in-parallel
title: Parallel agents in worktrees without stepping on each other
plugins: [worktrees, starter]
tags: [worktrees, subagents, parallel]
---

# Parallel agents in worktrees

## When to use it

Two or more agents work on separate changes at once. Each needs its own checkout, and each needs
the local files the app needs to run (`.env`, a local config) that git does not track.

## The scenario

The main checkout has an untracked `.env` and `config/local.yml`. You start two agents, each in a
new worktree (`git worktree add`, or Claude Code's EnterWorktree). Without help, both worktrees
start with neither file and the app will not boot. And a subagent dispatched from a worktree
session might resolve paths against the main checkout instead.

## Run it

1. Once per repo: `/starter:setup` writes `.worktreeinclude` (which local files a worktree needs)
   and the `post-checkout` githook.
2. Each agent creates its worktree. The githook (for `git worktree add`) or the worktrees
   plugin's EnterWorktree hook copies the listed files into it.
3. When an agent in a worktree dispatches a subagent, the worktrees plugin's anchor hook adds a
   preamble to the subagent's prompt naming the worktree root, so it works there.
4. Each agent ships from its own branch (`/ship:pr`). The always-on rule
   `parallel-agent-worktrees` keeps one build per tree and forbids tree-wide discards.

## What to expect

- Every new worktree has the listed files, and an edit in one worktree does not touch the others.
- A `required` file missing from the main checkout is reported, not silently skipped.
- A subagent started from the main checkout gets no preamble.

## If it goes wrong

- Files not copied after `git worktree add`: check `git config core.hooksPath` points at
  `.githooks`, or call `.githooks/post-checkout` from the hooks your repo already uses.
- A path in `.worktreeinclude` outside the repo (`../x`, `~/x`) is refused on purpose.

`checks.sh` replays the githook and the anchor hook on a fixture repo, with no model.
