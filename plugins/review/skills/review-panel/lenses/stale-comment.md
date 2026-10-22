# stale-comment lens — body (loaded on demand, grep-gated)

Loaded by `/review:review-panel` **Step 2**. **Gated:** run the Precheck below first. It is a plain
`git grep`, no agent. If it prints nothing, **skip this lens** (`review-panel: stale-comment
skipped (no candidates)`) and spawn no subagent. Only on a hit do you dispatch the lens, handing
it the **candidate lines** the grep printed plus the diff's **changed-file list**, not the whole
diff. That keeps the common case free and the firing case small. The grep is only the **gate**:
the dispatched lens resolves referents with whatever fits (grep, Glob, Read, LSP). When you
dispatch, paste the **Focus** block as `{LENS_FOCUS}` and the **Grounding** block in place of the
template's default grounding (this lens reviews *outside* the diff).

## Precheck (the gate — deterministic, run before spawning)

The gate fires when a candidate relates to this diff, two ways, and a candidate usually lives
*outside* the diff (that is the stale-on-landing case this lens exists for). `$BASE` is the diff
base from Step 1. Both passes search tracked files only, so generated and vendored trees the repo
ignores stay out.

```bash
RE='(in a follow-?up|not yet (available|landed|implemented|wired|supported)|to be (added|implemented|generated|wired)|temporarily (unscheduled|disabled)|(until|once)[^.]{0,50}(lands?|landed|merges?|merged|on (main|master)|ships?|shipped))'
# (1) revisit: a candidate lives in a file this diff touched. -i: a comment can start
# sentence-case ("// Not yet wired"), which a lowercase pattern would miss.
git diff -z --name-only --diff-filter=d "$BASE" | xargs -0 -r git grep -inIE "$RE" -- 2>/dev/null
# (2) landing: a candidate anywhere in the tree mentions a path stem this diff lands or touches.
# Stems are stripped to plain words so a path component like `[id]` cannot inject a character
# class into the pattern.
NEEDLES=$(git diff --name-only "$BASE" | tr '/.' '\n' | sed 's/[^[:alnum:]]//g' | sort -u \
  | grep -ivE '^(go|ts|tsx|js|jsx|py|rb|rs|java|kt|proto|md|sh|yml|yaml|json|test|tests|spec|src|lib|pkg|cmd|internal|app|service|config|model|api|v1|gen|index|main|utils?)$' \
  | grep -E '.{4,}' | paste -sd'|' -)
[ -n "$NEEDLES" ] && git grep -inIE "$RE" 2>/dev/null | grep -iE "($NEEDLES)"
```

No lines from either pass: skip. Lines: those are the candidates; dispatch the lens on them. The
grep over-fires (a stem can match an unrelated comment); that is fine, because the lens judges
each and drops the non-stale ones. It must never *under*-fire, so the stems are deliberately
broad. The landing pass searches every tracked file because a stale-on-landing comment can live
anywhere (a design doc, a skill, a config value). It stays cheap because the `$NEEDLES` filter
keeps only candidates that name a stem this diff lands; roadmap prose ("once X ships") that does
not intersect the diff never matches.

## Focus (`{LENS_FOCUS}`)

Each candidate is a **forward-looking comment**: a claim that expires when another change lands
(`"until X lands"`, `"not yet available"`, `"in a follow-up once Y merges"`; a comment should
state current behaviour, not a pending change). For each candidate, decide if it is **now
stale** two ways, and report only the stale ones:

- **Landed by this diff:** the referenced symbol, file or operation is in the changed-file list,
  so the thing the comment says "isn't here yet" just landed.
- **Already landed earlier:** locate the referent in the tree with whatever resolves it (`git grep
  -w`, Glob, Read, or LSP go-to-definition). If it resolves now, the comment is stale regardless
  of this diff.

Stale: flag **Important**; the fix is to remove the comment or rewrite it to current behaviour.
If the referent does **not** resolve, it is drift risk only: grade **Minor** or drop it, and do
not claim stale.

**Not targets** (skip; these are not stale-on-landing claims):
- `TODO`/`FIXME` backlog markers: a deferred-work note the author owns, not a claim that expires
  when another change lands.
- Runtime-temporal language (`"until the transaction commits"`, `"while the lock is held"`): it
  expires per request, not on a merge.
- A referent that does not resolve in the tree yet: drift risk only (grade down), never "stale".

## Grounding (replaces the template's default grounding paragraph)

This is the one lens that reviews *outside* the diff, so resolve the referent over the repo, not
just the diff. The Precheck's grep is only the deterministic gate, not your tool budget here; use
whatever confirms the landing (grep, Glob, Read, LSP). Before calling a comment stale, confirm its
referent resolves now and cite the path. If you cannot find it, say so and grade down rather than
assert staleness.
