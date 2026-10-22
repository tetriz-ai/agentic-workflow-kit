#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for readiness-check.sh. Run: bash readiness-check.test.sh
# Deterministic - exits non-zero on any failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/readiness-check.sh"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A complete, self-contained ship-queue finding — must pass.
cat > "$TMP/good.md" <<'EOF'
finding_id: F1
title: Webhook retries are never scheduled after a delivery timeout
type: bug
github_target: new
current_code_anchors: internal/webhooks/deliver.go:scheduleRetry:142
causal_trace: a timeout returns before scheduleRetry runs, so no retry is queued and the receiver never gets the event
contrasting_guard_or_sibling: internal/webhooks/deliver.go:handleHTTPError:88 schedules the retry correctly
actor_boundary: n/a
prod_status: latent
prod_evidence_window_and_result: 0 hits over 7d (code-confirmed, retries rarely needed)
prod_confirmation_or_recheck_recipe: log query on webhook.retry_scheduled over the last 7d in prod
dedupe_and_adjacent_boundary: no-match; one atomic outcome (retry scheduling + delivery log + replay)
approved_solution: a receiver that times out gets the event on retry; schedule the retry on the timeout path
scope_in: retry scheduling, delivery log entry, replay of dropped events
scope_out: no new webhook fields, no schema change
reproduce_first_test_files: internal/webhooks/deliver_test.go
exact_test_commands: go test -run TestTimeoutSchedulesRetry ./internal/webhooks/...
rollout_backfill_migration: replay dropped events via a one-off job after deploy
done_criterion: done = TestTimeoutSchedulesRetry passes and prod logs webhook.retry_scheduled within 5m of a timeout
priority: P1
owner: janedoe
labels: type:feature, bug, bug-hunt, ship-queue
handoff: ship-queue
open_author_decisions: none
local_evidence_transfer_audit: complete
EOF

# A broken ship-queue finding — multiple content violations.
cat > "$TMP/bad.md" <<'EOF'
finding_id: F2
title: Something vague
type: bug
current_code_anchors: the sync code somewhere
causal_trace: TODO trace this properly
approved_solution: fix it
scope_in: stuff
scope_out: other stuff
exact_test_commands: verify it manually in the UI
prod_status: unknown
rollout_backfill_migration: none
done_criterion: it works
owner: janedoe
priority: high
handoff: ship-queue
open_author_decisions: which sibling should we mirror?
dedupe_and_adjacent_boundary: see .claude/triage/hunt-batch-tracker.md for details
EOF

# A non-ship-queue finding — should be skipped, not gated.
cat > "$TMP/skip.md" <<'EOF'
finding_id: F3
title: A latent improvement parked for human triage
handoff: human
open_author_decisions: whether to build this at all
EOF

# Per-field defects ONLY — no file-level placeholder/local-ref — so this isolates
# the awk field path from the file-level scans (a non-gating awk field check here
# would NOT be masked by a file-level block, unlike bad.md which also trips TODO).
cat > "$TMP/bad_fields.md" <<'EOF'
finding_id: F4
title: A ship-queue finding with only per-field defects
current_code_anchors: the sync code area
causal_trace: producer to consumer to UI
approved_solution: emit the events
scope_in: producer and consumer
scope_out: nothing else
exact_test_commands: run it and eyeball the dashboard
prod_status: unknown
rollout_backfill_migration: none
done_criterion: it works
owner: janedoe
priority: high
handoff: ship-queue
open_author_decisions: which sibling should we mirror
dedupe_and_adjacent_boundary: no-match
EOF

# Complete EXCEPT open_author_decisions is OMITTED entirely (the by-omission fork
# bypass) — must BLOCK on the missing required field, not pass green.
sed '/^open_author_decisions:/d' "$TMP/good.md" > "$TMP/omit_fork.md"

# Good, but with a TOP-LEVEL-file anchor (go.mod:12, no directory) and a
# parameterized/redacted recipe using <org_id> — both must be ACCEPTED (the
# schema mandates <param> recipes; a top-level file is a legit anchor).
sed -e 's#^current_code_anchors:.*#current_code_anchors: go.mod:12#' \
    -e 's#^prod_confirmation_or_recheck_recipe:.*#prod_confirmation_or_recheck_recipe: SELECT count(*) FROM webhook_deliveries WHERE account_id = <account_id> (account_id redacted: tenant-scoped)#' \
    "$TMP/good.md" > "$TMP/good_recipe.md"

