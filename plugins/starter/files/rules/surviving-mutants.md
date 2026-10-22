---
paths:
  - "**/*_test.go"
  - "**/*.test.*"
  - "**/*.spec.*"
  - "**/test_*.py"
  - "**/*_test.py"
---

# A surviving mutant is information about three things, not one

The loop is: write the test, delete the fix, confirm the test fails. When it fails, the
test is real. When it *passes* — the mutant survives — the reflex is to strengthen the
test, and that is only one of three possible readings.

A mutant survives when the behaviour you asserted is delivered by something other than
the line you deleted. So it says exactly one of:

1. **The test is weak.** It never reached the behaviour. Strengthen it.
2. **The code is redundant.** Some other mechanism already guarantees the behaviour —
   a database CHECK, a caller that filters first, a type that cannot hold the bad value.
3. **Your explanation is wrong.** The line is doing something, but not the thing its
   comment says it does.

Reading 3 is the one that gets missed, and it is the expensive one, because the wrong
explanation outlives the code review and misleads whoever changes the line next.

## A worked case

A lookup guarded each key on being non-empty:

```sql
WHERE ((@email <> '' AND c.email = @email)
    OR (@phone <> '' AND c.phone = @phone))
```

Deleting both `<> ''` guards changes no test result. The behaviour ("empty keys match
nothing") is real and worth pinning, but the columns' own
`CHECK (email IS NULL OR email <> '')` also delivers it: no row can hold `''`, so an empty
parameter already matches nothing. The guard is a second belt, and a comment calling it *the*
mechanism would be the defect.

The right response is neither to delete the guard nor to strengthen the test. Keep the guard
for the reason that survives scrutiny (the statement should not depend on a constraint it does
not own), and say in both the code and the test that two mechanisms deliver this, so removing
either one alone leaves the case passing.

## What to do

- **Record surviving mutants; never silently drop them.** A mutation you ran and did not
  report is indistinguishable from one you never ran.
- **Before strengthening the test, ask what else delivers the behaviour.** If something
  does, name it in the comment. A justification that survives a mutation is worth more
  than a test that was contorted until it failed.
- **A test pinning a behaviour that two mechanisms deliver is still worth having** — it
  guards the behaviour, which is what the reader cares about. Just say so, so the next
  person is not misled into thinking it guards the guard.

Related: [operational-principles](operational-principles.md) — a check that returns the
same result under a plausible alternative reading is not evidence for either.
