#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Runs the review panel's lens selector over the fixture branch's changed paths.
set -uo pipefail
DIR="$1"; KIT="$(cd "$(dirname "$0")/../.." && pwd)"; REPO="$DIR/repo"
SEL="$KIT/plugins/review/scripts/select-lenses.sh"; LENSES="$KIT/plugins/review-lenses/lenses"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
pick() { (cd "$REPO" && bash "$SEL" --changed "$DIR/changed" "$LENSES" .claude/review-lenses 2>/dev/null) | while IFS= read -r f; do basename "$f" .md; done | sort | tr '\n' ' '; }

git -C "$REPO" diff --name-only main > "$DIR/changed"
got=$(pick)
case " $got" in *" database-migrations "*) ok "the migration selects database-migrations" ;; *) bad "no database lens: [$got]" ;; esac
case " $got" in *" billing "*) ok "the billing handler selects the team's billing lens" ;; *) bad "no team lens: [$got]" ;; esac
case " $got" in *" architecture-rules "*) bad "architecture-rules offered with no rules document: [$got]" ;; *) ok "architecture-rules is not offered while its setting is blank" ;; esac
printf '{"architecture_rules_file":"docs/architecture.md"}\n' > "$REPO/.agentic-workflow-kit.json"
got=$(pick)
case " $got" in *" architecture-rules "*) ok "architecture-rules is offered once the setting names a document" ;; *) bad "no architecture lens after the setting: [$got]" ;; esac
echo README.md > "$DIR/changed"; rm "$REPO/.agentic-workflow-kit.json"
got=$(pick)
[ -z "$got" ] && ok "a README-only change selects no domain lens" || bad "README selected [$got]"
printf -- '---\nlens: broken\nsummary: "no globs"\n---\n' > "$REPO/.claude/review-lenses/broken.md"
(cd "$REPO" && bash "$SEL" --changed "$DIR/changed" "$LENSES" .claude/review-lenses >/dev/null 2>"$DIR/err"); rc=$?
[ "$rc" = 2 ] && grep -q broken.md "$DIR/err" && ok "a lens with no applies-to stops the selector and names the file" || bad "broken lens (exit $rc)"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
