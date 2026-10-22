---
name: pr
description: >-
  Creates or updates a pull request. It checks the scope first and splits or stacks a sprawling
  diff, writes a Conventional Commits title and a description backed by evidence, following
  /ship:pr-communication, links a GitHub issue, and announces the pull request in the
  announce_channel setting when one is set. It also brings an existing pull request's title,
  description and scope up to date when the pr-nudge hook fires on a push. Use when the user says
  /ship:pr or asks to create or update a PR.
argument-hint: "[--no-announce] [reviewers...]"
---

# Create PR

A PR authored by an agent is cheap to produce and expensive to trust — so this skill spends its
effort on the two things that make an agent's PR trustworthy: **keeping it small enough to review**
(the scope check) and **proving the claims in it** (evidence-bound validation). Both are steps the
agent runs, not prose it writes. The body shape and the why behind it live in `/ship:pr-communication`
and its `pr-template.md`; this skill is the procedure.

Every step below diffs against the base branch from the `base_branch` setting:

```bash
BASE_BRANCH=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get base_branch '${user_config.base_branch}')
```

## Pre-flight

1. **Scope check — do this first.** Run `git diff "origin/$BASE_BRANCH" --stat` and judge whether
   the branch is **one logical change**. Sprawl is the default failure of agentic coding: one prompt
   can leave a feature, an unrelated refactor, and a drive-by fix in the same branch, and no
   description rescues a mixed-scope PR as well as splitting it does. If the diff spans independent
   concerns, the default is to **split or stack** (separate branches/PRs, smallest reviewable units)
   — surface this to the user before opening one mixed PR. Proceed with a single PR only if the user
   opts to, or the units genuinely must ship together — in which case name them in the body's
   **Scope** section and say why.
2. Summarize the change from `git diff "origin/$BASE_BRANCH" --stat` and the commit log.
3. Identify the GitHub issue this PR addresses — **mandatory for any PR targeting the base branch**:
   - Ask the user: "Which GitHub issue does this PR close? (e.g., #123)"
   - Include a closing keyword + number at the end of the PR body: `Closes #NNN` (or `Fixes`/`Resolves`).
     A bare issue URL is not enough — it must be preceded by a closing keyword.
   - If no issue exists yet, create one first with `/ship:github-issues`.
   - There is **no `no-issue` escape hatch**. Your merge gate, if it has one, may hard-require the
     closing keyword, and the merge then stays blocked without it.
4. Resolve reviewers (if provided as skill arguments or mentioned by the user). **First strip any
   recognized flags from the argument list** — `--no-announce` is a flag (it suppresses the
   announce step for a disposable or test PR), **not** a reviewer; never resolve it as a handle or
   pass it to `gh pr create --reviewer`. Then for the remaining names:
   - For each name, find the best-matching GitHub handle among recent contributors:
     ```bash
     gh api "repos/:owner/:repo/contributors?per_page=100" --jq '.[].login'
     ```
     Cross-check against `git log --format='%an <%ae>'` if needed to map real names → handles.
   - If there is a clear single match (name substring in login, or unambiguous git author), use it.
   - If multiple plausible matches or none found, ask: "Did you mean `@handle1` or `@handle2`?" —
     do not guess.
   - Collect the final list of handles (without `@`) for the `--reviewer` flag.

## Capture visual evidence (before/after)

Mandatory whenever the PR changes what a user sees on a rendered surface — whether the change lives
in frontend code **or** in a backend/API/data path the surface renders. Capture before/after
screenshots with the repo's own capture tooling (for example a Playwright suite run against a
running dev server). Do this **before** writing the body (step 5) so the images are ready to embed.

**Availability skip.** If no capture tooling runs in this environment — the tooling is not installed
or its browser binaries are missing (a capture run fails to launch; a `--version` check alone may
not reveal this) — skip the capture and record the **actual failing output** in the PR's
**Validation**, so the missing visual evidence is visible to the reviewer, not silently dropped.
This is the *only* capability-based skip; do not invoke it when the tooling is runnable (that is
dodging the step, not a skip).

