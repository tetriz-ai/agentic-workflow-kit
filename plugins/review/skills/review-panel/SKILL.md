---
name: review-panel
description: >-
  Reviews the diff so far with fresh subagents, one per lens, and grades findings Critical,
  Important or Minor. Use during coding when the review-cadence hook nudges, and once before a
  PR (pre-pr). A second model reviews the same range through /review:codex-lens or
  /review:claude-lens. Findings never block, and the panel does not post to a PR.
user-invocable: true
argument-hint: "[cadence|pre-pr]"
---

# review-panel - soft during-coding review

A continuous review layer for the runtime you are coding in. While you code, it spins **fresh
subagents** that read only the **diff-so-far** (never the session history, never the author),
grade findings **Critical / Important / Minor**, and hand them back so you fix the
Critical/Important ones *now*, not at PR time. It works the same under Claude Code and Codex.

**It is soft and runtime-local.** It does not block any commit or the merge gate, and it does not
post to the PR. It is the during-coding complement to your merge gate (the `merge_gate` setting,
or the base branch's required checks): the gate is deterministic and is the only thing that
blocks a merge. The panel's **team-rules** lens applies the team's own written review rules
during coding (Step 2), so those judgment calls surface while context is fresh.

## When it runs

Two run points, both auto-fired by this plugin's review-cadence hook (no one has to remember):

1. **Cadence (default).** Every `review_cadence_commits` commits (default 5) **or**
   `review_cadence_lines` changed lines (default 200) since the last panel run, the hook nudges
   you to run `review-panel cadence`. This is mid-coding: correct early, while the context is
   fresh.
2. **Pre-PR.** When you are about to `gh pr create` with unreviewed commits, or push to an open
   PR with unreviewed commits, the hook nudges you to run `review-panel pre-pr` over the full
   branch diff first.

You can also invoke it by hand: `/review:review-panel` (cadence) or `/review:review-panel pre-pr`.

### Soft does not mean optional

`soft` means **findings never block** the commit, the PR, or the merge gate. It does **not** mean
the run is skippable. **Invariant: a non-empty diff always gets at least one fitting lens; the
only non-run is an explicit, evidenced skip from the whitelist below.** Confidence is when
self-review is *weakest*, so "it looks trivial / config-only / I'm confident" is never a skip
reason. A config-only diff has fitting lenses (blast-radius, plus team-rules when the team has
rules); run it.

**Skip-whitelist.** Skip a nudged run ONLY for one of these, logged in one line **with its
evidence pasted in**, so a false claim is contradicted by its own command output:

**Design docs are never a docs-only skip. This carve-out sits above the whitelist and overrides
it.** A file matching the *Step 2 → Routing a design doc* table (an RFC or a numbered ADR under
the `rfc_dir` and `adr_dir` settings) is **routed, not skipped**, no matter how prose-like the
diff looks: run its structural review plus the `correctness`, `team-rules` and `simplification`
design lenses on the proposed design. The docs-only skip below never applies to it.

- **docs-only**: `git diff --name-only "$BASE"` touches *only* inert prose: files under `docs/`,
  or a top-level prose `*.md` (root `README`, `CHANGELOG`). **Home decides, not extension and not
  whether a file "looks executable":** *anything* under `.claude/**` (a `SKILL.md`, a rule, a
  `CLAUDE.md`, a reference file the agent loads, an agent definition) is guidance the agent acts
  on, so it is **never** docs-only. A guidance change is high-leverage and gets the
  **blast-radius / review-by-attack** lens. Because the test is purely the path, the pasted
  `--name-only` list *is* the check: a `.claude/**` path in it contradicts a "docs-only" claim.
  Routed design docs are the exception (the carve-out above). Everything else under `docs/` skips.
  Log: `review-panel: skipped (docs-only) - <the name-only list>`
- **already-ran-this-HEAD**: `.claude/review-cadence/baseline` equals HEAD **and**
  `git diff "$BASE"` is empty. A dirty tree has unreviewed edits: run the panel.
  Log: `review-panel: skipped (already-ran-this-HEAD)`

On a **cadence** skip, also run the Step 5 reset before stopping, or the `nudged` flag stays set
and mutes later cadence nudges. A pre-PR skip has no such flag; just log it.

## Step 1 - Resolve the diff to review

Run from the repo (or worktree) you are coding in. Resolve the base branch once:

```bash
BASE_BRANCH=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get base_branch '${user_config.base_branch}')
```

**cadence mode** (default): everything since the last panel baseline (fall back to the branch
point if the baseline is missing or stale):
```bash
BASE=$(cat .claude/review-cadence/baseline 2>/dev/null)
if [ -z "$BASE" ] || ! git cat-file -e "${BASE}^{commit}" 2>/dev/null; then
  BASE=$(git merge-base "origin/$BASE_BRANCH" HEAD)
fi
git diff "$BASE"            # committed + staged + unstaged since the baseline
```

**pre-pr mode**: the whole branch against the base branch:
```bash
BASE=$(git merge-base "origin/$BASE_BRANCH" HEAD)
git diff "$BASE"
```

Capture the changed-file list (`git diff --name-only "$BASE"`) and the diff. If the diff is
**genuinely empty** (no changed files), report "nothing to review" and stop. A non-empty diff
that merely *looks* trivial is not empty: run the panel.

## Step 2 - Fan out the fresh-subagent panel

Dispatch **one fresh subagent per lens** using the Agent tool, **in parallel** (independent calls
in a single message). Each subagent is fresh by construction and does **not** inherit this
session's history. Give each only: the **diff**, the **changed-file list**, and its lens prompt.
Subagents may read files in the repo for context but review **only what the diff changes**.

**The fan-out IS the panel. Invoking the panel authorizes its own mechanism, so do not
re-litigate that per call.** Freshness is the entire value: the reviewer must not be the author,
because the author's blind spots and the diff's defects are the same set. If you find yourself
reading the diff *yourself* instead of dispatching, you are not running the panel and must not
report lenses as run: a self-read logs identically to a real one, which is exactly how a missing
review passes unnoticed. Say plainly that the fan-out did not happen and why.

Run the lenses that fit the diff, **never zero**:

- source logic gets the **code-quality lenses** below (plus the Step 2.5 skeptic);
- a config, tooling or generated-artifact diff with no hand-written logic gets the
  **blast-radius lens**;
- a mixed diff gets both;
- **team-rules** runs on any non-docs diff and on a routed design doc, whenever the team rules
  file exists (see its row);
- every **opt-in lens file** whose `applies-to` globs match a changed path also runs (see
  *Opt-in lens files* below).

When unsure whether a file carries logic, treat it as source.

### Opt-in lens files

Domain lenses (database migrations, multi-tenant isolation, sync cursors, performance,
architecture rules, and any the team writes) are separate files, each with a YAML header naming
the paths it applies to:

```markdown
---
lens: database-migrations
applies-to:
  - "**/migrations/**"
  - "**/*.sql"
summary: Table count, value ownership and 10x breakage on schema changes.
---
## Focus
...
## Grounding
...
```

Two places hold them, and both are read on every run:

1. **The review-lenses plugin**, if installed. Invoke the `review-lenses` skill; it prints the
   folder that holds its lens files.
2. **The repo's own** `.claude/review-lenses/*.md`, written by the team in the same format.

Select the lenses for this diff with the selector, which prints one lens file per line for every
file whose `applies-to` globs match a changed path (exit 2 means a lens file has no
`applies-to`, so fix that file rather than skip it):

```bash
CHANGED_LIST=$(mktemp); git diff --name-only "$BASE" > "$CHANGED_LIST"
"${CLAUDE_PLUGIN_ROOT}/scripts/select-lenses.sh" --changed "$CHANGED_LIST" \
  <review-lenses folder, if any> .claude/review-lenses
```

For each selected file, paste its **Focus** section verbatim as `{LENS_FOCUS}` and its
**Grounding** section in place of the template's default grounding paragraph. A lens the team
writes overrides a plugin lens with the same `lens:` name.

### Routing a design doc

A design or decision record is reviewed as the design it *proposes*, not skipped as prose. This
table is the **single authority** for which docs route and to which structural review; to route a
new doc type later, add a row here.

| Doc type | Path it matches | Structural review |
|------|------|------|
| **RFC** | `<rfc_dir>/**/*.md` (setting `rfc_dir`, default `docs/rfc`) | **`/plan:tech-design-doc-review`** (plan plugin), the single authority for RFC review. It applies the decision-workflow checks and every per-section review hook in the writing skill's `sections/*.md`. **Do not enumerate or re-implement those hooks here**: pointing at that skill is what makes the panel inherit new section learnings with no edit to this file. |
| **ADR** | `<adr_dir>/[0-9]*-*.md` (setting `adr_dir`, default `docs/adr`): **numbered records only**, not `README`, `TEMPLATE` or an index | **`/plan:tech-design-doc-review`**, told *"this is an ADR: review by applicability, do not fail it for missing RFC-only sections"*, **plus** the **`/plan:adr`** invariant the RFC reviewer does not own: an accepted ADR is immutable, so a Decision change must **supersede** (a new ADR), not edit in place. |

When the plan plugin is not installed, run the three design lenses below and log that the
structural review was unavailable.

Routing is **per file**: in a mixed diff, route each table-matched doc here *and* run the normal
lens fan-out on the rest. Anything the table does not match takes the docs-only skip. Then, per
matched doc, the steps differ by whether the doc still exists:

**Added or changed**: run the table's structural review, then dispatch **`correctness`**,
**`team-rules`** and **`simplification`** on the **proposed design** the doc describes (its
algorithms, schema, contracts, regexes, thresholds), **not** its changed lines. The doc is a
`.md`, so **`team-rules`** picks its rules from what the doc *proposes* (proposed schema matches a
schema rule, a proposed API contract matches an API rule), **not** from the file extension. **No
other _Step 2_ lens runs.** This scopes the *code-quality fan-out* only, **not** the cross-model
step: **Step 2.6's counterpart lens still applies to a routed design doc** and is especially worth
running here, because a design doc is where a same-model panel is blindest to the correctness of
a doc's claims, and a different-model read catches design defects the same-model panel cleared.
**A doc lens holds the whole artifact, so check its size first** (`wc -c`; divide by 4 for
tokens) and **tell the lens to page it** (`offset`/`limit`, or per-`##` ranges) whenever it is
near a single read's token ceiling. A truncated lens returns a verdict on the fragment it loaded,
which is indistinguishable from a clean pass.
Log: `review-panel: routed <path> (<type>) to <review> + correctness/team-rules/simplification - verdict: <PASS|SCOPED PASS|NEEDS WORK|FAIL> (report produced)`

**Deleted or renamed**: there is no current file and no proposed design, so the structural review
and the three lenses do **not** apply. Dispatch **`team-rules`** alone (or a fresh
general-purpose reviewer when there is no rules file) against the doc's **pre-deletion** content
on one question: is a *decided* record being dropped in place? Decide from the doc's **Status**
(read it, do not assume). An accepted **ADR** is *superseded* (a new ADR), never deleted; an
accepted or implemented **RFC** is the design record, so mark it superseded and keep it. A bare
deletion, or a rename that drops the record, is the finding; deleting a never-accepted draft is
fine.
Log: `review-panel: routed <path> (<type> deletion) to supersede-not-delete review - verdict: <PASS|FAIL>`

A **`SCOPED PASS`** does not complete the route: it means the review graded part of the doc, so
either re-run to cover the rest or log the uncovered sections as an explicit handoff. Never reset
the cadence on it as though it were a full `PASS`. In both routing cases the route is complete
only once the applicable review ran and **any `NEEDS WORK`/`FAIL` verdict was acted on** (Step 4:
fix the blockers or log an explicit handoff; a logged `FAIL` is not "reviewed"); **then reset the
cadence (Step 5)** as for a finished panel run, so the `nudged` flag does not stick.

### The code-quality lenses

| Lens | Looks for |
|------|-----------|
| **correctness** | logic errors, off-by-one, nil/err handling, race conditions, wrong-number/unit/scale bugs, broken control flow; **field-contract change**: flag a change to a field's *value or shape*, or an added field that generic consumers (whole-object serializers, validators, snapshots, telemetry, signing/hashing) observe even when no formatter reads it, whose downstream consumers are left untraced or whose regression against them is unproven |
| **runtime-attack** | the failure regime this code is not written to survive: boundary inputs (zero / empty / max / overflow / off-by-one); concurrent callers (interleaved writes, lost updates, retry storms); partial-failure paths (torn transaction, downstream timeout mid-write, queue redelivery, idempotency assumed but not enforced); requests that arrive during a deploy, a schema change in flight or a cache invalidation; assumptions that hold in dev and break at 10x scale (memory growth, hot-path allocation, N+1 under load, a query that is fine at 1K rows). The **posture** is what makes this a separate lens from `correctness`: correctness asks *"is this logic right per the spec?"*, runtime-attack asks *"what regime breaks it?"*. Read every line as "under what input, load, or failure condition does this fracture?". Always run alongside correctness on a source-logic diff; never skip it on the grounds that correctness "already covers it". The value is the second posture on every line. |
| **matcher** (run *only* when the diff changes a regex / matcher / glob / selector / classifier / boundary check) | **on-demand**: read [`lenses/matcher.md`](lenses/matcher.md) for the verbatim `{LENS_FOCUS}`. This row is a pointer, not the focus. |
| **simplification** | dead code, needless abstraction, duplication, over-engineering, clearer rewrites; **comment taste**: when the diff adds or changes comments **in any language**, read and apply the repo's comment rule (the starter plugin writes `.claude/rules/comments.md`; use the repo's own when it has one) and any language-specific comment rule beside it; judge against those files, not this row or memory. Comment taste is not limited to one language: a migration or a fixture that adds comments gets the same read. |
| **stale-comment** (**grep-gated**: run the Precheck in `lenses/stale-comment.md` first; dispatch this lens only on a hit) | **on-demand**: read [`lenses/stale-comment.md`](lenses/stale-comment.md) for the Precheck, the verbatim `{LENS_FOCUS}`, and its Grounding. This row is a pointer, not the focus. It is the one lens that reviews **outside** the diff. |
| **security** | injection, authz/authn gaps, secret leakage, unsafe deserialization, missing input validation; **redaction on egress**: when a field carrying free text, PII, paths or secrets is serialized and sent (an upload payload, an external API body, a log line, a persisted sidecar), check it against that destination's trust contract rather than assuming it is fine. Secrets never leave; logs and telemetry get redacted; other boundaries need data minimisation or an authorised-recipient decision you can point to in a durable artifact (an RFC or ADR decision entry) whose existence you confirm. A merely asserted authorisation does not pass. A **pre-existing** field newly routed to an egress surface gets the same check even though the field is unchanged |
| **observability** (run *only* when the diff adds or changes a critical decision point: a security or authz decision, a plan, scope or permission gate, a state transition, a bypass or override activation, a fan-out or a high-stakes external-call boundary, an irreversible write) | does that decision carry a right-levelled signal for production validation and debugging? Flag (a) a critical decision with NO log or metric; (b) a wrong-level signal: a significant decision at Debug (not emitted in production, so invisible) or a per-request hot-path trace at Info (log spam). Right level: Error for a failure at a boundary; Info for a rare, significant decision worth production visibility; Debug for a hot-path per-request trace; a metric for an always-on rate. Judgment, not a hard gate: do NOT demand a signal on routine CRUD, getters or pure helpers, only on genuinely critical flows; one meaningful log OR metric is enough, never ask for both; do not ask for a comment that restates the log (a *why* comment is comment taste, owned by simplification) |
| **team-rules** (runs on any non-docs diff, source or config, and on a routed design doc, when the team rules file exists) | **on-demand**: read [`lenses/team-rules.md`](lenses/team-rules.md) for the verbatim `{LENS_FOCUS}` and its Grounding. This row is a pointer, not the focus. It applies the team's own rules from the `team_rules_file` setting (default `.claude/review-rules.md`); the posture lenses above find novel defects, this one enforces the rules the team wrote down. |

