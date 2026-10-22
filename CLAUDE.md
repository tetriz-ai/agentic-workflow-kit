# agentic-workflow-kit

## What this is

A marketplace of Claude Code plugins (also packaged for Codex): skills for reviewing, shipping,
planning and queueing work, and hooks that nudge or block around an agent's commands and edits.
It does not merge into the base branch on its own: `/ship:pr` merges only when the user asks
and the merge gate passes, and the deny list `/starter:setup` writes blocks an agent's merges
and pushes to the base branch. No hook calls a model.

The public API is the plugins' skills, their hook scripts, the settings keys, and the
`setup.sh` commands (`plan`, `apply`); a change to any of them is a breaking change.

## Layout

- `plugins/<name>/`: one plugin each, with `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`,
  `skills/<skill>/SKILL.md`, `hooks/hooks.json` and `scripts/`. `plugins/all` only depends on the rest.
- `shared/`: `kit-config.sh` (the settings resolver), `cwd-resolve.sh`, `hook-once.sh` (one
  run per event when the Codex plugins and the bridge both fire) and `path-contained.sh` (no
  write through a symlink that leaves the repo), copied into plugins and the bridge.
- `bridge/`: the Codex repo-local harness (`agent-harness/`, `codex/`).
- `examples/<name>/`: `story.md`, `setup.sh <dir>`, `checks.sh <dir>`.
- `scripts/`: the checks CI runs. `docs/settings.md`: every setting.
- Tests sit beside the script they test, as `<script>.test.sh`.

## Commands

Run every script with bash, not zsh: `bash scripts/<name>.sh`, or the path itself, which uses
the `#!/usr/bin/env bash` line. CI needs bash 3.2 or later, git, jq, mikefarah's yq 4.53.6,
python3, shellcheck 0.11.0, Claude Code 2.1.289 and the Codex CLI 0.159.0.

The tests, under the environment CI gives them (its git identity, no system git config, a
temporary HOME):

```sh
export GIT_AUTHOR_NAME=ci GIT_AUTHOR_EMAIL=ci@example.com GIT_COMMITTER_NAME=ci GIT_COMMITTER_EMAIL=ci@example.com GIT_CONFIG_NOSYSTEM=1
export RUNNER_TEMP="$(mktemp -d)"
export HOME="$RUNNER_TEMP/home" && mkdir -p "$HOME"
scripts/test-all.sh
scripts/check-test-leaks.sh
scripts/run-examples.sh
```

Lint and doc checks:

```sh
{ find plugins bridge shared scripts examples -type f -name '*.sh'; find plugins/starter/files/githooks -type f; } \
  | sort | xargs shellcheck -x -S warning
scripts/check-docs.sh
scripts/sync-shared.sh --check
scripts/check-identifiers.sh
```

The marketplace and every plugin:

```sh
claude plugin validate --strict .
for p in plugins/*/; do claude plugin validate --strict "$p"; done
scripts/check-codex-plugins.sh
```

## Contract to keep

- A deny hook blocks with exit 2 and a reason on stderr. The commit gates also block when `jq` is
  missing (`plugins/guards/scripts/commit-gate.test.sh`, `lockfile-gate.test.sh`).
- The commit classifier counts `git -C <dir> commit` and ignores `echo "git commit"`
  (`commit-gate.test.sh`; the cadence suite `plugins/review/scripts/review-cadence.test.sh` case 27).
- A lens prints one leading `<ENGINE>-LENS: FINDINGS|SKIPPED|FAILED` token and exits 0. SKIPPED is
  for a missing CLI, a missing key or gateway, or an empty range; output that does not match the
  schema is FAILED (`codex-lens.test.sh`, `claude-lens.test.sh`, `ocr-lens.test.sh`).
- The lockfile gate never loses an unstaged lockfile edit (`lockfile-gate.test.sh`).
- `setup.sh`, the bridge sync and worktree hydration never write through a symlink that leads out
  of the repo or worktree (`setup.test.sh`, `sync-harness.test.sh`, `worktree-hydrate.test.sh`).
- `setup.sh plan` writes nothing, and `setup.sh apply` merges settings, the deny list and
  `.gitignore`, keeps a differing file and is idempotent (`plugins/starter/scripts/setup.test.sh`).
- The extract-taste scrubber blocks every credential class it lists
  (`plugins/learn/skills/extract-taste/scrub.test.sh`).

## Making a change

- A behaviour change needs a test that fails before it and passes after. Tests are tables: add a
  row. A changed setting, skill name or hook message also needs a `CHANGELOG.md` entry.
- Edit `shared/*.sh`, then run `scripts/sync-shared.sh` to copy it into the plugins.
- A new setting goes in the plugin's `userConfig`, `plugins/starter/files/settings.json` and
  `docs/settings.md`; `scripts/check-docs.sh` fails until all three agree.
- An example is a folder under `examples/` with the three files, listed in `examples/README.md`.
  `story.md` opens with front matter (`id`, `title`, `plugins`, `tags`) and has five sections:
  When to use it, The scenario, Run it, What to expect, If it goes wrong
  (`examples/guarded-commits/` is a template). `checks.sh` finds the kit as
  `$(dirname "$0")/../..`, replays hooks with no model, and prints `passed=N failed=M` last.
  Then run `scripts/run-examples.sh` and paste its whole output, the count line included, into
  the text block after `scripts/run-examples.sh` in the root `README.md` (under Common tasks);
  `scripts/check-docs.sh` fails when the two differ.
- A hook reads one JSON object on stdin: `{"tool_input":{"command":"..."},"cwd":"..."}` for a Bash
  hook, `{"tool_input":{"file_path":"..."}}` for an edit hook. Build it with `jq -nc`, never by
  hand-quoting.
- Every script outside `examples/` starts with a copyright line and an SPDX line:
  `# Copyright 2026 The agentic-workflow-kit Authors` and `# SPDX-License-Identifier: MIT`.
  `scripts/check-docs.sh` checks them.
- A suite that lacks a tool it needs prints a line starting `SKIP:` and exits 0.
  `scripts/test-all.sh` counts the skipped suites in its summary, and with `CI` set a skip fails
  the run (`scripts/test-all.test.sh`).
- `scripts/test-all.sh` takes about 7 to 16 minutes, depending on the machine.
  `scripts/check-test-leaks.sh` runs every suite again, which adds about 4 minutes. Run one suite
  with `bash <path>.test.sh` while working.
- shellcheck runs at warning level with `.shellcheckrc`; fix a warning, do not silence it inline.

## Do not

- Do not put a comment above a SKILL.md's frontmatter: it must start on line 1.
- Name a kit skill as `/<plugin>:<skill>`, never bare: `scripts/check-docs.sh` fails on a bare
  `/<skill>` that names a shipped skill (`scripts/check-skill-refs.sh`).
- Fake tokens in `scrub.test.sh` and `push.test.sh` carry `gitleaks:allow`; keep them fake.
- macOS `mktemp` here ignores `TMPDIR`: root a test's temp files in one trapped directory.
- Do not let a test reach `pbcopy`, the network or a real `gh`: stub them on `PATH`.
