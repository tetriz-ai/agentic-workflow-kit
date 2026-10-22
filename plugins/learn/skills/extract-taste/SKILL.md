---
name: extract-taste
description: >-
  Collects how an engineer works with Claude Code, such as their preferences, workflow habits,
  shortcuts, repeated corrections and frustrations, from their local memory, CLAUDE.md, settings,
  hooks and session transcripts. It abstracts what it finds, scrubs it for credentials, and raises
  a research pull request to the base branch, which is collected for the team and not merged. Use
  when the user says /learn:extract-taste or asks to share their Claude preferences with the team.
argument-hint: "[--all-work] [--confirm-push] [--consolidator <login>]"
---

# extract-taste

## What this is

A **research instrument**, not a feature. Each engineer carries implicit Claude
working knowledge in their personal config — tastes, nitpicks, efficiencies,
and the things Claude reliably gets wrong for them. This skill surfaces that as
a structured artifact and raises a PR so it can be **collected and clustered**
across the team, then folded into the shared harness (gates, rules, skills,
hooks, CLAUDE.md).

**The PRs this raises are NOT meant to merge.** They are transport for a data
set. The artifact lives in an inert directory (`docs/taste-collection/`) that no
harness path reads, so an accidental merge changes nothing.

## Design stance: rigid on safety, generous on extraction

Two kinds of machinery live here and they follow opposite rules. **Safety**
(name-based private exclude, `scrub.sh` credential gate, no-push-by-default via
`push.sh`) is deliberately rigid and dumb — a miss leaks private data to a shared
PR, which is catastrophic and asymmetric. **Extraction** is deliberately loose and
LLM-driven — a rigid keyword filter would silently bury the gold (a clever
workflow has none of the "frustration" words). Never trade these: do not loosen a
safety gate, and do not add a heuristic that pre-decides what counts as a signal.
`gather.sh` does dumb recall-complete inventory; the model does the judgment.

## Non-negotiables

These are hard. Do not relax them, and do not let any flag override them.

1. **Privacy — name-based private exclude (coarse, not a guarantee).**
   `gather.sh` drops any project dir whose name matches a private marker
   (personal, private, secret, journal, finance, medical, tax, health) or a tmp
   scratch dir. This is a NAME filter, not a content classifier — a privately
   *named* work dir (a client repo, `side-notes`) is NOT auto-excluded. Under
   `--all-work` you must review the kept-dir list and exclude any private dir
   yourself, per dir. Never weaken this filter; state its coverage honestly.
2. **Privacy — abstract, never dump; scrub is signatures only.** Capture the
   *signal*, never raw transcript text, secrets, customer names, or PII.
   `scrub.sh` mechanically blocks known *credential signatures* (keys, tokens,
   DSNs, private keys) — it CANNOT detect customer/client names, internal project
   names, or free-form PII. Those rest on you abstracting and the human reviewing.
   A clean scrub means "no credential shape found", NOT "safe to share". If
   something cannot be stated without leaking, drop it.
3. **No-push by default; gates bound to exit codes.** A default run STOPS after
   assembly + scrub + showing the artifact; it never pushes. The push path is
   `push.sh` ONLY (Step 5) — it refuses without `--confirm-push`, aborts on a
   scrub HARD hit (a credential signature; SOFT warnings do not block), and aborts
   unless the staged diff is exactly the one artifact file. Never push with raw
   `git`/`gh`; that bypasses the gates.
4. **Relevance filter — team-transferable only.** Only keep signals that imply a
   *shared harness change that would help others*. Drop purely personal
   interaction taste (e.g. "I like terse replies") — that helps no one but the
   individual. Borderline cases go to a `needs-judgment` bucket, never silently
   dropped. Note: a stylistic-looking signal can still be team-relevant (e.g.
   "no arrow glyphs in PR/chat output" is a comms convention) — judge by
   "would the team adopt this?", not by "is it about style?".

## Procedure

