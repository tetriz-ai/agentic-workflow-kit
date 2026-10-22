# Contributing

Thank you for helping. Please open an issue before starting on a new plugin, skill or hook, or
on a change to what a hook prints. That way we can agree on it before you write the code.

## Run the checks

These are the checks CI runs. They need bash 3.2 or later, git, jq, mikefarah's yq, python3
and shellcheck. CI pins shellcheck 0.11.0 and yq 4.53.6. The manifest checks need Claude Code
2.1.289 and the Codex CLI 0.159.0.

```sh
scripts/test-all.sh              # every *.test.sh
scripts/check-test-leaks.sh      # no test leaves temp files behind
scripts/run-examples.sh          # every examples/<name>/setup.sh, then checks.sh
scripts/check-docs.sh            # manifests, links, skill references, settings, hooks
scripts/sync-shared.sh --check   # the shared libraries match shared/
scripts/check-identifiers.sh     # no home paths, private hosts, monorepo paths or session links
claude plugin validate --strict .
scripts/check-codex-plugins.sh   # the Codex packaging loads, in a temporary CODEX_HOME
```

Run shellcheck the way CI does:

```sh
{ find plugins bridge shared scripts examples -type f -name '*.sh'; find plugins/starter/files/githooks -type f; } \
  | sort | xargs shellcheck -x -S warning
```

The tests stub `gh`, `codex`, `claude`, `ocr` and the package managers. They never need an
account, a key or network access.

A suite that lacks a tool it needs, such as jq, git, yq or codex, prints a line starting
`SKIP:` and exits 0. On your machine `scripts/test-all.sh` still passes and counts the skipped
suites in its last line. With the `CI` environment variable set, as GitHub Actions sets it, any
skip fails the run.

## Every change needs a test

A pull request without a test is not merged. A behaviour change needs a test that fails before
the change and passes after it. Tests are table-driven: add a row. A change to a setting, a
skill's name or a hook's message is a breaking change (see "Versioning and compatibility" in
[docs/reference.md](docs/reference.md#versioning-and-compatibility)). A behaviour change adds a line under `## [Unreleased]` in `CHANGELOG.md`.

`shared/kit-config.sh`, `shared/cwd-resolve.sh`, `shared/hook-once.sh` and
`shared/path-contained.sh` are copied into each plugin, or the bridge, that uses them,
because an installed plugin cannot reach a sibling. Edit the file in `shared/`, then run
`scripts/sync-shared.sh` to copy it.

## Commit style

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/): a short subject
such as `fix(guards): gate git -C <dir> commit in that repo`, a blank line, then a body that
says why.

## Licensing of contributions

No sign-off line and no separately signed agreement are needed. A pull request you open is
released on the terms in [LICENSE](LICENSE), like every other file here.
