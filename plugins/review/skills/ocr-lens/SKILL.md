---
name: ocr-lens
description: >-
  Runs a local, read-only adversarial review of the current branch's committed changes with
  open-code-review, a model of a different lineage, through the gateways and model in the review
  plugin's settings. Use for /review:ocr-lens, or as the review panel's extra engine next to the
  automatic Codex or Claude counterpart. It is not the sweep of the hosted Codex reviewer's
  comments after a pull request opens.
user-invocable: true
argument-hint: "--base <ref> [focus text]"
---

# ocr-lens: local cross-model review with open-code-review

A **cross-model** review engine: it runs `open-code-review` (`ocr`) over the committed
`BASE..HEAD` range, so an independent model (a different lineage from the active-runtime panel and
its Codex/Claude counterpart) attacks the change. It gives a cross-model review with no hosted
bot. `ocr` is a separate tool you install (`npm install -g @alibaba-group/open-code-review@1.8.6`);
that is the version the kit is tested against, also named in [`ocr-lens.config`](ocr-lens.config).

**What is set, and why it matters.** The engine points `ocr` at an ordered list of gateways from
the review plugin's user-controlled `ocr_gateways` option or `AGENTIC_KIT_OCR_GATEWAYS` environment variable (never the repo file). Each gateway names an OpenAI-compatible endpoint, a
model, where its key comes from (an environment variable or a key file), and an optional extra
request body (for example, one that turns off a model's reasoning output). The lens uses the
first gateway that can serve and falls back to the next on a missing key or a permanent
401/402/403/404/429 failure (auth, insufficient credits, model not found, quota). The tool cap and
the token and wall-clock caps are in [`ocr-lens.config`](ocr-lens.config). Settings win over each
person's own `ocr` config. The model must do **native tool calls**: a reasoning model that
narrates them inside `<think>` hangs. The run is **read-only**: it never mutates the tree and never
runs tests or builds.

## Run it

1. **Resolve the base.** `--base <ref>` is **required** and is a literal ref: the review is of
   **committed** history (`BASE..HEAD`), not the working tree, so run it once the reviewed work is
   committed. Pass the merge-base with the base branch (the engine does not compute it). Optional
   trailing text is an opaque **focus** passed to the review.

   ```bash
   BASE_BRANCH=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get base_branch '${user_config.base_branch}')
   git fetch origin "$BASE_BRANCH"
   export OCR_GATEWAYS_JSON='${user_config.ocr_gateways}'
   ```

   **Warn before the first run.** `ocr` has no per-run option for the request body, so each run
   writes the serving gateway's `extra_body` into `ocr`'s **user** config
   (`~/.opencodereview/config.json`, key `llm.extra_body`), replacing any value the person set
   there. Before the first run in a session, tell the user this in one line; if they object, do
   not run the lens.

2. **Run the engine as its OWN background task** (`run_in_background: true`), never a foreground
   call and never a relay subagent. It self-caps on a wall-clock timeout (`OCR_LENS_TIMEOUT`) and
   notifies you on completion:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/ocr-lens/scripts/ocr-lens.sh" --base "$(git merge-base "origin/$BASE_BRANCH" HEAD)"
   # focused: pass it QUOTED as ONE argument, or a shell metacharacter splits the command
   bash "${CLAUDE_PLUGIN_ROOT}/skills/ocr-lens/scripts/ocr-lens.sh" --base "$(git merge-base "origin/$BASE_BRANCH" HEAD)" "secret-exposure provenance"
   ```

3. **Read the output deliberately** (a background task's stdout is not read for you). The first
   line is one status token:
   - **`OCR-LENS: FINDINGS`**: the review completed; the structured findings JSON follows (or
     `FINDINGS (0 findings — clean review …)` when nothing was flagged). Fold critical/high into
     your work like any review finding.
   - **`OCR-LENS: SKIPPED`**: one of three structural cases, each unspoofable: `ocr` not
     installed, no gateway configured or no key for any configured gateway, **or** the diff has no
     reviewable files (every changed file excluded by ocr's filter). The engine prints the proof
     alongside.
   - **`OCR-LENS: FAILED`**: no verdict. A gateway's auth, credit, quota or model failure first
     **falls back** to the next gateway; FAILED is terminal only when every gateway failed
     permanently, or immediately for a cause that does not fall back on the serving gateway (a
     missing config, a crash, a bad or flag-shaped `--base` (checked before any gateway runs),
     ocr's own PARTIAL coverage, or a self-capped timeout). The key-redacted error output and the fallback trail are printed. **Not a clean
     pass**: investigate; on a timeout re-run with a larger `OCR_LENS_TIMEOUT`, never relabel it a
     clean review.

4. **Raise the budget when this lens is the only cross-model read the change got.** The caps in
   [`ocr-lens.config`](ocr-lens.config) are sized for a panel where a sibling engine covers the
   same diff; when the sibling returned SKIPPED or FAILED, a budget-bound run turns that absence
   into thin coverage nobody declared. Override both for the one invocation (the config assigns
   them only if unset):

   ```bash
   OCR_LENS_TOKEN_BUDGET=800000 OCR_LENS_TIMEOUT=4800 \
     bash "${CLAUDE_PLUGIN_ROOT}/skills/ocr-lens/scripts/ocr-lens.sh" --base "$(git merge-base "origin/$BASE_BRANCH" HEAD)"
   ```

   A `PARTIAL coverage` warning means some selected files went unreviewed, and it does not say
   which of its two causes applies: an exhausted token budget, or per-file failures. Re-running at
   a higher budget tells them apart: coverage that grows was budget; coverage that stops at the
   same files was not, and those files need investigating. Either way partial findings are not a
   clean pass.

## Boundaries

- **Not the hosted sweep.** `/ship:codex-sweep` consumes the hosted Codex reviewer's threads *after* a
  PR opens, a different surface at a different time. Both run; neither substitutes for the other.
- **Additive to the automatic counterpart.** Review-panel runs OCR alongside Claude for a Codex
  author or Codex for any other author; neither result replaces the other.
- **Same engine as review-panel Step 2.6.** The panel invokes this same script on its pre-PR
  cadence; running `/review:ocr-lens` directly is the on-demand path.
- **File selection.** *Which files* are reviewed is `ocr`'s own filter; `ocr` excludes test files
  by default, and a repo that wants them reviewed adds an `include` list to its own
  `.opencodereview/rule.json`.