### Step 0 — Identity + isolation
- Runner handle: `gh api user --jq .login`. Call it `<handle>`.
- Work in a throwaway git worktree so the runner's current checkout is
  untouched. The branch is cut from **`origin/<base_branch>`** (the `base_branch`
  setting), never from whatever branch the runner happens to be on — so taste PRs
  are always clean against the latest base branch. Re-running the skill is
  expected, so a prior worktree is replaced, but only when it holds nothing
  unpushed: an uncommitted artifact, or commits on `taste/<handle>` that its
  remote branch (else `origin/$BASE`) does not have, stop the step with the work
  left in place:
  ```bash
  BASE=$("${CLAUDE_PLUGIN_ROOT}/scripts/kit-config.sh" get base_branch '${user_config.base_branch}')
  WT=/tmp/extract-taste-<handle>; BR=taste/<handle>
  git fetch origin "$BASE"
  git fetch origin "+refs/heads/$BR:refs/remotes/origin/$BR" 2>/dev/null || true
  git worktree prune
  if git rev-parse -q --verify "refs/heads/$BR" >/dev/null; then
    UP="origin/$BR"; git rev-parse -q --verify "refs/remotes/$UP" >/dev/null || UP="origin/$BASE"
    if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ] || [ "$(git rev-list --count "$UP..$BR")" != 0 ]; then
      echo "extract-taste: $WT or $BR holds work that is not pushed. Push it with push.sh, copy it out, or delete it yourself; Step 0 does not." >&2
      exit 1
    fi
  fi
  [ ! -d "$WT" ] || git worktree remove "$WT"
  git worktree add -B "$BR" "$WT" "origin/$BASE"
  ```
  If the step stops, ask the user what to do with the prior work; never delete it
  for them. `-B` then resets `taste/<handle>` onto fresh `origin/$BASE`, which is
  safe because nothing unpushed is left on it. If `git worktree add` reports the
  branch is checked out elsewhere, `git worktree prune` (above) clears stale
  entries; resolve any live conflicting worktree before retrying. After this, **verify your writes land in the worktree,
  not the main repo** (early writes can mis-route) —
  `git -C /tmp/extract-taste-<handle> status` before trusting. Write only there.

### Step 1 — Gather sources (deterministic)
Run the bundled discovery script from the repo root:
```bash
"${CLAUDE_PLUGIN_ROOT}/skills/extract-taste/gather.sh"                       # this repo only (verified)
"${CLAUDE_PLUGIN_ROOT}/skills/extract-taste/gather.sh" --all-work            # widen: lists candidate dirs, STOPS
"${CLAUDE_PLUGIN_ROOT}/skills/extract-taste/gather.sh" --all-work --approved # widen: inventory the approved dirs
```
Default scope prints: static sources to read in full; the in-scope project dirs
(every dir logged keep/skip/drop, never silent); memory dirs; and a full inventory
of **all** in-scope sessions with three signal columns — `markers`, `user_turns`,
`size_kb`. Membership is decided by **ground truth**: a dir is kept only if a
session's recorded `cwd` is under this checkout or its git origin matches this repo
— so a sibling repo that merely shares the name substring (e.g. `<repo>-fork`) is not
swept in. The script inventories; it does not pre-pick — you triage. A real clone
whose `cwd` no longer resolves is logged `skip (unverified / other-repo)`. Note the
gate proves a session's *starting* origin; if a session later `cd`s into a
different repo, those turns are read unverified — Pass B disregards foreign-cwd
turns, and abstraction + scrub + review are the backstops (there is no per-session
multi-cwd validation).
Sessions whose transcript contains a produced taste artifact are **self-excluded**
(logged `self-excluded`), so a re-run is never biased by an earlier run's
conclusions. This also drops the skill's own dev/validation sessions (they handled
the artifact) — accepted, since no content signature separates them and their
working-style is redundant; there is no precise session-id exclusion.

