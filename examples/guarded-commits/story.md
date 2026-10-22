---
id: guarded-commits
title: An agent cannot commit past a failing test, a stale lockfile or an unpinned npx
plugins: [guards, starter]
tags: [hooks, commit-gate, lockfile, npx]
---

# Guarded commits

## When to use it

You let an agent commit on its own and want a few deterministic lines it cannot cross: the tests
pass before a commit, a lockfile matches its package.json, and `npx -y` fetches only a pinned
version.

## The scenario

The agent changes a function, a test now fails, and it tries to commit anyway. Later it adds a
dependency to `package.json` without updating `package-lock.json`, and runs `npx -y` on an
unpinned package.

## Run it

1. Once: set the `commit_gate` setting to the command that must pass, for example with
   `/starter:setup` (`--set commit_gate='make test'`), which writes `.agentic-workflow-kit.json`.
2. Work as usual. Before any agent `git commit` (also `git -C <dir> commit`), the guards plugin
   runs the gate in the repo the commit lands in, and blocks the commit when it fails, showing
   the tail of its output. The agent fixes the failure and commits again.
3. The lockfile gate regenerates the nearest lockfile without installing and blocks a commit that
   leaves it out of sync. The refreshed lockfile is left for the agent to stage.
4. The npx guard blocks `npx -y <package>`, or a plain `npx <package>` that is not a local bin,
   without an exact version.

## What to expect

- A blocked commit says which command failed and why, and nothing is committed.
- A blank `commit_gate` turns that gate off. A missing package manager is a note, not a block.
- `echo "git commit"` and `git log --grep commit` are not commits and run no gate.

## If it goes wrong

- The gate runs in the wrong checkout: it follows a leading `cd <dir>` and `git -C <dir>`. Other
  forms fall back to the tool's working directory.
- No jq on the machine: the deny gates block a commit with a reason rather than let it through.

`checks.sh` replays the three guards with recorded payloads, a stub `npm` and no network.
