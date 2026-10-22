# Task-brief issue body — the executable task template

For an **implementable task**: a slice from an RFC's Task Breakdown, or any standalone task meant to be taken end-to-end (by `/queue:ship-task` or a human). The issue description **doubles as the agent brief** — `/queue:ship-task` reads it to ground a sub-agent and run the task to completion. So it cannot be a stub; it must carry everything needed to build the task **without re-deriving the design**.

## The body template

```markdown
## Summary
What + why, 2-3 sentences, anchored to the PRD/RFC intent (not a restatement of the title).

## References
- **PRD:** <link/path> + the section that motivates this
- **RFC:** <rfc_dir>/<name>.md (the plan plugin's `rfc_dir` setting, default `docs/rfc`) + the slice / sections this implements (e.g. §6 LLD, §7.3 RLS)
- **Parent ticket:** #N (if this is a sub-task)
- **Related:** PRs / tickets / ADRs — #N, ADR-N

## Scope
- **In:** exactly what this task delivers
- **Out:** what it deliberately does not (bounds the agent — prevents scope creep)

## Grounding (read before building)
- **RFC sections that specify this:** the contract / schema / processing / concern this slice realizes
- **Codebase paths:** the packages/files it touches (where the new code lands — from the RFC's package-distribution table)

## Acceptance / demoable proof
- The slice's concrete proof — **not a screen, not "looks right":** an integration test through <real path>, a `grpcurl` of <rpc> with expected response, an operational job's READ mode on <job>, or an ingest-to-table assertion (the ingestion path writes the expected rows). State the exact check that proves done.

## Execution
- **HITL / AFK:** `autonomous` (gates suffice) or `human-gated` (names the one human decision and where it sits)
- **Depends-on:** #N that must land first (drives the multi-slice drain order + stacked-vs-independent; empty = independent)
- **Implementing skill:** the domain build-skill that carries this slice's conventions — one of: `/skill-name` (grounding reads it); `none — <reason>` (pure refactor / operational job / no owning surface — grounding works from RFC + code only); or `/skill-name (verify — may be stale)` (grounding reads it but does NOT treat it as gospel). A genuinely-atomic two-surface slice may list **both** skills comma-separated (`/<backend-skill>, /<frontend-skill>`) — grounding reads each. From the RFC slice's "implementing skill" column.
- **Test prep:** env (local / deploy), fixtures/seed, access (cookie / VPN / AWS profile), which DB

## Estimate
- set the project **Estimate** field (active wall-clock days; see `/ship:github-issues`). Not a body line.
```

## Field rules (the anti-stub contract)
- **Grounding is mandatory** — references that resolve + the RFC sections + the code paths. A task-brief with no RFC/PRD anchor and no code paths is a stub; `/queue:ship-task` cannot run it autonomously and will have to stop and ask.
- **Acceptance is a check, not a vibe** — it must be the demoable proof an agent (or a human) can execute and observe. If you can't name the check, the task isn't ready.
- **HITL/AFK is load-bearing** — `/queue:ship-task` runs an `autonomous` task unattended and **pauses** a `human-gated` one at its decision point; `/queue:ship-queue` reads the same field and records a `human-gated` blocker rather than shipping the slice. The **values and how they are resolved** are single-sourced in the `tech-design-doc-writing` skill's `sections/task-breakdown.md` (the HITL/AFK bullet) — fill this field from there, do not invent a synonym. Tag by **where a decision sits**, not by how sensitive the area feels: a schema change or an auth path is not automatically gated (an automated guardrail may cover it — see the autonomy second pass), and a question the RFC's Decisions Log **already answers** is a lookup, so the slice builds autonomously against the decided answer rather than being gated on it.
- **Depends-on is the DAG edge** — `/queue:ship-queue --integration-branch` orders the multi-slice drain on it (it ships a slice only once every `Depends-on` is merged onto the integration branch); `/queue:ship-task` reads it to decide stacked-vs-independent for a single slice. Write it as `#N` (or `#N, #K` for several); empty / `—` / `none` = independent.
- **Implementing skill is honest, not aspirational** — it routes the **grounding** subagent (`/queue:ship-queue` Step 2) to the right surface's conventions, so the brief carries the correct token-system / contract / placement knowledge. Owned by the breakdown author. Use `none — <reason>` when no skill owns the surface (the empty cell must be a checkable claim, not silence), and `/skill (verify — may be stale)` when a skill exists but you are not sure it is current — grounding then reads it for orientation but verifies against the live code rather than trusting it. A stale skill silently trusted is the failure this field's honesty prevents.

## Mapping an RFC slice → this brief
The RFC's Task Breakdown is written to fill this 1:1:

| Task Breakdown field | Task-brief field |
|---|---|
| slice (what it is) | Summary + Scope.In |
| RFC anchor | References.RFC + Grounding |
| demoable proof | Acceptance / demoable proof |
| HITL/AFK tag | Execution.HITL/AFK |
| depends-on | Execution.Depends-on |
| implementing skill | Execution.Implementing skill |
| (layers crossed) | Grounding.Codebase paths |

So creating tickets from a reviewed RFC is mechanical: one issue per slice, this template, filled from the slice's row. Ticket creation happens **after the RFC passes review** (so tickets map to the reviewed design) — `/queue:ship-task` does it just-in-time per slice, never the RFC-writing skill.
