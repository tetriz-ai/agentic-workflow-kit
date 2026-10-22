# Limitations

These limits matter once an agent works unattended on a repository you care about. The first
section lists the kit's non-goals. In the sections after it, a test pins each limit, except those
that come from Codex itself or from model judgment. The harmful direction comes first.

## What the kit does not do

- **Never merges into your base branch on its own.** `--integration-branch` merges onto that branch only.
- **Not a security boundary.** The guards miss a command hidden by an alias, a variable, `eval` or a wrapper.
- **Does not replace CI or branch protection.** Review findings never block. Your `merge_gate` or required checks do.
- **GitHub only.** The ship and queue skills call `gh`.

`/queue:ship-queue --integration-branch <name>` opens one pull request from that branch, and a
human merges it. Only the commit, lockfile and npx hooks block.

## The guard hooks

**Can let through:**

- **A command named through a variable.** `G=git; $G commit` and `X=npx; $X -y pkg` pass.
  Tests: `commit-gate.test.sh`, `block-unpinned-npx.test.sh`.
- **A Yarn 1 lockfile.** Yarn 1 has no lockfile-only install, so the gate skips it with a note.
  Test: `lockfile-gate.test.sh`.
- **A missing package manager.** The lockfile gate allows the commit with a warning, by design.
  Test: `lockfile-gate.test.sh`.

Yarn 2 and later are checked. A package manager that is installed and fails blocks the commit with
its output, because only a missing one leaves the gate unable to run the check.

**Blocks more than it should:**

- **A separator inside quotes.** `echo "done; git commit next"` counts as a commit, by design.
  Test: `commit-gate.test.sh`.
- **No jq.** Every commit, and every command naming npx, is blocked with a reason.
  Tests: `commit-gate.test.sh`, `lockfile-gate.test.sh`, `block-unpinned-npx.test.sh`.

Quotes are dropped before a command is split, which is why the quoted separator counts.

## The cross-model lenses

**Can miss:**

- **Uncommitted work.** The lenses review committed `BASE..HEAD`, and an empty range is SKIPPED.
  Tests: `codex-lens.test.sh`, `claude-lens.test.sh`, `ocr-lens.test.sh`.
- **Untracked files.** The Codex lens reviews a snapshot of the committed files.
  Test: `codex-lens.test.sh`.

Because each review covers a fixed range, it names a fixed commit. SKIPPED is never a clean pass.

**Reads more than it should:**

- **A file outside the repo, by its absolute path.** Codex's read-only sandbox allows it.
  `codex-lens.sh` states it.

This is how Codex's read-only sandbox works, so no test pins it.

**Changes more than it should:**

- **The ocr user config.** Each `/review:ocr-lens` run writes into `~/.opencodereview/config.json`.
  Test: `ocr-lens.test.sh`.

It writes the serving gateway's request body there, because `ocr` has no per-run option for it.
The skill says so before its first run.

## The review panel

**Can miss:**

- **What the models miss.** Findings are model judgments. Your tests and merge gate still block.

**Flags too much:**

- **A wrong finding.** A finding can be mistaken. You decide which findings to fix.

## Skills that act outside the chat

**Can act unasked:**

- **A matching request.** On Claude Code, the agent may push, open a pull request or file an issue.

[reference.md](reference.md#skills-with-side-effects) lists each such skill and the runtimes where
it can start unasked. This is how the runtime picks skills, so no test pins it.

**Waits for you more than it should:**

None known.

## The extract-taste scrubber

**Can let through:**

- **Names, ticket text and free-form PII.** It blocks credential shapes only. An email address passes with a warning.

A signature matcher cannot see the rest, so no test pins it. `scrub.sh` states the limit, and
`scrub.test.sh` pins the email case.

**Blocks more than it should:**

None known.