### The blast-radius lens

| Lens | Looks for |
|------|-----------|
| **blast-radius** | a config or rule change that does **more than intended** (an over-broad relaxation, a glob or selector that over-matches); a regenerated or pruned artifact that now **hides real violations** (a lint baseline re-prune masking new errors, a snapshot regeneration swallowing a diff); dependency or lockfile drift; CI and build implications. The core question: *does the change's actual scope match its stated intent, and could it silence something real?* For a config or guidance change, also apply the **review-by-attack** posture: what rationalisation does this wording permit an agent, and is every escape hatch (a skip, an inline allow marker, a suppression, a disabled test) bound to falsifiable evidence, not self-attestation? For a **SKILL.md** diff, also flag prose that *explains why* (rationale, history, justification) where the skill should only *instruct what to do*. When a changed file falls under a path-scoped **keep-in-sync** rule (a rule whose `paths:` match and whose body says a document must track this code) and the change moved, added or re-gated the thing that rule's document maps, flag that the referenced document was not updated in the same diff. |

### Subagent prompt template

One template serves every lens; they differ only by what you fill in. Per subagent, set `{LENS}`
to the lens name and `{LENS_FOCUS}` to that lens's "Looks for" cell **verbatim**: do not
paraphrase, summarise, or hand-pick which parts apply. The author-agent is blind to exactly the
dimension it would trim, so an improvised or shortened focus silently drops that coverage. Then
paste the diff. **If that cell opens with `on-demand`** (the row is a pointer to a
`lenses/<lens>.md`, not the focus itself), you **must** read that file first and use its
**Focus** block verbatim as `{LENS_FOCUS}`; if the file also carries a **Grounding** block, paste
it in place of the template's default grounding paragraph below. An opt-in lens file works the
same way. Read a lens file only for a lens you selected. The grounding, grading and output-shape
instructions are identical for every lens.

