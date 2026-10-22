# bug-hunt — author-gate / filing regression scenarios

The acceptance cases for the author-gate + filing contract (author-gate.md, filing.md, evidence-manifest.md). Skill behaviour is prose, so these are the checks a change to that contract must still satisfy. **(script)** marks the cases whose *format/completeness shape* `scripts/readiness-check.sh` enforces mechanically (covered in `scripts/readiness-check.test.sh`) — the lint proves a cell is present and well-formed, not that an anchor points at real code or a test exists; that binding stays the agent's grounded duty and the author gate. The rest are behavioural checks a reviewer verifies against the contract prose.

1. **Many findings, some multi-layer.** The table recommends one atomic outcome for each; none is marked held solely for breadth. (author-gate.md "one atomic outcome")
2. **Empty-group scope bug.** The agent recommends a fail-closed explicit scope; it does not ask the author to invent the solution. (author-gate.md "resolve, then present")
3. **Rarely used path, latent defect.** Choosing "fix before activation" allows **P1 + ship-queue** with no re-grounding. (author-gate.md priority ≠ severity; ship-queue ≠ activity)
4. **Several owner changes + one excluded person.** The regenerated distribution matches every row exactly; the excluded person has zero. (author-gate.md owner distribution)
5. **"rows 4–6 same as above; P1 and ship-queue".** The decision log expands it across all three rows; the next table shows each explicitly. (author-gate.md decision log)
6. **Shared server-side HTTP connection pool.** The review text distinguishes it from the caller's own client and explains the cross-request/cross-tenant sequence. (author-gate.md actor/boundary language)
7. **A causal check for the agent + a product fork for the author.** The table labels them differently and asks the author only the product question. (author-gate.md question classification — rejects an agent-owned question)
8. **Approved hunt → file.** Filing creates/enriches from the existing drafts with no broad code search; only rows whose anchors actually drifted are re-grounded. (filing.md "three things")
9. **Gitignored internal ledger.** The GitHub body contains the evidence inline and does not cite the local ledger/run-id as required reading. **(script)** (readiness-check local-ref scan)
10. **Approved recommendation, no open fork.** The filing pass may add implementation detail but must not introduce a decision or remove ship-queue without new contradictory evidence. (filing.md frozen decision set)
11. **Second issue in a batch drops its acceptance proof.** Read-back stops the batch at that issue and records it `created_partial`; later issues stay uncreated. (filing.md create→read-back→compare)
12. **Author-input table containing a derivable response-field manifest.** Validation rejects it as agent-owned implementation work and keeps the issue queue-ready. **(script)** (readiness-check: a `ship-queue` row with a surviving `open_author_decisions` fails)
13. **Enrich an existing issue.** Verification proves the prior context remains and the new grounding is self-contained; a body replacement that silently loses earlier accepted scope fails. (filing.md semantic-section read-back)

Additional mechanical guards in `readiness-check.test.sh`: a `ship-queue` row with no `file:line` anchor, a non-runnable test command, an invalid priority/prod_status, or an unresolved placeholder all fail the gate.
