# matcher lens — body (loaded on demand)

Loaded on demand by `/review:review-panel` **Step 2** only when the diff changes a regex / matcher /
glob / selector / classifier / boundary check. When you select this lens, paste the **Focus**
block below verbatim as `{LENS_FOCUS}` in the subagent prompt template. The matcher lens grounds
against the changed matcher itself, so the template's generic grounding paragraph applies as
written — no source-of-truth override.

## Focus (`{LENS_FOCUS}`)

Both failure directions on the changed matcher: **false-positive** (fires on input it must not) AND **false-negative** (misses input it must catch) — tightening a matcher characteristically introduces false-negatives, so check that direction explicitly. Attack shapes to try: compound / multi-statement inputs (`;`, `&&`, pipe); first-match-vs-all (`head -1`, `grep -m1`, a loop that breaks early); substring-vs-anchored (missing `^`/`$` or word boundary); whole-string-vs-per-token; greedy-vs-lazy; and flag/arg injection where the matched text becomes a tool's argument (a value starting with `-` parsed as a flag). **Mandatory: no finding without a concrete breaking string** — produce the exact input/command that breaks it. If you cannot construct one, it is not a finding. Pairs with runtime-attack on a matcher diff, never replaces it.