> You are a fresh, adversarial reviewer for the **{LENS}** lens on a change in this repository. You did not write this code and have no prior context; review only the diff below.
>
> Focus: {LENS_FOCUS}
>
> **Ground every finding in reality. Do not invent rules or claim a check exists without looking.** Before citing a rule ID, confirm it in the repo's own rules (its architecture rules document, its team rules file, its `.claude/rules/`); before claiming a test or lint enforces (or fails to enforce) something, read that test or lint config. If you are unsure a rule fires, say so rather than assert it.
>
> **Flag what you cannot verify from the diff.** If your conclusion, *especially a clean or "safe" one*, depends on state that is not in the diff and not derivable from source (a table's owner, the role a service connects as at runtime, live data values, vendor API behaviour), do NOT grade it clean. Emit it as an **Important** finding with `verifiability: "requires-runtime"` and put the exact command that would settle it in `verification`. Findings you fully checked against source stay `verifiability: "source"`.
>
> For each issue, grade severity:
> - **Critical**: data loss, a security hole, a cross-tenant leak, or breaks existing behaviour.
> - **Important**: will cause problems at scale or for the next feature; a real design or correctness defect.
> - **Minor**: style, naming, a small clarity win.
>
> Every finding MUST include a concrete fix. If you are not sure, phrase it as a question and grade it Minor.
>
> Return ONLY a JSON array (no prose), each item:
> `{"lens":"{LENS}","file":"path","line":<int|null>,"severity":"Critical|Important|Minor","regression_of":"","verifiability":"source|requires-runtime","verification":"<command that settles a requires-runtime finding, else empty>","rule":"<rule-id or empty>","finding":"...","fix":"..."}`
> Leave `regression_of` empty: you have no prior-round context and must not guess at one; the orchestrator fills it in Step 3.
> Return `[]` if the diff is clean for this lens.
>
> --- DIFF ---
> {paste the diff}

Use the `general-purpose` subagent type (or any reviewer agent the session has). The point is a
*fresh* agent, not the author.

## Step 2.5 - Skeptic pass on clean security / runtime-attack / isolation verdicts

A clean verdict is the dangerous one: it is where a confident wrong "safe" hides. Run this skeptic
pass on a clean (`[]` or only-Minor) verdict from the **security** lens, the **runtime-attack**
lens, or an opt-in **multi-tenant-isolation** lens. "I tried to break this and could not" is
exactly the claim that hides a missed failure mode (the concurrent caller, the partial-write path,
the input near a boundary). Spawn one more fresh subagent, given the **same diff and changed-file
list the lens saw**, aimed at the absence of findings:

> You are a fresh {LENS} reviewer. The {LENS} lens reported the diff below clean. Name the single load-bearing assumption that, if false, makes it unsafe or makes it fracture under stress (e.g. "the app connects as a non-owner database role", "this ID is always tenant-scoped before the query", "this code is never called concurrently on the same key", "the upstream never returns more than 1000 rows"). **Pick a *different* load-bearing assumption than the lens's own reasoning. Do NOT restate or re-affirm why the lens concluded clean; your job is the assumption it did not examine.**
>
> **Trace value provenance across function and process boundaries, not one function in isolation.** A function can read as safe while the value it actually handles was set elsewhere: a different caller, an earlier boot path, a copied-then-mutated struct. Ask which concrete value this code sees *at runtime*, where it was populated, and whether the safe property (an empty secret, a scoped ID, a bounded size) is true *then*, not just in the function under the diff.
>
> State whether that assumption is verified by the diff or source (read repo files across the call path if needed) or merely assumed. If it is only assumed AND depends on runtime state, return it as one **Important** finding with `verifiability: "requires-runtime"` and **the exact command that settles it** in `verification`. For a secret or exposure verdict, that is the command that runs the exposing path against a planted secret and greps the output for it. Otherwise return `[]`.
>
> --- DIFF ---
> {paste the same diff the lens reviewed}

This turns the panel's adversarial review onto its *clean* verdicts, not just its findings: a
same-model second angle on the null result. A different-model reviewer is stronger still on a
high-stakes clean verdict (Step 2.6); this skeptic is the cheap standing pass that always runs.
Skip it for the other lenses, whose clean verdicts are lower-stakes; the extra subagent is not
worth the cost.

## Step 2.6 - Cross-model lenses, attempted by default

Same-model coverage shares the author's blind spots. The panel therefore runs the **counterpart**
family here (Claude when Codex authored the change, Codex for every other authoring runtime) plus
OCR as a separate lineage. They are **attempted, not opt-in**, on the cadence below and fold in
additively.

**Engine registry: add a model by adding a row.** Each engine is a self-contained lens script that
honours the same `--base` contract and the shared `<ENGINE>-LENS:` grammar below. Extending
coverage is one new row, one lens script and its line in the run list below; the cadence, the
shared grammar and the folding rules are engine-agnostic.

| Engine | Model / lineage | Lens script | SKIPPED (structural, unspoofable) when |
|---|---|---|---|
| Counterpart | Codex author: Claude. Any other author: Codex. Each engine reads its model and effort from the review plugin's settings (`codex_model`, `codex_effort`, `claude_model`, `claude_effort`). | `scripts/counterpart-lens.sh` in this skill | The selected engine's CLI is not on PATH, or the range changes no file. Conflicting known runtime markers are `COUNTERPART-LENS: FAILED` until explicitly resolved. |
| OCR | `open-code-review` against the gateway and model in the `ocr-lens` settings | the `/review:ocr-lens` skill's `scripts/ocr-lens.sh` | `ocr` not installed, no gateway configured or no key for it, **or** the diff has no reviewable files (every changed file excluded by ocr's filter) |

