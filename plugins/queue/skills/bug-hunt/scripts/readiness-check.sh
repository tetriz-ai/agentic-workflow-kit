#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# readiness-check.sh — the pre-author-gate / pre-filing readiness gate for
# /queue:bug-hunt. It fails the review handoff unless every `ship-queue`-bound finding
# in the canonical evidence manifest is a COMPLETE, well-formed executable draft
# (bug-hunt evidence-manifest.md + filing.md).
#
# Scope, stated honestly: this is a FORMAT + COMPLETENESS lint over the agent's
# own manifest — it checks that the required cells are present and well-shaped (a
# real file:line-shaped anchor, a command-shaped test line, a resolved fork, no
# gitignored/placeholder text). It deliberately does NOT verify that an anchor
# points at real code or that the test actually exists/passes — binding a claim to
# reality stays the agent's grounded duty (filing.md's drift check) and the human
# author gate. So it catches the mechanical omissions that leave a finding thin,
# not a fabricated-but-well-formed claim.
#
# Usage:  readiness-check.sh <manifest-file>
# The manifest holds one or more finding records; a record starts at a
# `finding_id:` line (col 0) and runs to the next `finding_id:` / EOF. Fields are
# `key: value` (one logical line each — the manifest is the structured summary;
# full prose lives in the rendered issue body).
#
# Exit 0 = every ship-queue finding is ready. Exit 1 = at least one is not (each
# blocker printed with the offending finding + field). Exit 2 = usage/IO/parse
# error (incl. a manifest with zero parseable finding records — never a silent
# pass). Findings with another known handoff (human, activation, none) are reported skipped; a
# blank finding_id, a missing handoff or an unknown one is a BLOCK.
set -uo pipefail

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "readiness-check: manifest file not found: '${FILE:-<none>}'" >&2
  exit 2
fi

fails=0

# ---- File-level scans (a violation anywhere fails the manifest) ----------------
# Command substitution, not a temp file: a shared /tmp path both races concurrent
# session-id-named hunts and, if the redirect ever failed, silently skipped the
# scan (a non-gating gap). Local / gitignored artifacts an assignee on GitHub
# cannot open must be summarized inline, never cited. (The manifest's own
# hunt-manifest-<session>.md filename and session-id stamp are NOT matched — the
# concern is citing another local artifact as required reading.)
if refs=$(grep -nE '\.claude/triage|hunt-(run|batch)-|(^|[^A-Za-z0-9])~/' "$FILE"); then
  echo "BLOCK: manifest references local/gitignored artifacts (summarize inline, do not cite):"
  printf '%s\n' "$refs" | sed 's/^/  /'
  fails=$((fails + 1))
fi
# Unresolved fill-in placeholders: a draft with TODO/<fill> is not executable.
# Deliberately narrow — the schema MANDATES <param>-style sanitized query recipes
# for tenant-sensitive predicates, so a bare <token> must NOT trip this; only
# explicit fill-in words/tokens do.
# The word "placeholder" itself only counts in a fill-in token (`<placeholder>`,
# `[placeholder]`), since a finding may be about placeholder text.
if ph=$(grep -nEi '\bTODO\b|\bTBD\b|\bFIXME\b|<placeholder[^>]*>|\[placeholder\]|<fill[^>]*>|<your-[^>]*>|<TODO[^>]*>|<\.\.\.>' "$FILE"); then
  echo "BLOCK: manifest has unresolved placeholders:"
  printf '%s\n' "$ph" | sed 's/^/  /'
  fails=$((fails + 1))
fi

