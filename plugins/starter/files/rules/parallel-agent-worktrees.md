---
# No `paths:` scope on purpose: this constrains how work is HANDED to an agent, not what any
# file contains, so no glob could trigger it. Per .claude/rules/docs-conventions.md an
# unscoped rule loads every session — keep it short.
---

# Parallel agents: one tree, one consumer — and "completed" is not "finished"

A git worktree holds exactly one checked-out branch, so it admits **one build at a time**. Two
agents in the same tree do not collide loudly: the second finds the first's branch checked out and
its edits already applied, and both then produce confident work against a tree neither one owns.
A parallel fan-out therefore gives every build its own worktree, and no agent touches a sibling's.

**A delegated agent's git can wipe the delegator's uncommitted work — commit or isolate before
you hand off.** A subagent sharing your tree runs git against the *whole* tree, and the tree-wide
discard commands — `git restore <path>`, `git checkout -- .`, `git reset --hard`, `git stash`
(sweeps the whole worktree aside), and `git clean` (deletes untracked/ignored files) — remove
uncommitted work across their whole scope, not just the files that agent authored. So an agent you
spawned to "fix the tests" or "reset to a clean state" can silently erase the in-progress edits you have not committed, with no conflict and no
warning: `git restore <dir>` reverts every uncommitted edit under that folder, whoever made it. Two protections, use at least one before delegating any agent that will
build, test, or run git in a tree that holds your uncommitted work: **commit or checkpoint that work
first** (a WIP commit on the feature branch is cheap and recovers tracked edits from a later
`git restore`/`checkout`/`reset --hard` — though a commit does not shield untracked or ignored
files from `git clean`, so isolation is the stronger guard there), or
**give the agent its own tree** (`isolation: "worktree"`, or a named worktree it owns). And in the
agent's own prompt, forbid the tree-wide discard commands outright — a delegated agent fixes a
compile failure by *editing* the offending file, never by resetting the tree.

**A task that armed a background waiter has not released its tree.** `/ship:pr` ends the shipping turn
by arming `codex-sweep.sh await <PR>`; when Codex posts, that waiter wakes the task back up to act
on the review threads — in the same worktree, on the same branch. So the turn ending is not the
work ending. Before handing a worktree to the next build, establish that the finishing agent armed
no waiter, or let that round close first.

**One tree per search — never sweep across trees.** A recursive search stays inside the tree you
are working in (your worktree or the main checkout), never reaching an ancestor of the repo root, a
sibling checkout, or `.claude/worktrees/` (each worktree is a full copy of the repo). Prefer the Grep
tool — it honors `.gitignore` and still sees untracked files; `git grep` also skips the ignored trees
but searches tracked files only, so add `--untracked` when new/unstaged files must be covered. A raw
recursive walk that honors neither (`grep -r`, `find`, `rg -uu`, `fd -u`) is the trap: over a path
reaching another checkout or a dependency tree it reads every file there, and on a machine with an
on-access file scanner that starves builds. If one is unavoidable, keep its root inside the current tree and scope it
to a subtree free of `node_modules`/`.venv` — `--exclude-dir` only prunes named dirs, so it is extra
protection, not a substitute for an in-tree root. Reading a *named* sibling tree a task needs is fine;
do not sweep from an ancestor.

**Isolate per tree; key shared state per session; sequence the rest.** A fresh worktree carries no
`node_modules` and no `.venv` (the worktrees plugin's `worktree-hydrate.sh` deliberately skips them).
`/queue:ship-queue`'s `.claude/triage/` directory is the opposite — pinned to the main checkout so a
resume from any tree finds it — which is why its run-ledger is keyed by session and so never
collides. Files keyed by **issue** rather than session (the per-slice briefs, panel findings)
share that one directory across every concurrent run, and the queue itself has no lock, so
two drains of the same label will overwrite each other's working files and process the same issues
twice. Isolation protects the tree; only sequencing protects the work.