**When to attempt (default yes), for every engine in the registry:**
- **pre-pr run: always attempt.** Once per branch before the PR is the natural cross-model gate;
  run every engine every time. "The diff looks low-stakes / I'm confident / it is config-only / it
  routed as a design doc" is **not** a skip. The *Routing a design doc* rule "no other Step 2 lens
  runs" scopes the Step 2 fan-out only; it does not cancel this attempt.
- **cadence run: attempt when the diff is high-stakes.** Firing a paid model every few commits
  burns usage, so mid-coding these fire only when a silently wrong *"safe"* verdict would be
  catastrophic or hard to reverse: a leaked secret, a bypassed authz check, a gate or matcher that
  quietly stops gating (security, privacy, auth, a gate or regex/selector/classifier, or code that
  serializes, prints, logs or diffs config or secrets). This is an early-catch trigger only; it
  never gates the pre-pr attempt.

**How to run: each engine as its OWN background task (no LLM subagent).** Every lens script
resolves its backend, runs a **read-only** review of committed `BASE..HEAD`, classifies the
outcome, and prints one leading status token.

Launch **each engine as a separate Bash tool call with `run_in_background: true`**, one tool call
per engine. **Never** a shell `&`, and **never** several scripts batched into one foreground Bash
call. Only a harness background task is tracked: it shows in the task list, survives the turn and
notifies you on completion. A shell `&` (or a blocking foreground call) is invisible to that
tracker. A background task's stdout is **not** read for you, so read its output deliberately when
you fold findings.