run() { bash "$SCRIPT" "$1" >"$TMP/out" 2>&1; echo $?; }
has() { if grep -qF -- "$2" "$TMP/out"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 (missing [$2])"; echo "--- out ---"; cat "$TMP/out"; fail=$((fail+1)); fi; }

# 1. Good manifest -> READY, exit 0.
rc=$(run "$TMP/good.md")
if [ "$rc" = "0" ]; then echo "PASS: good manifest exits 0"; pass=$((pass+1)); else echo "FAIL: good exit=$rc"; cat "$TMP/out"; fail=$((fail+1)); fi
has "good -> READY" "readiness-check: READY"
has "good -> OK F1" "OK F1"

# 2. Bad manifest -> NOT READY, exit 1, with specific blockers.
rc=$(run "$TMP/bad.md")
if [ "$rc" = "1" ]; then echo "PASS: bad manifest exits 1"; pass=$((pass+1)); else echo "FAIL: bad exit=$rc"; cat "$TMP/out"; fail=$((fail+1)); fi
has "bad -> NOT READY" "readiness-check: NOT READY"
has "bad -> BLOCK F2" "BLOCK F2"
has "bad -> no code anchor" "current_code_anchors has no"
has "bad -> test not runnable" "not a runnable command"
has "bad -> invalid priority" "priority not P0|P1|P2|Parked"
has "bad -> invalid prod_status" "prod_status invalid"
has "bad -> open fork on ship-queue row" "open fork"
has "bad -> placeholder caught (file-level)" "unresolved placeholders"
has "bad -> local ref caught (file-level)" "references local/gitignored artifacts"

# 3. Non-ship-queue -> skipped, READY, exit 0.
rc=$(run "$TMP/skip.md")
if [ "$rc" = "0" ]; then echo "PASS: skip-only manifest exits 0"; pass=$((pass+1)); else echo "FAIL: skip exit=$rc"; cat "$TMP/out"; fail=$((fail+1)); fi
has "skip -> SKIP F3" "SKIP F3"

# 4. Combined (good+bad+skip) -> NOT READY (bad drags it down), exit 1.
cat "$TMP/good.md" "$TMP/bad.md" "$TMP/skip.md" > "$TMP/all.md"
rc=$(run "$TMP/all.md")
if [ "$rc" = "1" ]; then echo "PASS: combined exits 1"; pass=$((pass+1)); else echo "FAIL: combined exit=$rc"; cat "$TMP/out"; fail=$((fail+1)); fi
has "combined -> OK F1 still recognized" "OK F1"
has "combined -> BLOCK F2" "BLOCK F2"
has "combined -> SKIP F3" "SKIP F3"

# 5. Missing file -> exit 2.
rc=$(run "$TMP/nope.md")
if [ "$rc" = "2" ]; then echo "PASS: missing file exits 2"; pass=$((pass+1)); else echo "FAIL: missing exit=$rc"; fail=$((fail+1)); fi

# 6. Per-field-only defects -> exit 1 via the awk path (no file-level trigger).
rc=$(run "$TMP/bad_fields.md")
if [ "$rc" = "1" ]; then echo "PASS: bad_fields exits 1 (awk path gates alone)"; pass=$((pass+1)); else echo "FAIL: bad_fields exit=$rc"; cat "$TMP/out"; fail=$((fail+1)); fi
has "bad_fields not masked by file-level" "BLOCK F4"

# 7. CRLF line endings must NOT defeat gating (the trim() \r bug).
sed 's/$/\r/' "$TMP/bad_fields.md" > "$TMP/crlf.md"
rc=$(run "$TMP/crlf.md")
if [ "$rc" = "1" ]; then echo "PASS: CRLF manifest still exits 1 (not skipped)"; pass=$((pass+1)); else echo "FAIL: CRLF exit=$rc (non-gating!)"; cat "$TMP/out"; fail=$((fail+1)); fi
has "CRLF -> checked, not SKIP" "BLOCK F4"

# 8. Empty file and no-finding_id file -> parse error exit 2 (never silent READY).
: > "$TMP/empty.md"
rc=$(run "$TMP/empty.md")
if [ "$rc" = "2" ]; then echo "PASS: empty file exits 2 (parse error)"; pass=$((pass+1)); else echo "FAIL: empty exit=$rc"; cat "$TMP/out"; fail=$((fail+1)); fi
printf 'title: no finding_id here\nhandoff: ship-queue\n' > "$TMP/noid.md"
rc=$(run "$TMP/noid.md")
if [ "$rc" = "2" ]; then echo "PASS: no-finding_id file exits 2 (parse error)"; pass=$((pass+1)); else echo "FAIL: noid exit=$rc"; cat "$TMP/out"; fail=$((fail+1)); fi

# 9. Omitted open_author_decisions on a ship-queue row -> BLOCK (no bypass).
rc=$(run "$TMP/omit_fork.md")
if [ "$rc" = "1" ]; then echo "PASS: omitted open_author_decisions blocks"; pass=$((pass+1)); else echo "FAIL: omit_fork exit=$rc"; cat "$TMP/out"; fail=$((fail+1)); fi
has "omit_fork -> missing field" "missing/empty field: open_author_decisions"

# 10. Top-level anchor + parameterized recipe -> still READY (no false blocks).
rc=$(run "$TMP/good_recipe.md")
if [ "$rc" = "0" ]; then echo "PASS: top-level anchor + <param> recipe stays READY"; pass=$((pass+1)); else echo "FAIL: good_recipe exit=$rc"; cat "$TMP/out"; fail=$((fail+1)); fi

# 11. Extension-less file reached via a path (Dockerfile) is a valid anchor.
sed 's#^current_code_anchors:.*#current_code_anchors: build/app/Dockerfile:5#' "$TMP/good.md" > "$TMP/good_dockerfile.md"
rc=$(run "$TMP/good_dockerfile.md")
if [ "$rc" = "0" ]; then echo "PASS: extension-less path anchor (Dockerfile:5) stays READY"; pass=$((pass+1)); else echo "FAIL: good_dockerfile exit=$rc"; cat "$TMP/out"; fail=$((fail+1)); fi

# 12. Every mandatory grounding field is required — omission blocks (one per field).
for fld in actor_boundary prod_evidence_window_and_result prod_confirmation_or_recheck_recipe reproduce_first_test_files labels local_evidence_transfer_audit; do
  sed "/^${fld}:/d" "$TMP/good.md" > "$TMP/omit_${fld}.md"
  rc=$(run "$TMP/omit_${fld}.md")
  if [ "$rc" = "1" ] && grep -qF "missing/empty field: ${fld}" "$TMP/out"; then
    echo "PASS: omitting mandatory field '${fld}' blocks"; pass=$((pass+1))
  else echo "FAIL: omitting '${fld}' did not block (exit=$rc)"; cat "$TMP/out"; fail=$((fail+1)); fi
done

# 13. A command run from a named working dir is runnable; the word "placeholder" in
#     prose is not a fill-in; type, github_target and contrasting_guard_or_sibling are checked.
# Rows: name | sed edit applied to good.md | want exit | must appear in the output (blank: none)
CASES=(
  "cd <dir> && <runner> is runnable|s#^exact_test_commands:.*#exact_test_commands: cd server \&\& go test ./...#|0|"
  "cd <dir> && prose is still not runnable|s#^exact_test_commands:.*#exact_test_commands: cd server \&\& look at it#|1|not a runnable command"
  "the word placeholder in prose is not a fill-in|s#^title:.*#title: Search placeholder text renders twice#|0|"
  "a <placeholder> token is still a fill-in|s#^scope_out:.*#scope_out: <placeholder>#|1|unresolved placeholders"
  "a missing type blocks|/^type:/d|1|missing/empty field: type"
  "an invalid type blocks|s#^type:.*#type: chore#|1|type not bug|improvement|doubt-resolved"
  "a missing github_target blocks|/^github_target:/d|1|missing/empty field: github_target"
  "an existing-#N github_target is valid|s@^github_target:.*@github_target: existing-#127@|0|"
  "an invalid github_target blocks|s#^github_target:.*#github_target: maybe#|1|github_target not new|existing-#N"
  "a missing contrasting_guard_or_sibling blocks|/^contrasting_guard_or_sibling:/d|1|missing/empty field: contrasting_guard_or_sibling"
  "a blank finding_id blocks|s#^finding_id:.*#finding_id:#|1|finding_id is empty"
  "a missing handoff blocks|/^handoff:/d|1|handoff is missing"
  "an unknown handoff blocks|s#^handoff:.*#handoff: someday#|1|unknown handoff [someday]"
  "a handoff in the wrong case blocks with a hint|s#^handoff:.*#handoff: Ship-Queue#|1|did you mean ship-queue"
  "another known handoff is skipped|s#^handoff:.*#handoff: human#|0|SKIP"
)
n=0
for row in "${CASES[@]}"; do
  n=$((n + 1))
  name=${row%%|*}; rest=${row#*|}; edit=${rest%%|*}; rest=${rest#*|}; want=${rest%%|*}; must=${rest#*|}
  sed -e "$edit" "$TMP/good.md" > "$TMP/q8_$n.md"
  rc=$(run "$TMP/q8_$n.md")
  if [ "$rc" = "$want" ] && { [ -z "$must" ] || grep -qF -- "$must" "$TMP/out"; }; then
    echo "PASS: $name"; pass=$((pass+1))
  else echo "FAIL: $name (exit=$rc, want $want${must:+, want [$must]})"; cat "$TMP/out"; fail=$((fail+1)); fi
done

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