- **When it fires.** Either trigger fires it. Judge against the PR's **merge-base** diff
  (`git diff --stat "origin/$BASE_BRANCH"...HEAD`, three-dot — not tip-to-tip, so files changed
  only on the base branch when the branch is behind don't count):
  - **Frontend code** — the diff touches a code or style file under a renderable surface (a web
    app, a static site, an app's UI layer). Plain modules count, not only components and
    stylesheets: display is often driven from them (class maps, copy or pricing data) — the
    non-visual ones fall out via the evidence-bound skip below. A **shared UI package** edit
    ripples to every app that *consumes* it, so capture one route per consuming app — check the
    `package.json` consumers, don't assume.
  - **Backend / data-driven** — a change with **no frontend file touched** that still alters what a
    surface renders: copy/labels served to the client, a field/flag/enum the UI maps to display (a
    trend direction, a status, a count or denominator shown on a card), or the shape/contents of a
    payload a surface draws (e.g. adding previous-period points so a trendline shows current +
    previous, a new series, reordered rows). This trigger is author judgment anchored to those
    signals — a `git diff` path glob cannot catch it, so do not lean on one.
  - **Skip** only when the PR changes nothing a user sees. The skip is a claim about *rendered
    output*, not about which files changed, so bind it to evidence either way — a bare "no
    rendered-output effect" line is not enough: for a touched-but-non-visual frontend path, cite the
    hunk that shows no markup/class/style/token change; for a backend/data change, name the
    signals checked and found absent (the changed fields/enums/copy are read by no client display
    mapping, the payload shape a surface draws is untouched). Never fabricate a shot.
- **What to capture.** Every affected route **and every distinct state the PR changes** (empty /
  populated / error; light + dark if the change is theme-sensitive; each affected tab). **There is
  no cap on the number of screenshots** — add every shot that carries distinct signal; drop any
  visually identical or near-identical to one already included (no redundancy). Capture the **full
  route, not the top viewport**. When a layout scrolls inside a nested fixed-height container, a
  full-page screenshot captures only the viewport. Screenshot the tall inner content node instead
  (an element screenshot clips to the element's box, so aiming it at the viewport-height container
  still drops below-the-fold), or scroll-and-stitch. If you cannot get a full-height image, say so
  on the PR rather than pass a top-only shot off as the full route.
- **Mechanism — per surface.** Use the capture tooling that matches the surface: the repo's
  visual harness where one exists (add a route to it for an uncovered route rather than
  hand-rolling a spec), otherwise a throwaway spec run against that surface's own dev server.
  Never attach a screenshot of one surface for a change to another. Delete a throwaway spec after.
- **Before vs after.** Capture the branch first (**after**), then produce the **before** by reverting
  only the layer the PR changed:
  - **Frontend-code change** — render the base UI: overwrite only the changed client files present at
    the merge-base with their base version, let the dev server rebuild, re-capture, then restore and
    confirm a clean tree:
    ```bash
    BASE=$(git merge-base "origin/$BASE_BRANCH" HEAD)
    # only paths present at BASE — a file this PR adds has no "before" to check out
    git checkout "$BASE" -- <changed client paths that existed at BASE>   # capture "before", then restore:
    git checkout HEAD    -- <paths still present in HEAD>                 # modified files
    git rm -f               <base-only paths the PR deletes/renames>      # checkout HEAD can't restore a path absent from HEAD
    git status --short                                                    # must be clean
    ```
  - **Backend / data-driven change** — the frontend is unchanged, so vary the **mocked API response**,
    not any code: mock the pre-change response for **before** and the post-change one for
    **after** (for example with Playwright's `page.route`), both against the same branch UI. No
    backend run or checkout needed. **Derive the before payload from the base source**
    (`git show "$BASE":<file>`, or the removed side of the diff hunk), never hand-crafted from
    memory — a "before" that never matched the base code is a fabricated comparison. If the exact
    pre-change shape can't be derived, flag the pair in **Unverified & assumptions** instead of
    presenting it as confirmed.
  A brand-new file/surface (absent at BASE) has no before — label it "new" and show after only.
- **Upload + embed — never commit images.** Upload the captures through GitHub's web attachment
  (the PR editor's file upload), which returns `https://github.com/user-attachments/assets/<id>`
  URLs. Embed those URLs in the body's **Screenshots** section, before vs after side by side in an
  HTML `<table>`. Capture output goes under a git-ignored directory or any temp dir — images must
  not enter git history. Do not fall back to committing images. If the upload cannot be completed,
  record the failing output in **Validation** so the missing embeds are visible, exactly like the
  availability skip.

## Create

5. **Write the title and body per `/ship:pr-communication`** (which owns `pr-template.md`):
   - **Screenshots.** Embed the before/after full-page screenshots from *Capture visual evidence*
     into the body's Screenshots section (skip only when the PR changes nothing a user sees, or no
     capture tooling runs here — see *Capture visual evidence*).
   - **Title** — Conventional Commits, `type(scope): imperative subject`, < ~70 chars (full spec and
     the `type`/`scope` vocabulary are in `pr-template.md`).
   - **Body** — impact first, map not transcript, omit-empty sections.
   - **Validation is run, not promised.** Actually execute the checks and paste their real output
     (the repo's tests and build, the merge gate result, `review-panel pre-pr` verdict, any manual
     hit). An agent must not assert a green it did not produce. **For the `review-panel` verdict,
     include the reviewed HEAD SHA** (e.g. `review-panel: <lenses>, 0 Critical/Important, reviewed
     @ <sha>`) — the panel does not post to the PR, so this line is the only thing telling a
     reviewer the panel ran and up to which commit (a HEAD past that SHA means a stale panel).
   - **Declare blind spots.** Anything the change asserts that you could not prove from source or a
     local run goes in **Unverified & assumptions** with the exact check that settles it — never
     silently presented as done.
6. Ensure generated code (API stubs, mocks, dependency-injection wiring) is regenerated if applicable.
7. Run the repo's build to verify.
8. Create the PR **ready, not a draft** (include `--reviewer` only if reviewers were resolved):
   ```bash
   gh pr create --title "<title>" --body "<description>" [--reviewer handle1,handle2]
   ```
   Never `--draft`: a draft blocks the hosted Codex review and hides the issue↔PR link.
   - **Fold later fixes as new commits, never `git commit --amend`.** Once the branch is pushed, amend forces a force-push (a permission prompt) and the merge squashes anyway (step 13), so plain incremental commits are strictly simpler and hook-friendly; only amend a commit you have not pushed.

## Arm the Codex review sweep (after creating a NEW PR)

Codex posts its review ~1-2 min later. Instead of leaving the author to come back
and run `/ship:pr-feedback` by hand, hand the *waiting* to a background shell loop that
costs no tokens, and let `/ship:codex-sweep` act once there is something to address —
so no LLM turn is spent while Codex is still working.

9. **Arm only when the step-8 `gh pr create` just produced a new PR** — it exited
    0 and printed a fresh `/pull/<N>` URL. Skip if no PR was created, if `gh pr
    create` echoed back a pre-existing PR, or on the reconcile path below.
    Otherwise launch the sweep's waiter **once**, as a background `Bash` (not
    `ScheduleWakeup`). Use the quoted plugin-root path below, so it runs from
    **any** cwd — a worktree, a subdirectory. A bare cwd-relative path fails the
    moment the Bash cwd is a subdirectory, and the sweep then silently never arms:
    ```
    Bash(command: '"${CLAUDE_PLUGIN_ROOT}/skills/codex-sweep/codex-sweep.sh" await <PR>',
         run_in_background: true,
         description: "await Codex review on PR #<PR>")
    ```
    This does not block — the turn ends. `await` polls Codex in a shell loop (each
    poll is zero tokens; the wait is a `sleep`) and exits the moment there is
    something to act on, re-invoking you **once** with a triage whose last line is a
    `NEXT: run /ship:codex-sweep <PR>` handoff. Follow it: `/ship:codex-sweep` fixes the
    clear-cut Codex findings, replies on each thread, and surfaces human threads
    read-only (it never resolves — that stays the author's last touch). Launch the
    waiter exactly once per PR; do not also fire a `ScheduleWakeup` for the same PR.
10. **After launching, print one quiet line** so the author knows it is handled (once,
    plain, no banner/emoji-spam) — e.g. `↻ Watching for Codex's review on #<PR> — I'll
    address its comments with fixes + replies when it lands, and leave the threads open
    for you to resolve before merge.` Print it only when step 9 actually launched the
    waiter; never on the reconcile path or when no PR was created.

## Reconcile an existing PR (on push)

A PR's title and description are written once and rot as the branch grows. When you push to a branch
that already has an open PR, the `pr-nudge` hook fires — re-check both the **scope** and the
**text** against the full branch. This is the AI-judgment step the hook cannot do itself.

1. Gather the current state:
   ```bash
   gh pr view --json number,title,body
   git log "origin/$BASE_BRANCH"..HEAD --oneline
   git diff "origin/$BASE_BRANCH"...HEAD --stat
   ```
2. **Scope drift first.** If the branch has grown into more than one logical change, the fix is not
   a better description — re-run the **Pre-flight scope check** and surface splitting/stacking. A
   reviewer should never be handed a sprawling PR with a tidy paragraph papering over it.
3. **Text drift.** Does the title still name what this PR does? Does the body cover every commit and
   area now in the diff, and is its Validation still true of the current HEAD? New scope a reviewer
   would not expect from the current text = drift.
4. **Visual drift.** If a commit pushed since the screenshots were captured changed a rendered
   surface (same trigger as *Capture visual evidence*), the embedded before/after is stale — the
   uploaded assets are frozen at capture time, so a reviewer sees pre-push visuals. Re-capture for
   the new HEAD, re-upload, and re-embed (or drop the section if the change is no longer visual).
5. If it drifted, rewrite both (per `/ship:pr-communication`) and update — preserve the `Closes #NNN`
   line, and re-run/refresh **Validation** so its evidence matches the pushed HEAD:
   ```bash
   gh pr edit <PR> --title "<new title>" --body "<new body>"
   ```
   If scope expanded materially, also check the linked issue still covers it (broaden it or link
   another).
6. If nothing material changed, say so and move on — do not churn the description.

## Announce the PR (when `announce_channel` is set)

11. Read the `announce_channel` setting:
    ```bash
    CHANNEL=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get announce_channel '${user_config.announce_channel}')
    ```
    Post to that channel after PR creation. **Mandatory when the setting is set and the session
    has a chat connector** — never skip out of forgetfulness. Skip **only** when one of: the
    setting is blank, the session has no chat connector that can post to the channel, **or** the
    caller passed `--no-announce` (a disposable or test PR that must not reach the real channel —
    `/queue:ship-queue` threads this through for its per-slice `--integration-branch` PRs). Otherwise:
    - Resolve each reviewer's chat user ID through the connector's user search. Neither name nor
      email alone is guaranteed to match — try them in order, stop at the first hit:
      1. Full real name (from `git log --format='%an' | sort -u`, e.g. `"Jane Doe"`)
      2. First name only (e.g. `"Jane"`)
      3. Git author email (from `git log --format='%ae' | sort -u`, e.g. `jane.doe@example.com`)
      4. GitHub handle (e.g. `janedoe`) — rarely works but cheap to try
    - If all lookups miss or return multiple ambiguous hits, fall back to plain `@name` text rather
      than a broken/wrong mention.
    - Message format — **exactly one line + link, never a free-drafted multi-line post**:
      ```
      <PR title in one line> — <PR URL> (cc <@USER_ID> [<@USER_ID> ...])
      ```
      Omit the `cc` segment if no reviewers. **The shape is invariant to how interesting the PR is** — operator-facing notes (a scope decision, a follow-up, a deploy order, the fix rationale) belong in the **PR body**, not the channel; if you are typing a second sentence, it is going in the wrong place. A multi-paragraph post is the wrong shape and forces a hand-edit.
    - Send it through the connector's send-message call to the channel named in `CHANNEL`.
    - If no chat connector is configured, skip this step silently — do not error.

## Merging (only when the user asks you to merge, not just open)

Opening a PR does **not** make it mergeable: the merge stays blocked until the merge gate passes.
Read the `merge_gate` setting:

```bash
GATE=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get merge_gate '${user_config.merge_gate}')
```

Blank means the base branch's required GitHub checks. Otherwise it names the command or label that
clears the gate; such a gate may not run on its own, so run the command or apply the label. Clear
the gate first, then:

12. **Pre-merge check** (verify, don't assume): the PR links an issue (step 3), the merge gate is
    green (for a blank `merge_gate`, `gh pr checks <N> --required` passes), and
    `gh pr view <N> --json mergeStateStatus --jq .mergeStateStatus` is no longer `BLOCKED`.
    A `the base branch policy prohibits the merge` error means the gate is not cleared — fix that, do
    not bypass it.
13. **Merge** (default squash; keep history tidy):
    ```bash
    gh pr merge <N> --squash --delete-branch
    ```
    Merging needs no admin rights. **Never use `--admin` to bypass branch protection** — if the merge
    is blocked, the gate at step 12 is not green; fix the gate.