```bash
# On the reviewed branch, reviewed work COMMITTED. BASE = Step 1's baseline.
# Run EACH line as its OWN Bash tool call with run_in_background: true.
bash "${CLAUDE_PLUGIN_ROOT}/skills/review-panel/scripts/counterpart-lens.sh" --base "$BASE"   # Bash call 1
bash "${CLAUDE_PLUGIN_ROOT}/skills/ocr-lens/scripts/ocr-lens.sh" --base "$BASE"               # Bash call 2
# Optional high-stakes focus: pass it QUOTED as ONE argument, or a shell metacharacter splits
# the command before the engine sees it.
bash "${CLAUDE_PLUGIN_ROOT}/skills/ocr-lens/scripts/ocr-lens.sh" --base "$BASE" "secret-exposure provenance"
```

`--base` is **branch mode**: the review is of **committed** history (`BASE..HEAD`), not the working
tree, so run it once the reviewed work is committed. The pre-pr attempt naturally is; on a
dirty-tree high-stakes cadence run, commit first, or this pass covers committed work only (the
same-model lenses saw the full `git diff BASE`, and the post-commit pre-pr run is the backstop).

**Read each engine's leading status token and act on it.** `<ENGINE>` is the uppercased engine
name its script prints (`CODEX`, `CLAUDE`, `OCR`); `COUNTERPART-LENS: FAILED` means conflicting
known runtime markers need an explicit override:

