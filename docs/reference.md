# Reference

This page covers what reaches outside the chat, what each part needs, and the compatibility
promise. [plugins.md](plugins.md) lists each plugin's skills and hooks.
[settings.md](settings.md) lists every setting.

## Skills with side effects

These skills act outside the chat. The second column says where the agent may start one on its
own when your request matches.

| Skill | Starts unasked on | What it does outside the chat |
|---|---|---|
| `pr` | Claude Code | opens or updates a pull request, announces it to `announce_channel` when configured (reviewer lookup uses git-log names and emails), and merges one only when you ask and no deny list blocks it |
| `codex-sweep` | Claude Code | pushes fixes and replies on review threads |
| `github-issues`, `bug-hunt` | Claude Code | file issues |
| `ship-task`, `ship-queue` | Claude Code | push branches and open pull requests |
| `extract-taste` | Claude Code | opens a pull request with your profile |
| `adr` | Claude Code and Codex | files an issue and writes an ADR file |
| `tech-design-doc-writing`, `task-breakdown` | Claude Code and Codex | write design doc files |
| `ocr-lens` | Claude Code and Codex | writes the gateway's request body into `~/.opencodereview/config.json` |
| `harness-education` | neither | opens a pull request with the rules and edits you picked |
| `setup` | neither | writes the repo files it lists |

Where a skill does not start unasked, call it by name, for example `/ship:pr`, or `$pr` on Codex.

## What each part needs and calls

Beyond git, jq and bash:

| Also needs | For |
|---|---|
| `gh`, logged in | anything that talks to GitHub |
| the `codex` or `claude` CLI | the cross-model lenses |
| `node`, the `ocr` CLI and a gateway key | `/review:ocr-lens` |
| the Go implementation of `yq`, `python3` and a clone of the kit | the bridge |
| the hosted Codex reviewer installed on your GitHub repository | `/ship:codex-sweep` |
| a chat connector that can post to the channel | `/ship:pr` announcements, when `announce_channel` is set |

A missing CLI, gateway or key turns a review lens into a stated SKIPPED, never a silent pass. A
skill script that needs `gh` stops with a message.

The lockfile gate runs npm, pnpm or yarn against the package registry during commits.

No hook calls a model. Three hooks call `gh` to ask GitHub about this repo:

- the description drift reminder
- the review cadence on a push
- the queue snapshot at session start

## Versioning and compatibility

The kit follows semantic versioning. Renaming a skill, a plugin or a setting, changing a
setting's default, or changing a hook's exit status or message is a breaking change.

CI validates the plugins with Claude Code 2.1.289 and 2.1.300, and with the Codex CLI 0.159.0
and 0.162.1. The scripts' tests run on bash 3.2 on macOS and bash 5.2 on Linux.