# ---- Per-record field + content checks (awk splits records on finding_id:) -----
# One awk pass: it prints CHECK/OK/BLOCK/SKIP + "  - reason" lines, and trailing
# "FAILS n" / "RECORDS n" sentinels this script parses.
awk_out="$(awk '
  function trim(s){ gsub(/\r/,"",s); sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
  function val(k){ return (k in F) ? F[k] : "" }
  function need(k,  v){ v=val(k); if (v=="") { print "  - missing/empty field: " k; nf++ } return v }
  function check_record(  lh){
    if (!started) return
    if (fid=="") { print "BLOCK <blank finding_id> (record " REC ")"; print "  - finding_id is empty"; TOTAL++; return }
    hand=val("handoff"); lh=tolower(hand)
    if (hand=="") { print "BLOCK " fid " (handoff missing)"; print "  - handoff is missing: ship-queue | human | activation | none"; TOTAL++; return }
    if (hand !~ /^(ship-queue|human|activation|none)$/) {
      print "BLOCK " fid " (handoff=" hand ")"
      if (lh ~ /^(ship-queue|human|activation|none)$/) print "  - unknown handoff [" hand "]: did you mean " lh "?"
      else print "  - unknown handoff [" hand "]: ship-queue | human | activation | none"
      TOTAL++; return
    }
    if (hand != "ship-queue") { print "SKIP " fid " (handoff=" hand ")"; return }
    print "CHECK " fid; nf=0
    # Every grounding-bearing field evidence-manifest.md declares mandatory — a
    # subset check let a thin, non-reproducible draft print OK (missing prod
    # evidence, recipe, repro files, labels, transfer audit).
    need("title"); need("causal_trace"); need("approved_solution")
    need("scope_in"); need("scope_out"); need("done_criterion")
    need("dedupe_and_adjacent_boundary"); need("rollout_backfill_migration"); need("owner")
    need("actor_boundary"); need("prod_evidence_window_and_result")
    need("prod_confirmation_or_recheck_recipe"); need("reproduce_first_test_files")
    need("labels"); need("local_evidence_transfer_audit"); need("contrasting_guard_or_sibling")
    ty=need("type");          if (ty!="" && ty !~ /^(bug|improvement|doubt-resolved)$/) { print "  - type not bug|improvement|doubt-resolved: [" ty "]"; nf++ }
    gt=need("github_target"); if (gt!="" && gt !~ /^(new|existing-#[0-9]+)$/) { print "  - github_target not new|existing-#N: [" gt "]"; nf++ }
    # code anchors: >=1 file:line-or-symbol where the file token carries a "." or
    # "/" — so a dotted file (path/x.go:142, go.mod:12) AND an extension-less file
    # reached via a path (build/Dockerfile:5, ./Makefile:12) both pass,
    # while a bare prose word without either does not. A completeness lint favours
    # recall here — a garbage anchor value is for the author gate to catch, but a
    # legit anchor must never be blocked.
    a=need("current_code_anchors")
    if (a!="" && a !~ /[A-Za-z0-9_\/.-]*[\/.][A-Za-z0-9_\/.-]*:[0-9A-Za-z_]/) { print "  - current_code_anchors has no file:line/symbol anchor: [" a "]"; nf++ }
    # runnable test command: the value must START with a known runner, so a prose
    # line that merely mentions "go test" somewhere does not pass.
    # A named working dir first (`cd <dir> && <runner> ...`) is allowed: the schema asks for
    # a command runnable from a named working dir.
    t=need("exact_test_commands"); tc=t; sub(/^cd [^ ]+ && /, "", tc)
    if (t!="" && tc !~ /^(go (test|run)|grpcurl|make |bash |pnpm |npm |psql|\.\/|cargo |python |dlv )/) { print "  - exact_test_commands is not a runnable command: [" t "]"; nf++ }
    # enum fields (both fully end-anchored)
    p=need("priority");     if (p!="" && p !~ /^(P0|P1|P2|Parked)$/) { print "  - priority not P0|P1|P2|Parked: [" p "]"; nf++ }
    ps=need("prod_status"); if (ps!="" && ps !~ /^(active|latent|not-log-visible|dormant)$/) { print "  - prod_status invalid: [" ps "]"; nf++ }
    # no open author decision may survive on a ship-queue row — REQUIRED, so an
    # omitted field is itself a block (an unresolved fork cannot hide by omission).
    d=need("open_author_decisions")
    if (d!="" && d !~ /^(none|\[\]|-)$/) { print "  - open_author_decisions must be none/[] on a ship-queue row (an open fork): [" d "]"; nf++ }
    if (nf>0) { print "BLOCK " fid " (" nf " issue(s))"; TOTAL+=nf } else print "OK " fid
  }
  /^finding_id:/ { check_record(); delete F; REC++; started=1; fid=trim(substr($0,index($0,":")+1)); next }
  /^[A-Za-z0-9_]+:/ { k=substr($0,1,index($0,":")-1); F[k]=trim(substr($0,index($0,":")+1)); next }
  END { check_record(); print "FAILS " TOTAL+0; print "RECORDS " REC+0 }
' "$FILE")"

printf '%s\n' "$awk_out" | grep -vE '^(FAILS|RECORDS) '
awk_total="$(printf '%s\n' "$awk_out" | awk '/^FAILS /{print $2}')"
records="$(printf '%s\n' "$awk_out"  | awk '/^RECORDS /{print $2}')"

echo "----"
# Zero parseable records is a parse error, never a silent pass (empty file, wrong
# separator, truncation, format drift).
if [ "${records:-0}" -eq 0 ]; then
  echo "readiness-check: PARSE ERROR (no 'finding_id:' records found in $FILE)"
  exit 2
fi
if [ "$fails" -gt 0 ] || [ "${awk_total:-0}" -gt 0 ]; then
  echo "readiness-check: NOT READY (file-level blocks: $fails, ship-queue field blocks: ${awk_total:-0})"
  exit 1
fi
echo "readiness-check: READY (all ship-queue findings well-formed and self-contained)"
exit 0