- **`<ENGINE>-LENS: FINDINGS`**: the review's structured findings graded
  `critical|high|medium|low` follow. Map to the panel's grades (critical/high to Critical or
  Important, medium to Important or Minor, low to Minor) and fold into Step 3 like any other lens,
  **additive**, never a replacement. A garbled or unparseable return is "read it", never a clean
  verdict.
- **`<ENGINE>-LENS: SKIPPED ...`**: the engine is objectively unavailable, or there is nothing
  for it to review (its SKIPPED column above). These are the only skips. It is structural, so nothing (a branch name, the reviewed
  content) can spoof it. The engine prints the proof (the PATH lookup, or the missing key
  setting) alongside, so "unavailable" rests on a falsifiable artifact.
- **`<ENGINE>-LENS: FAILED ...`**: the run produced no verdict: not logged in, usage exhausted, a
  crash, a network blip, a bad or flag-shaped `--base`, a git error while collecting the diff,
  or a wedged run the engine self-capped.
  The error or partial output is printed. This is **not** a skip: investigate. A self-capped
  timeout (the message names the cap) is re-run with a larger timeout (`CODEX_LENS_TIMEOUT`,
  `CLAUDE_LENS_TIMEOUT`, `OCR_LENS_TIMEOUT`), not a bare retry; never relabel it a clean pass.

