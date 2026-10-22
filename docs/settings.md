# Settings

Every repo-specific value is a setting. Each plugin declares the settings it reads in its
`.claude-plugin/plugin.json` `userConfig`, with the default below. A setting takes the first
non-empty value in this order:

1. the value a skill passes for it
2. `CLAUDE_PLUGIN_OPTION_<KEY>`, which Claude Code exports to hooks from the plugin's options
3. `AGENTIC_KIT_<KEY>` in the environment
4. the key in `.agentic-workflow-kit.json` at the repo root;
5. the default.

`<KEY>` is the key in upper case. A shared key means the same thing in every plugin that reads it.

## Where to set a value

| Channel | Reaches | Scope |
|---|---|---|
| `.agentic-workflow-kit.json`, written by `/starter:setup` | hooks and skills, on Claude Code and Codex | the repo, committed for the team |
| `/plugin` options (`claude plugin install <plugin> --config key=value`) | hooks on Claude Code | you, in every repo |
| `AGENTIC_KIT_<KEY>` | hooks and skills | the shell that starts the agent |

Use the repo file for team settings other than `ocr_gateways`. OCR endpoints and credential
sources are user-controlled: set `CLAUDE_PLUGIN_OPTION_OCR_GATEWAYS`,
`AGENTIC_KIT_OCR_GATEWAYS` or `OCR_GATEWAYS_JSON` in your own environment. The resolver ignores
`ocr_gateways` in the repo file, so a reviewed change cannot redirect a reviewer's credentials.

Treat changes to `.agentic-workflow-kit.json` like changes to CI code. `commit_gate`,
`format_command`, `merge_gate` and `logs_metrics` can execute commands, and `announce_channel`
can cause external posts. Inspect these settings before running hooks or skills on an untrusted
branch. Workspace trust includes this file.

Use the repo file for other settings the team shares. The other channels have limits:

- A plugin option is stored in your user settings, even when the plugin is installed for one
  project.
- A skill cannot count on an option. An unset `${user_config.<key>}` falls back to the repo file.
- An option given to the `all` bundle does not reach its plugins. Set it on the declaring plugin.
- Codex has no plugin options, so on Codex the repo file and the environment are the only
  channels.

## Every setting

| Key | Default | What it does |
|---|---|---|
| `base_branch` | `main` | The branch pull requests target and reviews diff against. Read by review, ship, plan, queue and learn. |
| `repo_slug` | blank | owner/name of the GitHub repository. Blank: read from the git remote. Read by ship, queue and learn. |
| `announce_channel` | blank | Where /ship:pr announces a new pull request (for example a Slack channel name). Blank: no announcement. Read by ship. |
| `merge_gate` | blank | A command that must pass before a pull request is merge-ready, or a label that triggers the required check. Blank: the base branch's required GitHub checks. Read by ship and queue. |
| `github_project` | blank | owner/number of a GitHub Project board new issues are added to. Blank: no board. Read by ship and queue. |
| `github_project_version_fallback` | blank | The Version option a new issue gets on the GitHub Project board when no current release can be resolved from recent issues. Blank: Version is left unset. Read by ship. |
| `codex_reviewer_login` | `chatgpt-codex-connector` | The GitHub login of the hosted Codex reviewer whose threads /ship:codex-sweep acts on. Read by ship. |
| `queue_label` | `ship-queue` | The label that marks issues ready for /queue:ship-queue. Read by queue. |
| `logs_metrics` | blank | How /queue:bug-hunt checks production evidence: a command or a short note. Blank: that step is skipped and the finding says so. Read by queue. |
| `rfc_dir` | `docs/rfc` | Where design docs (RFCs) live. Read by review and plan. |
| `adr_dir` | `docs/adr` | Where architecture decision records live. Read by review and plan. |
| `team_rules_file` | `.claude/review-rules.md` | The team's review rules, applied by the review panel's team-rules lens. harness-education appends candidate rules here. Read by review. |
| `review_cadence_commits` | 5 | Nudge a review panel run after this many commits since the last one. Read by review. |
| `review_cadence_lines` | 200 | Nudge a review panel run after this many changed lines since the last one. Read by review. |
| `codex_model` | blank | The model the Codex lens asks for. Blank: Codex's own default. Read by review. |
| `codex_effort` | `high` | Reasoning effort for the Codex lens (for example low, medium, high). Read by review. |
| `claude_model` | blank | The model the Claude lens asks for. Blank: the Claude CLI's own default. Read by review. |
| `claude_effort` | `medium` | Effort for the Claude lens (for example low, medium, high). Read by review. |
| `ocr_gateways` | `[]` | A JSON array of gateways for the optional open-code-review lens, each {name, url, model, key_env or key_file, extra_body}. [] turns the lens off. User options or environment only; ignored in the repo file. Read by review. |
| `commit_gate` | blank | A command that must pass before an agent's git commit (run from the repo root with sh -c). Blank: no commit gate. Read by guards. |
| `commit_gate_timeout` | 570 | Seconds the commit gate's command may take, and the lockfile gate's package-manager runs may take in all, before the commit is blocked as timed out. At most 570, so the hook ends inside its 600-second timeout. A larger value is used as 570, with a warning. Read by guards. |
| `format_command` | blank | The formatter to run on an edited file, with {file} for its path. Blank: detect gofmt or golangci-lint, prettier with a config, ruff or black, rustfmt. Read by guards. |
| `architecture_rules_file` | blank | A document of the team's architecture rules for the architecture-rules lens. Blank: that lens is not offered. Read by review-lenses. |

Values that are not settings, because they are not repo-specific, stay as environment variables
on the script that reads them, for example `CODEX_LENS_TIMEOUT`. Each script's header lists its own.
