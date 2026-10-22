# §8 Testing Strategy

**What it is** — how you'll prove it works, and **what it takes to actually test it** — front-loaded so testing isn't discovered late.
**Applies when** — every RFC that ships behaviour.

## Claude drafts (derivable)
- The test layers and the edge cases each covers (unit: which edges, mocked-vs-real; integration: real/realistic deps; load: tool + pattern + acceptance if relevant).

## Author decides (grill — printed question + your recommendation + "or your take")
- **Automated validation, local AND deploy — minimize manual.** How do we validate this *automatically* on a dev machine, and again on deploy, so we're not eyeballing it by hand? Name the automated check per environment; call out the *little* that genuinely must be manual and why. *Recommend the automated path; push back on "we'll verify manually."*
- **Test scenarios** — the concrete behaviours to assert (happy + the edges: empty / first-run / error / stale / below-threshold). Derive them from **PRD/RFC intent** — ideally drafted in a fresh session that hasn't seen the implementation, so they assert *intended* behaviour, not the code that was written.
- **Test preparation** — what it takes to run those scenarios: env (local / deploy), seed data + fixtures, an operational job's READ mode or `grpcurl`, access (cookie / VPN / AWS profile), which DB. Frontload this.
- **Cross-boundary seams — name the one artifact both sides assert against.** Where the design's slices span more than one runtime or process (a mobile client and its API, two services in different languages, a producer and a consumer separated by a queue), per-layer tests prove each side against *its own* assumption of the other — so every suite stays green while the two assumptions disagree, and no single slice's Definition of Done covers the contract between them. For each such seam name the **single shared artifact** — a golden fixture is the canonical shape — that the producing side asserts it *emits* and the consuming side asserts it *consumes*. Assign it in the Task Breakdown to the **consuming** slice: the consumer is the side that breaks, and a seam owned by no slice is a seam nothing tests. Where the far side genuinely cannot be reached from a test (a third-party API with no usable credential), say so as a **named gap** — an unreachable boundary is disclosed, never a mock presented as coverage.
- These automated checks and the prep are **themselves slices** in the Task Breakdown — not an afterthought.

## Ground in (pointers — read, don't restate)
- the testing skills domain routing finds for each layer (unit, integration, end-to-end)
- the repo's environments doc for local/deploy specifics

## Review hooks (what /plan:tech-design-doc-review checks here)
- "We will add comprehensive tests" with no specifics → WARN.
- **Automated** local+deploy validation named (not manual-by-default) → missing → WARN.
- Concrete test scenarios incl. edges → happy-path-only → WARN.
- Test-prep frontloaded (env/fixtures/access) → missing for a non-trivial feature → WARN.
- **Slices spanning two runtimes/processes with no shared artifact named for the seam** (each side asserted only against its own assumption of the other) → FAIL. The gate is the *named artifact*, not a promise to test the seam — "we'll add an end-to-end test" leaves the same hole, because a suite per side is exactly what passes while the two sides disagree. The unreachable-boundary carve-out is **not self-assertable**: it applies only when the doc names the *specific* missing access (a credential no one in the org holds, a vendor with no sandbox tenant) — "hard to test", "needs prod", or a bare "not testable" is a FAIL, not a disclosure, and a mock standing in for the far side is coverage theatre either way.
