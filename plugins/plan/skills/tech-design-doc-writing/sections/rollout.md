# §9 Rollout & Operational Readiness

**What it is** — how it ships safely, and how we answer "are we ready." Gating mechanics live in §10 Feature Flags; one-off jobs in §11 Operational Jobs; this section is the *plan* + the *readiness*.
**Applies when** — any change that reaches production.

## Claude drafts (derivable)
- The phase skeleton (shadow → canary → gradual → cleanup) adapted to the change.

## Author decides (grill — printed question + your recommendation + "or your take")
- **Rollout lever & its scope granularity** — first state *what* the rollout lever is and *how finely it targets*: a per-org feature flag (org-granular), an identity-keyed allowlist, or a **global per-surface config lever** (e.g. a client-wide cache-refresh counter: every client, no per-org targeting). Do not assume a per-org phased plan when the lever is global.
  - **Per-org phased rollout** (when the lever is org-granular) — the order: which orgs first, then widen, then global (driven by the §10 flag's per-org overrides → global default). *Recommend a pilot set + widen criteria.* If the lever is **global/fleet-wide**, there is no "pilot just these orgs" — plan the phasing on the dimensions the lever *can* actually vary (environment, client type, or a minimum-app-version adoption floor), and state that **every production increment stays fleet-wide for eligible clients**. Do not present repeated counter bumps as staged exposure: a monotonic counter serves only its latest value with no cohort targeting, so re-bumping refreshes the same clients rather than widening a cohort.
- **"Are we ready?"** — the readiness answer: the **runbooks + monitoring (dashboards/alerts)** that exist **before** launch and give the observability to operate this. Plus the **post-launch warehouse-health watch window** (from the Observability concern) — who watches, how long.
- **Rollback** — per phase, "how do I undo this in under 10 minutes?" (flag flip, backward-compatible schema). If you can't, that's a design problem.
- **Deploy mechanics** — the repo's standard deploy strategy (e.g. blue-green); do **not** spell it out here unless a **new infra component** is added (then it's an HLD item).

## Ground in (pointers — read, don't restate)
- the repo's deployment and environments docs
- the repo's rollout/deploy config; any observability skill domain routing finds

## Review hooks (what /plan:tech-design-doc-review checks here)
- A **phased** rollout (not "flip on for all orgs once merged") → WARN.
- A **rollback trigger + procedure** per phase → missing → for a production change, FAIL.
- **Readiness**: dashboards/alerts/runbooks exist before launch → missing for a prod-facing feature → WARN.
