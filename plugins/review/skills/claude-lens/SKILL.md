---
name: claude-lens
description: >-
  Runs a local, read-only adversarial review of the current branch's committed changes with
  Claude, using the model and effort from the review plugin's settings. Use for
  /review:claude-lens, for a second opinion from Claude, or as the review panel's automatic
  counterpart when Codex wrote the change. The Claude CLI handles sign-in, and this skill never
  copies credentials.
user-invocable: true
argument-hint: "--base <ref> [focus text]"
---

# claude-lens: local Claude review

This engine runs the local `claude` CLI over committed `BASE..HEAD` with an adversarial prompt
and structured output. It is the Claude sibling of [`/review:codex-lens`](../codex-lens/SKILL.md):
direct `/review:claude-lens` always means Claude, while [`/review:review-panel`](../review-panel/SKILL.md)
selects it automatically when the authoring runtime is Codex.

The model and effort come from the review plugin's `claude_model` and `claude_effort` settings
(blank model: the CLI's own default). The CLI runs with safe mode, restricted file tools, no
Bash/Edit/Write, no permission prompts, and no session persistence.

## Run it

Run the engine as its own background task after committing the reviewed work. Resolve the base
branch and the settings once:

```bash
BASE_BRANCH=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get base_branch '${user_config.base_branch}')
export CLAUDE_LENS_MODEL='${user_config.claude_model}' CLAUDE_LENS_EFFORT='${user_config.claude_effort}'
bash "${CLAUDE_PLUGIN_ROOT}/skills/claude-lens/scripts/claude-lens.sh" --base "origin/$BASE_BRANCH"
bash "${CLAUDE_PLUGIN_ROOT}/skills/claude-lens/scripts/claude-lens.sh" --base "origin/$BASE_BRANCH" "auth + tenant isolation"
```

Read its leading status token:

- `CLAUDE-LENS: FINDINGS`: a completed structured review follows.
- `CLAUDE-LENS: SKIPPED`: the `claude` binary is not installed, or the range changes no file
  (nothing to review, so no model call). These are the only skips.
- `CLAUDE-LENS: FAILED`: no verdict: login, quota, model access, network, parse, bad base,
  configuration, or timeout failure. Never treat this as a clean pass.

The engine does not seed or copy credentials. It uses the Claude CLI's existing machine login or
inherited provider environment. A developer who has not used Claude Code on the machine runs
`claude auth login` once. Do not use `--bare` for this lens, because bare mode disables the
login the CLI already has.

The locally installed CLI sends the committed review diff to the provider and account that CLI
is configured to use, the same trust boundary as an ordinary Claude Code session on that
machine. The model process runs from a private temporary directory holding a snapshot of the
tracked files, not the live checkout, so its read-only tools cannot reach untracked files.

## Boundaries

- This is always the Claude engine; it never changes model family based on the caller.
- The Codex lens owns the shared adversarial prompt and structured-output schema; this adapter
  substitutes only the reviewer identity.
- It reviews committed history, not the working tree.
- It is local and pre-PR. It does not replace the hosted `/ship:codex-sweep`.
- `review-panel` invokes it through the counterpart dispatcher; OCR remains additive.