`--all-work` is **origin-blind** and can pull in other repos (even a different
org's), so it is two-phase: `--all-work` alone lists the candidate dirs and **reads
no sessions**; you **show the user the kept-dir list and get explicit PER-DIR
approval** (do not blanket-approve a long list); only then re-run with `--all-work
--approved` to inventory. Default scope never needs this.

### Step 2 — Extract + classify (independent subagent passes)
The goal is the **gold mine**, including dimensions nobody has named yet —
optimise for recall. Extraction runs as **fresh subagents, not in this main
context**: the agent running the skill has read the design and the user's stated
prefs, so doing it inline would pattern-match to expectations instead of
discovering. Keep the reading independent. This three-pass flow IS the skill — a
manual/dry run follows it exactly, so it is identical for everyone.

**Pass A — codified (one subagent).** Reads the static sources + memory dirs in
full -> the user's *stated* preferences. Cheap, dense, and gold the team cannot
see today.

**Pass B — observed (fan-out, BLIND to Pass A).** Two complementary mechanisms —
partition for coverage, specialists for depth. **Do not give any Pass-B subagent
Pass A's output or the user's stated prefs** — they surface behaviour
independently, so synthesis can catch where stated and observed diverge. Each
returns abstracted candidate signals only, no raw text. **Disregard any turn whose
`cwd` is outside this repo** (a mid-session `cd` elsewhere) — the scope gate proves
only the session's starting origin, so foreign-repo turns must not become signal.

1. **Generalist partition (coverage).** Take the inventory in signal-ranked order
   and split it into **disjoint batches** (~8–10 sessions each); one generalist
   subagent per batch extracts *every* dimension from its sessions. Partition is
   for coverage, NOT lens-narrowing — each session gets a full-spectrum read, no
   session is single-angled. **Decide how deep to go by saturation, not a magic
   number:** process batches in ranked order and dedup new `key`s; **stop when 2
   consecutive batches add < ~5% new keys** (diminishing returns — more reading
   just re-finds the same habits). Backstop ceiling: deep-read at most ~60–80
   sessions (one concurrency wave) so a huge corpus can't run away. Everything
   below the deep-read line gets ONE cheap **skim** pass (obvious signals only) —
   skimmed, never skipped.
2. **Specialist passes (depth on the gold).** Alongside the generalists, run
   dedicated single-angle agents over the **high-`markers` head** for the angles a
   generalist skims past — above all a **frustration / "where Claude reliably
   disappoints + repeated corrections"** specialist, so that bucket is never
   collapsed into `correction`/`anti-pattern`. (Add an efficiency specialist if
   the corpus is large.)

These lenses drive batch **ordering** and the **specialist** angles — NOT the
generalist read (generalists stay full-spectrum per #1, no single-angling): high
`markers` -> corrections/frustrations; high `user_turns`/`size_kb` with *zero*
markers -> long sessions where efficiencies and clever workflows hide (a marker
gate would bury these); recent (`ls -t`) -> current habits.

**Pass C — synthesize (one fresh subagent).** Given A + B (abstracted signals
only), it dedups by `key`, classifies, and flags two high-value cases for free:
*overlap* (codified AND observed -> high confidence) and *contradiction* (stated in
config but behaviour fights the opposite -> prime harness signal). Two standing
rules:
- **Discover, don't just bucket.** The taxonomy is a *seed*, not a cage — coin a
  new dimension rather than force a fit.
- **Keep when uncertain.** A marginal entry costs the consolidator one glance; a
  dropped one is gold gone. Only purely personal interaction taste is dropped (see
  non-negotiable #4); everything plausibly transferable is kept as
  `transferable: needs-judgment`.

Report coverage with **evidence, not bare assertion** — "saturated"/"skimmed" are
otherwise self-grantable skips. The coverage report MUST include a per-batch table
(`batch | sessions | new keys | %new`) plus `skim_sessions` and `skim_new_keys`,
and which specialist lenses ran. What this actually binds: the reconcile
**deep-read + skimmed = in-scope** is checkable against gather.sh's hard in-scope
count; the `%new` saturation stop is **human-auditable, not machine-proof** (an
agent computes it from its own key set), so a reviewer can demand a deeper pass.
Listing a couple of the new `key` slugs per batch makes a `skim_new_keys: 0` over a
large tail checkable rather than just claimed.

**Dimension taxonomy** (a seed — assign one, or coin a new dimension for anything
that does not fit; `uncategorized` is the catch-all):
| dimension | what it captures |
|---|---|
| `style` | output format, verbosity, tone, naming, comment density |
| `workflow` | branch / PR / test / commit / review habits and sequencing |
| `efficiency` | tooling hacks, aliases, subagent-dispatch patterns, custom hooks |
| `correction` | instructions repeated across sessions (signals a baseline gap) |
| `frustration` | where Claude reliably disappoints — the must-fix gold mine |
| `verification` | trust posture: what they double-check, what they never trust |
| `domain` | repo-specific facts they keep teaching Claude |
| `anti-pattern` | explicit "never do X" rules |
| `uncategorized` | novel, doesn't fit above |

### Step 3 — Assemble the artifact
Write one file: `docs/taste-collection/<handle>.md` (markdown, not yaml). The file body is the banner comment,
the frontmatter, the `# Taste profile` heading, and a single ```yaml ``` entries
block — the outer ```markdown wrapper below is display-only, do not write it into
the file. Structure:

```markdown
<!-- COLLECTION ARTIFACT — research only. NOT wired into the harness. Do NOT merge. -->
---
handle: <handle>
generated: <date>            # ask the user for today's date; do not invent
scope: this-repo-clones | all-work
sources: { memory: N, claude_md: N, settings: N, hooks: N, sessions: N }
dropped_personal: N          # count of personal-only signals filtered out (transparency)
---

# Taste profile: <handle>

```yaml
# One block, parsed by the harvester. Each entry:
entries:
  - key: <stable-slug>            # kebab summary of the signal; stable across runs for dedup
    dimension: <taxonomy value OR a new dimension you coined>
    signal: <one-line abstracted statement>
    detail: <optional, <=2 sentences. Abstract the SHAPE of a nuance a one-liner
             flattens (e.g. how a workflow is structured). No verbatim quoting, no
             transcript text, no names/secrets.>
    evidence: <how observed — e.g. "stated in global CLAUDE.md" / "corrected ~6x across sessions">
    frequency: low | medium | high
    transferable: team | needs-judgment   # NEVER write `personal` here — those are dropped
    suggested_home: gate | rule | skill | hook | claude-md | new | unknown
```
```

`key` is a stable slug of the normalized signal — it is what a future
auto-collection mode diffs against to avoid re-raising the same preference.

### Step 4 — Scrub + review-gate
1. Run the scrub to surface anything mechanical before showing the user:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/skills/extract-taste/scrub.sh" /tmp/extract-taste-<handle>/docs/taste-collection/<handle>.md
   ```
   A **HARD hit** (credential signature) must be abstracted out and re-run until
   clean — never push past it. **SOFT warnings** (emails, hostnames, URLs) are
   surfaced for judgement, not blockers. Scrub does NOT catch customer names or
   free-form PII — scan for those yourself.
2. Show the full artifact to the user; let them edit, drop, or reclassify.
3. **STOP here unless `--confirm-push` was passed.** Report the artifact path and
   end. The default run never pushes — the safe default for private data.

### Step 5 — Raise the PR (only with `--confirm-push`)
Use the wrapper — it is the only sanctioned push path. It re-runs scrub as a hard
gate, verifies the staged diff is exactly the one artifact file, then commits,
pushes, opens the labelled PR, and tags the consolidator — the person who
collects taste PRs, passed as `--consolidator <login>` (ask the user if it was not
given). **Never push with raw `git`/`gh`** — that bypasses the gates.
```bash
EXTRACT_TASTE_CONSOLIDATOR=<consolidator-login> \
  "${CLAUDE_PLUGIN_ROOT}/skills/extract-taste/push.sh" <handle> /tmp/extract-taste-<handle> --confirm-push
```
It prints the PR URL and copies it to the clipboard. When the artifact is the same as the one
already on `taste/<handle>`, it prints `no new taste since <commit> (<date>)` and exits 0 with
nothing committed, pushed or refreshed: tell the user there is nothing new and go to Step 6.

### Step 6 — Clean up
```bash
git worktree remove /tmp/extract-taste-<handle>
```
Report the PR URL to the user.

## Lifecycle note
The skill itself ships in the kit (so everyone who installs it has
`/learn:extract-taste`). The artifacts it produces are not merged. The harvest/cluster
step is a separate, consolidator-side concern — out of scope here.
