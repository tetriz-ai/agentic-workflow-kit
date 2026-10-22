---
name: pr-feedback
description: >-
  Gathers every piece of review feedback on a PR in one pass: inline comments, review bodies and
  the conversation, with thread state. Use when addressing or auditing PR comments, and before
  calling them resolved.
user-invocable: true
argument-hint: "[pr-number]"
---

# pr-feedback - complete PR review feedback

GitHub PR feedback is split across separate API surfaces, and no single common command returns all of them. In particular, `gh pr view --comments` and `gh api .../pulls/N/comments` both **miss review bodies** (`/pulls/N/reviews[].body`) - where a Codex review, or a human's review summary, often puts its findings. So "I addressed all the PR comments" is unreliable: an entire surface can be invisible, and a finding gets silently dropped.

This skill fetches all three surfaces in one pass and prints a triage list, so coverage is complete by construction.

## Run it

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/pr-feedback/pr-feedback.sh" [PR_NUMBER]   # no arg -> the current branch's PR
```

It surfaces, grouped:
- **Review bodies** - the commonly-missed surface (a review's top-level body).
- **Inline review threads** - each with state: `RESOLVED`/`UNRESOLVED` and `outdated`. An *outdated* thread can still be a valid, unaddressed finding - do not skip it because it moved.
- **Conversation comments** - top-level PR comments.

Plus a count summary, and a warning (never a silent truncation) if any surface exceeds 100 items - in which case the list is not complete and you must paginate before claiming full coverage.

## Then TRIAGE every item

Fetching is only half; the point is that nothing is dropped:
1. For each finding decide **fix now / already-fixed / won't-fix (with a reason)**. Leave nothing unaddressed silently.
2. Reply where it lives: an **inline** finding -> reply in-thread using the thread's **`reply target: id N`** (the thread's top-level comment — GitHub does not support replying to a reply): `gh api repos/<owner>/<repo>/pulls/<N>/comments -F in_reply_to=N -f body=...`; a **review-body** or **conversation** finding -> a top-level PR comment referencing it (there is no in-thread reply target for a review body).
3. When you fix a **Critical/Important** finding, the fix delta is un-reviewed code where the next bug hides — re-review it before calling it resolved (`/review:review-panel`'s re-review-the-fix-delta step, Step 4.5: re-run the relevant lens on just the delta, re-attacking the same failure class, one re-pass).
4. State the disposition in your summary so the human can see nothing was missed.

## Boundaries

- **Read + present only.** It does not post, fix, or resolve anything - triage and replies are yours.
- **Scope:** the three PR-review surfaces (inline comments, review bodies, conversation). Commit-line comments (`/commits/<sha>/comments`) are out of scope - a rare surface for review findings.
- Bot review bodies may include boilerplate (e.g. a Codex "About" footer); the substantive finding is the part to act on.
- It strips ANSI color from the API response (some setups emit colored JSON), so it is safe whether or not your `gh` colorizes.
- Soft/advisory, like the rest of the during-coding review layer. A deterministic guarantee that every surfaced finding is triaged *before merge* belongs in your merge gate, if it has one, not in this skill.

## See also
- `${CLAUDE_PLUGIN_ROOT}/skills/pr-feedback/pr-feedback.sh` - the engine (one GraphQL query over all surfaces).
- `/review:review-panel` - produces review feedback; this aggregates and triages it.
