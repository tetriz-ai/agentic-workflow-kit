---
id: usage-paced-queue
title: A queue pauses before the usage limit, not at it
plugins: [queue]
tags: [ship-queue, usage-pacing, statusline, worktrees]
---

# A usage-paced queue

## When to use it

You leave `/queue:ship-queue` draining a label on a subscription with a 5-hour usage window.
You want the run to stop at a clean point between issues while it still has the budget to
schedule its own resume, rather than hit the limit mid-fix. Usage pacing is experimental, so
bound the run with `--limit N` and run it attended rather than rely on it overnight.

## The scenario

The queue works each issue in its own worktree. Claude Code hands the 5-hour usage figure only
to the statusline command, so the queue cannot see it unless a statusline writes it down. The
operator already has a personal statusline and does not want to lose it.

## Run it

1. Once, as the operator: set your own `statusLine` command to the queue plugin's
   `scripts/statusline-capture.sh`. It is opt-in, and the plugin never wires it for you. It writes
   `.claude/triage/usage.json` in the main checkout, then runs the `statusLine` from your
   `~/.claude/settings.json` (or prints the session's branch and 5h percentage when you have
   none).
2. Start `/queue:ship-queue`. Between issues it runs `scripts/usage-guard.sh should-pause`.
3. Below 85% it starts the next issue. At 85% or more it sets a one-off resume for the reset
   time from `usage-guard.sh resets-at`, and ends the turn.

## What to expect

- Your statusline looks the same as before.
- A capture made in any worktree lands in the main checkout, where every worktree reads it.
- No signal, or one older than three minutes, never pauses the run. Several such answers in a
  row make the queue tell the operator that pacing is blind.
- `should-pause <threshold>` overrides the 85% default for one call.

## If it goes wrong

- The run never pauses: check `.claude/triage/usage.json` in the main checkout updates while a
  session is open. Without it, `should-pause` keeps saying `ok no-signal`. Bound such a run with
  `--limit N`.
- Your personal statusLine points at the wrapper itself: it renders the fallback line once,
  with the session's own branch (`issue-12` in a worktree), rather than calling itself again.

`checks.sh` replays the wrapper with recorded statusline payloads from a worktree, then asks the
guard, with no model.