Every engine exits 0 on every self-determined outcome (FINDINGS / SKIPPED / FAILED), because this
panel stays soft; it propagates 143/130 only when the caller signals it (TERM/INT). Never treat a
lens's *absence* as a clean verdict, and never let it block.

**Per-engine notes:**
- **Counterpart** treats Codex as the sole special author runtime: `CODEX_SESSION_ID` selects
  Claude; without it, Codex is the default. Conflicting Codex and Claude markers fail visibly
  instead of guessing. `REVIEW_AUTHOR_RUNTIME=<name>` overrides detection; only the exact value
  `codex` selects Claude and every other non-empty name selects Codex. The router prints its
  author/source/engine decision to stderr for auditability and never selects by installed
  binaries. The Codex engine is [`/review:codex-lens`](../codex-lens/SKILL.md) (`codex exec`, read-only
  sandbox); the Claude engine is [`/review:claude-lens`](../claude-lens/SKILL.md) (`claude -p`, restricted
  read-only tools). Both CLIs use their own machine login; the lenses copy no credentials.
- **OCR** is the `/review:ocr-lens` skill's engine. Its gateway, model and key come from the review
  plugin's `ocr_*` settings; see [`/review:ocr-lens`](../ocr-lens/SKILL.md). When it is the only engine
  that returned findings (every sibling SKIPPED or FAILED), re-run it with the raised budget
  `/review:ocr-lens` documents, so the panel's sole cross-model read is not also a capped one. `ocr`
  excludes test files by default; a repo that wants them reviewed adds an `include` list to its
  own `.opencodereview/rule.json`. A diff that still selects nothing reviewable returns
  **SKIPPED (no reviewable files)**, never a `0 findings` that reads as a clean pass.

**Not a substitute for `/ship:codex-sweep`.** These are local, pre-PR cross-model reviews through a CLI.
`/ship:codex-sweep` (ship plugin) consumes the hosted Codex reviewer's threads *after* the PR opens, a
different surface. Both run; these lenses never replace the sweep.

## Step 3 - Aggregate, dedupe, present

1. Parse each subagent's JSON array. Merge all findings.
2. **Dedupe** by `(file, line, rule/finding)`: when several lenses flag the same line, keep one
   entry and note the lenses. A **team-rules** finding that cites a rule a posture lens already
   raised on the same line collapses into that one entry; note both lenses, do not list it twice.
3. Group by severity. Present a compact table with columns: severity, **regression**, file:line,
   lens, finding, fix. The `regression` cell is `REGRESSION (round N)` or empty. Keep it a column,
   never folded into the finding prose, where it stops being sortable.
4. **Pull `requires-runtime` findings into their own group** with the `verification` command shown.
   These are not "clean"; they are "unverified from source" and need a ground-truth check (Step 4).
5. **Stamp `regression_of` yourself.** The Step 2 subagents are context-free by design and cannot
   know what an earlier round found, so this is the orchestrator's job. After merging, persist each
   lens's findings to `.claude/triage/panel-<key>/<lens>-<round>.json` (local run state the repo
   git-ignores), where `<key>` is the issue or PR number when one exists and otherwise the branch
   name. The panel fires before a PR does, so a branch-keyed directory is the normal case.
   `<round>` is the count of existing `<lens>-*.json` files in that directory plus one. This naming
   and this writer are the authority wherever the panel composes with another skill. Before
   presenting a later round, diff its findings against the prior round's file: a finding at the
   same `(file, defect class)`, or one landing in code the prior round's *fix* introduced, gets
   `regression_of: "round N"`. Severity is unchanged by it. If the prior round's file is absent,
   say the round is unchecked for regressions rather than stamping a round number you cannot
   support.
