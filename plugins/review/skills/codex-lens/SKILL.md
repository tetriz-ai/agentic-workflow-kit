---
name: codex-lens
description: >-
  Runs a local, read-only adversarial review of the current branch's committed changes with Codex,
  using the model and reasoning effort from the review plugin's settings. Use for
  /review:codex-lens, for a second opinion from Codex, or as the review panel's automatic
  counterpart when anything other than Codex wrote the change. It is not the sweep of the hosted
  Codex reviewer's comments after a pull request opens, which is /ship:codex-sweep.
user-invocable: true
argument-hint: "--base <ref> [focus text]"
---

# codex-lens: local Codex review

A **model-specific** review engine: it runs the local `codex` CLI over the committed `BASE..HEAD`
range with an adversarial prompt. It is a cross-model pass when any non-Codex runtime authored the
change, and stays explicitly invocable from any runtime. Nobody has to comment on a PR to arm a
hosted bot; anyone with the Codex CLI runs this and gets the review locally.

**What is set, and why it matters.** The engine invokes `codex exec` with the model and reasoning
effort from the review plugin's `codex_model` and `codex_effort` settings, passed as `-c`
overrides, so they win over whatever each person's own Codex config holds. A blank model uses the
CLI's configured default. Set both in the plugin's settings to give everyone the same review
standard. The run is **read-only**: it never mutates the tree and never runs tests or builds; the
script rejects any sandbox other than read-only.

## Run it

1. **Resolve the base.** `--base <ref>` is required; pass a branch or ref (the engine computes
   the merge-base with `HEAD` itself). Optional trailing text is an opaque **focus** passed to
   the review. Fetch first so the base is current:

   ```bash
   BASE_BRANCH=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get base_branch '${user_config.base_branch}')
   git fetch origin "$BASE_BRANCH"
   ```

2. **Run the engine as its OWN background task** (`run_in_background: true`), never a foreground
   call and never a relay subagent: it spends no model tokens of its own. It self-caps on a
   wall-clock timeout and notifies you on completion:

   ```bash
   export CODEX_LENS_MODEL='${user_config.codex_model}' CODEX_LENS_EFFORT='${user_config.codex_effort}'
   bash "${CLAUDE_PLUGIN_ROOT}/skills/codex-lens/scripts/codex-lens.sh" --base "origin/$BASE_BRANCH"
   # focused:
   bash "${CLAUDE_PLUGIN_ROOT}/skills/codex-lens/scripts/codex-lens.sh" --base "origin/$BASE_BRANCH" "auth + tenant isolation"
   ```

   Never route it through a write-capable Codex task runner; this soft pass must not mutate the
   tree.

3. **Read the output deliberately** (a background task's stdout is not read for you). The first
   line is one status token:
   - **`CODEX-LENS: FINDINGS`**: the review completed; the structured findings JSON follows. Fold
     critical/high into your work like any review finding.
   - **`CODEX-LENS: SKIPPED`**: `codex` is not installed, or the range changes no file (nothing
     to review, so no model call). Both are structural and unspoofable.
   - **`CODEX-LENS: FAILED`**: no verdict (not logged in, quota, model not on the plan, crash,
     a bad or flag-shaped `--base`, a git error while collecting the diff, a missing schema, a
     run with no final message, or a self-capped timeout). The error or partial output is printed. **Not a
     clean pass**: investigate; on a timeout re-run with a larger `CODEX_LENS_TIMEOUT`, never
     relabel it.

4. **Record the run on the PR (optional).** When the review ran against an **open PR**, a marker
   comment makes runs countable later. Skip it when there is no PR or no network; never block on
   it.

   ```bash
   HEAD_SHA=$(git rev-parse --short HEAD)
   gh pr comment <PR> --body "$(printf '<!-- codex-lens:run -->\ncodex-lens reviewed `%s`: model %s, effort %s, %s findings' "$HEAD_SHA" "${CODEX_LENS_MODEL:-default}" "$CODEX_LENS_EFFORT" "<N>")" || true
   gh pr view <PR> --json comments -q '[.comments[]|select(.body|contains("<!-- codex-lens:run -->"))]|length'
   ```

## Boundaries

- **Not the hosted sweep.** `/ship:codex-sweep` consumes the hosted Codex reviewer's threads *after* a
  PR opens, a different surface at a different time. Both run; neither substitutes for the other.
- **Counterpart engine for non-Codex authors.** Review-panel's dispatcher invokes this script
  when any non-Codex runtime authored the change; running `/review:codex-lens` directly is always the
  on-demand Codex path.
- **Tuning.** Model and effort are settings; the diff-size thresholds and the wall-clock cap are
  in [`codex-lens.config`](codex-lens.config) and can be raised for one run through the
  environment; the adversarial prompt is [`codex-lens.prompt.md`](codex-lens.prompt.md), from
  OpenAI's Codex plugin for Claude Code (see NOTICE).
