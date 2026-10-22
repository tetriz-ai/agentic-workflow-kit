#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for pr-feedback.sh with a stubbed `gh` on PATH (no network). The stub answers
# `repo view`, `pr view` and the GraphQL query with the fixture named by $FIXTURE;
# GH_FAIL=graphql makes the query fail, STUB_NO_PR=1 makes `pr view` find no PR.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/pr-feedback.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/gh" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "repo view") echo "acme/widgets"; exit 0 ;;
  "pr view")   [ -n "${STUB_NO_PR:-}" ] && { echo "no pull requests found" >&2; exit 1; }; echo 127; exit 0 ;;
  "api graphql") [ "${GH_FAIL:-}" = graphql ] && { echo "HTTP 502" >&2; exit 1; }
                 printf '\033[1;37m'; cat "$FIXTURE"; printf '\033[0m'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/gh"
export PATH="$TMP:$PATH"

# A PR with a review body, an empty-bodied approval, a resolved and an outdated unresolved
# thread, a long conversation comment, and no truncation.
cat > "$TMP/full.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"title":"feat: widgets",
 "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
   {"author":{"login":"reviewer"},"state":"CHANGES_REQUESTED","body":"Please handle the empty list.\nAlso the nil case."},
   {"author":{"login":"approver"},"state":"APPROVED","body":"  "}]},
 "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[
   {"isResolved":true,"isOutdated":false,"path":"a.go","line":3,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":11,"author":{"login":"reviewer"},"body":"done?"}]}},
   {"isResolved":false,"isOutdated":true,"path":"b.go","line":null,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":21,"author":{"login":"reviewer"},"body":"still wrong"},{"databaseId":22,"author":{"login":"author"},"body":"why?"}]}}]},
 "comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"author":{"login":"someone"},"body":"LONGBODY"}]}}}}}
JSON
long=$(printf 'x%.0s' $(seq 1 300)); sed -i.bak "s/LONGBODY/$long/" "$TMP/full.json"
# The same PR with more review threads than one page.
jq '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage = true' "$TMP/full.json" > "$TMP/trunc.json"
# The same PR with one thread whose replies run past a page.
jq '.data.repository.pullRequest.reviewThreads.nodes[1].comments.pageInfo.hasNextPage = true' "$TMP/full.json" > "$TMP/trunc-replies.json"
echo '{"errors":[{"message":"Something went wrong"}]}' > "$TMP/errors.json"
echo '{"data":{"repository":{"pullRequest":null}}}' > "$TMP/missing.json"
# The same PR with the inline-thread connection absent from the response.
jq 'del(.data.repository.pullRequest.reviewThreads)' "$TMP/full.json" > "$TMP/nothreads.json"

# Rows: name | fixture | env | args | want exit | output must contain (fixed string)
CASES=(
  "the title line names the PR and repo|full.json|||0|=== PR #127 feedback — acme/widgets — feat: widgets ==="
  "a review body is shown|full.json|||0|• @reviewer [CHANGES_REQUESTED]:"
  "a review body keeps its lines, indented|full.json|||0|    Also the nil case."
  "an empty-bodied approval is not a review body|full.json|||0|review-bodies: 1"
  "a resolved thread is labelled|full.json|||0|• a.go:3  [RESOLVED]  (reply target: id 11)"
  "an outdated unresolved thread is labelled|full.json|||0|• b.go:?  [UNRESOLVED · outdated]  (reply target: id 21)"
  "every reply in a thread is listed|full.json|||0|    @author: why?"
  "a long comment is cut with a marker|full.json|||0|… [truncated — open the comment for the rest]"
  "the summary counts each surface|full.json|||0|inline-threads: 2 (unresolved: 1) · conversation: 1"
  "the PR number comes from the branch when not given|full.json||  |0|=== PR #127"
  "truncation is called out|trunc.json|||0|this list is NOT complete"
  "a thread's truncated replies are called out|trunc-replies.json|||0|this list is NOT complete"
  "a GraphQL error response fails closed|errors.json|||1|GraphQL returned errors"
  "a missing PR fails|missing.json|||1|PR #127 not found in acme/widgets"
  "a response without a connection fails, never (none)|nothreads.json|||1|lacks: reviewThreads"
  "a failed query fails|full.json|GH_FAIL=graphql||1|GraphQL query failed"
  "no PR for the branch fails|full.json|STUB_NO_PR=1||1|no PR number"
  "a non-numeric PR fails|full.json||abc|1|PR must be a number"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name fx envs args want must <<<"$row"
  # shellcheck disable=SC2086
  out=$(env FIXTURE="$TMP/$fx" $envs bash "$SUT" $args 2>&1); rc=$?
  if [ "$rc" = "$want" ] && printf '%s\n' "$out" | grep -qF -- "$must"; then ok "$name"
  else bad "$name (exit $rc, want $want; missing [$must])"; printf '%s\n' "$out" | head -5 | sed 's/^/    /'; fi
done

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