6. **Declare coverage.** State the lens set that ran this round and, when it is a subset of the
   previous round's, which lenses were dropped (`ran 6 of 9 - dropped matcher, security,
   stale-comment`). A delta round is legitimate; an *undeclared* one is not, because its findings
   otherwise carry the same weight as a full round's and a name like "final" reads as whole-diff
   clearance. If more than half this round's findings carry `regression_of`, say so in the same
   line: the fan-out is circling a mechanism rather than converging on the diff, and the fix is to
   simplify the mechanism, not to run another round.

## Step 4 - Act

- **Fix every Critical and Important finding now**, before continuing to code (cadence) or before
  opening the PR (pre-pr), *except* `requires-runtime` findings, which follow the advisory path
  below.
- **Minor**: fix if cheap, otherwise note them; they do not block.
- **`requires-runtime` findings**: run the `verification` command now if you can reach the target.
  If it needs access you do not have (production), flag it as a check to run before deploy: note
  it in the PR test plan or the handoff with the exact command. This is advisory, not a gate; never
  silently grade the change safe because the check was inconvenient.
- **State the decision in one line** so the human sees it was not silent: which lenses ran (e.g.
  "ran blast-radius + team-rules on a config-only diff: 1 Important, fixed") or, if you skipped,
  the whitelist reason (`review-panel: skipped (reason: docs-only)`).
- This panel does **not** post to the PR and does **not** run the merge gate. Keep it that way: the
  gate stays deterministic and runs no LLM.

## Step 4.5 - Re-review the fix delta

The fix is where the next bug hides, and it is the one piece of code a point-in-time review never
saw. Fixes routinely introduce a *new* defect of the very class just fixed: a boundary rewrite that
reintroduces the boundary bug, a matcher tightened into false negatives. A finding is not resolved
when the fix is written; it is resolved when the fix has itself been attacked.

So **before marking any Critical/Important finding resolved** (a panel finding here, or a PR-review
finding you just addressed; Minors are noted, not re-attacked): re-run the **relevant lens(es)**
(the same class the finding belonged to, plus the matcher lens if the fix touched a matcher) on
**just the fix delta**, not the whole branch:

```bash
# BASE = the commit the finding was reviewed against (the panel baseline, or the
# pre-fix HEAD). Delta only.
git diff "$BASE" -- <the files the fix touched>
```

Re-attack the **same failure class** on the new code (the adversarial posture of Step 2, aimed at
the fix). One re-pass per fix round: if it is clean, mark resolved; if it surfaces a same-class
defect, fix that and stop. Do **not** loop indefinitely: cap at one re-pass and, if real residual
risk remains, note it rather than spinning. (`/ship:pr-feedback` points here when you address PR
comments.)

**The same applies to a large mechanical rewrite, not only to a fix.** A rename sweep, a copy or
wording pass, a refactor that touches many call sites: anything that changes text at scale changes
meaning at scale, and the author of the sweep is the reader least able to see it. Re-review the
**rewrite delta** with one question: does any rewritten passage now say something different from
what it said before, or contradict something the sweep did not touch?

A **comment or doc fix that changes meaning counts**: re-attack it with the comment-taste lens
**and** a correctness read against the repo's comment rule, not only the class the original finding
belonged to. A "make it concise" rewrite can introduce a *different* class of defect (a contract
claim trimmed into a falsehood). **Any reword of a clause, including shortening, is
meaning-changing by default**; only a fix confined to whitespace, punctuation, or a single-token
spelling correction skips the re-pass.

## Step 5 - Reset the cadence

After you have triaged (and fixed Critical/Important), rebaseline so the next cadence window starts
fresh. Run it from the reviewed repo or worktree:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/review-cadence.sh" reset
```
It rebaselines that checkout to its current HEAD and re-arms the nudge.

## Boundaries (do not drift)

- **Soft, runtime-local, no merge gate.** If you ever want this to hard-gate, have the agent write a
  structured review-report artifact and let the merge gate verify the file exists and passed; the
  gate never calls an LLM. Do not add that here.
- **Soft is not optional.** Softness is about *findings not blocking*, never about *skipping the
  run*; see the skip-whitelist above. Do not reintroduce "advisory, your call" language that lets a
  confident skip masquerade as a judgment call.
- **Applies the team's rules, does not post them.** The team-rules lens reads the team rules file
  **live** (the single shared source, no copies here to drift) and hands findings back to fix in
  context. The panel does **not** post to the PR.
- **Not `/simplify` or `/code-review`.** Those are user-invoked and one-shot, and `/simplify`
  *applies* fixes directly. This panel's **simplification lens** is review-only: a fresh subagent
  returns graded findings the main agent triages. The lens exists so simplification is covered
  automatically on the cadence, not only when someone remembers to ask.

## See also

- `lenses/`: one `*.md` per built-in lens marked `on-demand` in Step 2 (the verbatim
  `{LENS_FOCUS}`, plus a Grounding block when that lens overrides grounding), read only when the
  lens is selected.
- The review-cadence hook (`scripts/review-cadence.sh` in this plugin) counts commits and lines
  since the baseline; its tests are `scripts/review-cadence.test.sh`.
- [VALIDATION.md](VALIDATION.md): how to validate the whole chain (logic test, mechanism, live
  smoke).
