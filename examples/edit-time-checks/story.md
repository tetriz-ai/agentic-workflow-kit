---
id: edit-time-checks
title: Every agent edit is formatted the repo's way, and a risky edit is flagged at once
plugins: [guards]
tags: [hooks, format-on-edit, generated-files, doc-health, codex]
---

# Edit-time checks

## When to use it

An agent edits many files in one session. You want each edit formatted the way your CI expects,
and you want to hear right away when an edit lands in a generated file or leaves a skill or
`CLAUDE.md` broken, rather than at review.

## The scenario

The repo formats with its own script, named in the `format_command` setting. The agent tidies a
Go file, then patches a generated API client, writes a skill without a description, and points
`CLAUDE.md` at a `/deploy-staging` skill that does not exist. The same session also runs on
Codex, where the kit's Codex plugin and the bridge both deliver each edit.

## Run it

1. Once: set `format_command` to your formatter with `{file}` for the path, for example with
   `/starter:setup` (`--set format_command='make fmt FILE={file}'`). Blank detects gofmt or
   golangci-lint, prettier with a config, ruff or black, and rustfmt.
2. Work as usual. After every Edit, Write or MultiEdit, the guards plugin runs the formatter on
   that file from the repo root, then checks it and adds any warning to the agent's context.

## What to expect

- The formatter runs silently, and its failure (say, a half-written file) never blocks the edit.
- An edit to a file whose header says it is generated warns and names the generator.
- A `SKILL.md` without `description:`, or a `CLAUDE.md` naming a skill the repo does not have,
  is flagged. The kit's own skills, such as `/review-panel`, are not.
- On Codex, one edit delivered twice is formatted and checked once.

## If it goes wrong

- Nothing is formatted: the edited file must sit in a git repo. `format_command` is read from
  `.agentic-workflow-kit.json` at the root of that repo, wherever the session runs, and an
  environment value (`AGENTIC_KIT_FORMAT_COMMAND`) wins over it.
- A path with spaces or shell syntax breaks the formatter: write `{file}` bare, not quoted. The
  hook passes the path as one argument.

`checks.sh` replays both hooks through `hook-once.sh` with recorded Edit payloads, a stub
formatter and no model.
