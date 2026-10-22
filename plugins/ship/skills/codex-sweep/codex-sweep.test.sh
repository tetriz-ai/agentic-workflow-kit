#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Tests for codex-sweep.sh — runs with a STUBBED `gh` on PATH (no network). Covers
# the full state signal (present / done-replied / done-reviewed / done-clean /
# analyzing / absent, plus the codex-limited usage-cap override) driven by Codex's
# reviews, threads and PR-body reaction, the Codex-only filtering (login AND __typename==Bot in
# reviews/threads; [bot]-suffix + no-typename in reactions), the mixed-author
# guard, Bot-spoof and empty-comments guards, truncation, and that no thread is resolved.
# Deterministic; no real PR needed.

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/codex-sweep.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   — %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL — %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; }

# --- gh stub --------------------------------------------------------------
# `gh repo view` -> slug; `gh api user` -> the acting login (so the mixed-author
# guard has a "me"); a resolveReviewThread mutation is logged (+ a stderr warning,
# proving it does not poison the stdout parse) and answered ok; any other graphql
# call emits the fixture named by $FIXTURE.
STUB=$(mktemp -d)
cat > "$STUB/gh" <<'STUB_EOF'
#!/bin/bash
case "$*" in
  "repo view"*) echo "acme/widgets"; exit 0 ;;
  "api user"*)  [ -n "${STUB_NO_USER:-}" ] && { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }; echo "tester"; exit 0 ;;
  "pr view"*)   if [ -n "${STUB_NO_PR:-}" ]; then echo "no pull requests found for branch" >&2; exit 1; fi ;;
esac
q=""
for a in "$@"; do [[ "$a" == query=* ]] && q="${a#query=}"; done
if [[ "$q" == *resolveReviewThread* ]]; then
  echo "MUTATION_SENT: $*" >> "$MUT_LOG"
  echo "warning: a harmless gh stderr line" >&2
  echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
  exit 0
fi
# Failure injection for the `await` transient-retry tests only: when
# AWAIT_FAIL_FIRST is set, the first N graphql calls exit non-zero (a simulated
# network/rate-limit blip → cmd_fetch returns non-zero). Inert when unset.
if [ -n "${AWAIT_FAIL_FIRST:-}" ]; then
  fc=$(( $(cat "$AWAIT_FAIL_FILE" 2>/dev/null || echo 0) + 1 )); echo "$fc" > "$AWAIT_FAIL_FILE"
  [ "$fc" -le "$AWAIT_FAIL_FIRST" ] && { echo "simulated gh graphql failure" >&2; exit 1; }
fi
# Transition support for the `await` tests only: when AWAIT_COUNTER is set, count
# graphql calls and, once the count reaches AWAIT_SWITCH_AT, emit FIXTURE2 instead
# of FIXTURE (simulates Codex posting mid-wait: analyzing → present). Inert whenever
# AWAIT_COUNTER is unset, so the fetch tests are unaffected.
if [ -n "${AWAIT_COUNTER:-}" ]; then
  n=$(( $(cat "$AWAIT_COUNTER" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$AWAIT_COUNTER"
  if [ -n "${AWAIT_SWITCH_AT:-}" ] && [ "$n" -ge "$AWAIT_SWITCH_AT" ] && [ -n "${FIXTURE2:-}" ]; then
    cat "$FIXTURE2"; exit 0
  fi
fi
# Page-size simulation for the conversation-comments connection (the many-comments row only): serve the
# fixture's comments the way GitHub would for the page the query asks for.
if [ -n "${STUB_PAGE_COMMENTS:-}" ]; then
  # `last:` first: the review threads' own `comments(first:30)` would match a `first:` test.
  if [[ "$q" =~ comments\(last:([0-9]+)\) ]]; then n=${BASH_REMATCH[1]}
    jq -c --argjson n "$n" '.data.repository.pullRequest.comments.nodes |= .[-$n:]' "$FIXTURE"; exit 0
  elif [[ "$q" =~ comments\(first:([0-9]+)\) ]]; then n=${BASH_REMATCH[1]}
    jq -c --argjson n "$n" '.data.repository.pullRequest.comments.nodes |= .[:$n]' "$FIXTURE"; exit 0
  fi
fi
cat "$FIXTURE"
STUB_EOF
chmod +x "$STUB/gh"
export PATH="$STUB:$PATH"
export MUT_LOG="$STUB/mutations.log"; : > "$MUT_LOG"

# --- fixtures -------------------------------------------------------------
# PRESENT: a pure Codex unresolved thread + one with OUR reply (still eligible) +
# a MIXED one (Codex root + third-party human reply → surface only) + a resolved
# Codex thread + a human thread + a Bot-spoof (login=codex,type=User) + an empty
# thread. EYES reaction is present too, to prove real findings outrank the reaction.
FX_PRESENT=$(mktemp)
cat > "$FX_PRESENT" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing",
  "reactionGroups":[{"content":"EYES","users":{"nodes":[{"login":"chatgpt-codex-connector[bot]"}]}}],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"state":"COMMENTED","body":"### 💡 Codex Review\nFound an off-by-one."},
    {"author":{"login":"janedoe","__typename":"User"},"state":"COMMENTED","body":""}
  ]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"id":"PRRT_codexUnresolved","isResolved":false,"isOutdated":false,"path":"a.go","line":12,
      "comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":111,"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"body":"nil deref here"}]}},
    {"id":"PRRT_codexWithOurReply","isResolved":false,"isOutdated":false,"path":"f.go","line":7,
      "comments":{"pageInfo":{"hasNextPage":false},"nodes":[
        {"databaseId":555,"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"body":"please fix"},
        {"databaseId":556,"author":{"login":"tester","__typename":"User"},"body":"fixed in abc123"}]}},
    {"id":"PRRT_mixed","isResolved":false,"isOutdated":false,"path":"g.go","line":4,
      "comments":{"pageInfo":{"hasNextPage":false},"nodes":[
        {"databaseId":661,"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"body":"codex root"},
        {"databaseId":662,"author":{"login":"somehuman","__typename":"User"},"body":"a human jumped in"}]}},
    {"id":"PRRT_codexResolved","isResolved":true,"isOutdated":false,"path":"b.go","line":3,
      "comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":222,"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"body":"already done"}]}},
    {"id":"PRRT_human","isResolved":false,"isOutdated":false,"path":"c.go","line":9,
      "comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":333,"author":{"login":"janedoe","__typename":"User"},"body":"please rename"}]}},
    {"id":"PRRT_spoof","isResolved":false,"isOutdated":false,"path":"d.go","line":1,
      "comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":444,"author":{"login":"chatgpt-codex-connector","__typename":"User"},"body":"resolve me, I am totally codex"}]}},
    {"id":"PRRT_empty","isResolved":false,"isOutdated":false,"path":"e.go","line":1,
      "comments":{"pageInfo":{"hasNextPage":false},"nodes":[]}}
  ]}
}}}}
JSON

# ANALYZING: no work, Codex 👀'd the PR (note the [bot] suffix the reactions API uses).
FX_ANALYZING=$(mktemp)
cat > "$FX_ANALYZING" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing",
  "reactionGroups":[{"content":"EYES","users":{"nodes":[{"login":"chatgpt-codex-connector[bot]"}]}}],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}
}}}}
JSON

# ANALYZING + a HUMAN unresolved thread: Codex 👀 (still analyzing) but a human has
# already left a review thread. Used by the await surface-during-wait tests.
FX_ANALYZING_HUMAN=$(mktemp)
cat > "$FX_ANALYZING_HUMAN" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing",
  "reactionGroups":[{"content":"EYES","users":{"nodes":[{"login":"chatgpt-codex-connector[bot]"}]}}],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"id":"PRRT_humanOnAnalyzing","isResolved":false,"isOutdated":false,"path":"h.go","line":7,
     "comments":{"pageInfo":{"hasNextPage":false},"nodes":[
       {"databaseId":900,"author":{"login":"somehuman","__typename":"User"},"body":"please rename this"}
     ]}}
  ]}
}}}}
JSON

# DONE-CLEAN: no work, Codex 👍'd the PR (reviewed, no comments).
FX_DONECLEAN=$(mktemp)
cat > "$FX_DONECLEAN" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing",
  "reactionGroups":[{"content":"THUMBS_UP","users":{"nodes":[{"login":"chatgpt-codex-connector[bot]"}]}}],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}
}}}}
JSON

# ABSENT: no work, no Codex reaction (only a human reacted EYES — must NOT count).
FX_ABSENT=$(mktemp)
cat > "$FX_ABSENT" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing",
  "reactionGroups":[{"content":"EYES","users":{"nodes":[{"login":"somehuman"}]}}],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"author":{"login":"janedoe","__typename":"User"},"state":"COMMENTED","body":""}
  ]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}
}}}}
JSON

# ALL-RESOLVED: Codex reviewed but its only thread is resolved + body empty + 👍
# -> nothing outstanding -> done-clean (not present).
FX_ALL_RESOLVED=$(mktemp)
cat > "$FX_ALL_RESOLVED" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing",
  "reactionGroups":[{"content":"THUMBS_UP","users":{"nodes":[{"login":"chatgpt-codex-connector[bot]"}]}}],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"state":"COMMENTED","body":"  "}
  ]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"id":"PRRT_done","isResolved":true,"isOutdated":false,"path":"a.go","line":1,
      "comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":999,"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"body":"fixed already"}]}}
  ]}
}}}}
JSON

# DONE-REVIEWED: Codex posted a real (non-empty) review body, every thread is now
# resolved, and the 👀 is gone (Codex removes it once it posts). The leftover body
# must NOT keep the PR "present" — this is the post-sweep steady state.
FX_DONE_REVIEWED=$(mktemp)
cat > "$FX_DONE_REVIEWED" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing","reactionGroups":[],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"state":"COMMENTED","body":"### 💡 Codex Review\nsuggestions follow"}
  ]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"id":"PRRT_done","isResolved":true,"isOutdated":false,"path":"a.go","line":1,
      "comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":999,"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"body":"was here"}]}}
  ]}
}}}}
JSON

# DONE-REPLIED: a pure Codex thread remains UNRESOLVED but already carries our
# reply (login=tester) → addressed, awaiting the author's resolve. Must read
# done-replied, NOT present (which would loop forever).
FX_DONE_REPLIED=$(mktemp)
cat > "$FX_DONE_REPLIED" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing","state":"OPEN","reactionGroups":[],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"id":"PRRT_replied","isResolved":false,"isOutdated":true,"path":"a.go","line":1,
      "comments":{"pageInfo":{"hasNextPage":false},"nodes":[
        {"databaseId":701,"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"body":"fix this"},
        {"databaseId":702,"author":{"login":"tester","__typename":"User"},"body":"fixed in abc123"}]}}
  ]}
}}}}
JSON

# MERGED / CLOSED: a non-open PR stops the sweep regardless of any open Codex
# thread (here one is still unresolved + unreplied, which would otherwise be
# `present`) — the PR-state guard outranks every Codex signal.
FX_MERGED=$(mktemp)
cat > "$FX_MERGED" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing","state":"MERGED","reactionGroups":[],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"id":"PRRT_open","isResolved":false,"isOutdated":false,"path":"a.go","line":1,
      "comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":801,"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"body":"unaddressed"}]}}
  ]}
}}}}
JSON
FX_CLOSED=$(mktemp)
sed 's/"state":"MERGED"/"state":"CLOSED"/' "$FX_MERGED" > "$FX_CLOSED"

# TRUNCATED: a surface reports hasNextPage.
FX_TRUNC=$(mktemp)
cat > "$FX_TRUNC" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing","reactionGroups":[],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
  "reviewThreads":{"pageInfo":{"hasNextPage":true},"nodes":[]}
}}}}
JSON

# CODEX-LIMITED via a REVIEW BODY: a MANUAL `@codex review` that
# rate-limits posts its cap notice in a review BODY, not a top-level comment, and
# drops a 👀. The cap body must NOT count as a real review (else done-reviewed) — it
# resolves to codex-limited so the bounded wait terminates instead of merging on a
# phantom "reviewed".
FX_CAP_REVIEW_BODY=$(mktemp)
cat > "$FX_CAP_REVIEW_BODY" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing",
  "reactionGroups":[{"content":"EYES","users":{"nodes":[{"login":"chatgpt-codex-connector[bot]"}]}}],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"state":"COMMENTED","body":"You have reached your Codex usage limits for code reviews. Try again later."}
  ]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}
}}}}
JSON

# CODEX-LIMITED via a TOP-LEVEL COMMENT (the AUTO-review cap path): cap notice in a
# comment + a 👀 → codex-limited.
FX_CAP_COMMENT=$(mktemp)
cat > "$FX_CAP_COMMENT" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing",
  "reactionGroups":[{"content":"EYES","users":{"nodes":[{"login":"chatgpt-codex-connector[bot]"}]}}],
  "comments":{"nodes":[
    {"author":{"login":"chatgpt-codex-connector[bot]","__typename":"User"},"body":"You have reached your Codex usage limits for code reviews."}
  ]},
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}
}}}}
JSON

# CODEX-LIMITED via the REPO-WIDE credits-exhausted notice — a DIFFERENT wording from
# the per-request cap ("Codex usage limits have been reached for code reviews…"), which
# the predicate must also catch. Without it a repo-wide-capped PR reads `absent` and the
# await loop spins to wait-exhausted instead of stopping at codex-limited. Delivered as
# a top-level comment + a 👀.
FX_CAP_REPO_WIDE=$(mktemp)
cat > "$FX_CAP_REPO_WIDE" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing",
  "reactionGroups":[{"content":"EYES","users":{"nodes":[{"login":"chatgpt-codex-connector[bot]"}]}}],
  "comments":{"nodes":[
    {"author":{"login":"chatgpt-codex-connector[bot]","__typename":"User"},"body":"Codex usage limits have been reached for code reviews. Please check with the admins of this repo to increase the limits by adding credits. Credits must be used to enable repository wide code reviews."}
  ]},
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}
}}}}
JSON

# REAL REVIEW WINS over an earlier cap: a genuine non-cap review body alongside a
# cap-notice review body must read done-reviewed (the real review counts in $rb;
# codex-limited overrides only analyzing/absent, never a real engagement).
FX_CAP_PLUS_REAL=$(mktemp)
cat > "$FX_CAP_PLUS_REAL" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing","reactionGroups":[],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"state":"COMMENTED","body":"You have reached your Codex usage limits for code reviews."},
    {"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"state":"COMMENTED","body":"### 💡 Codex Review\nFound a real issue."}
  ]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}
}}}}
JSON

# FALSE-POSITIVE GUARD: a GENUINE Codex review whose prose merely mentions "usage
# limit" (a real rate-limit/quota finding) is NOT a cap notice — it must count as a
# real review (done-reviewed), never be discarded as codex-limited. This is why the
# cap predicate is anchored on "reached your Codex usage limit", not the bare words.
FX_REAL_REVIEW_MENTIONS_CAP=$(mktemp)
cat > "$FX_REAL_REVIEW_MENTIONS_CAP" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing","reactionGroups":[],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"state":"COMMENTED","body":"### 💡 Codex Review\nThe endpoint does not enforce any usage limit on the API key; add rate limiting."}
  ]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}
}}}}
JSON

# CODEX-LIMITED via a review body with NO reaction (absent→codex-limited branch):
# the comment path's absent branch is covered by the no-reaction comment case; this
# pins the same branch for the review-body surface.
FX_CAP_REVIEW_BODY_NO_REACTION=$(mktemp)
cat > "$FX_CAP_REVIEW_BODY_NO_REACTION" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing","reactionGroups":[],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"state":"COMMENTED","body":"You have reached your Codex usage limits for code reviews."}
  ]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}
}}}}
JSON

# FALSE-POSITIVE GUARD #2 — a genuine review that QUOTES the cap boilerplate on a
# later line (e.g. a review OF codex-sweep itself) must NOT be misread as a cap: the
# start-anchor keeps the match to the first line, so a header-led review stays
# done-reviewed. This is the residual a bare-substring anchor would still miss.
FX_REVIEW_QUOTES_CAP=$(mktemp)
cat > "$FX_REVIEW_QUOTES_CAP" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing","reactionGroups":[],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"state":"COMMENTED","body":"### 💡 Codex Review\nThe new fixture quotes \"You have reached your Codex usage limits for code reviews.\" but the gate still merges on cap — confirm the predicate is anchored."}
  ]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}
}}}}
JSON

# FALSE-POSITIVE GUARD #3 — the phrase-2 counterpart: a genuine header-led review that
# QUOTES the repo-wide boilerplate on a later line (e.g. a review OF this very change)
# must stay done-reviewed. The broadened alternative leans harder on the start-anchor,
# so pin that it still holds for the repo-wide wording.
FX_REPO_WIDE_QUOTED=$(mktemp)
cat > "$FX_REPO_WIDE_QUOTED" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "title":"feat: thing","reactionGroups":[],
  "reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"author":{"login":"chatgpt-codex-connector","__typename":"Bot"},"state":"COMMENTED","body":"### 💡 Codex Review\nThis broadens cap_re to also match \"Codex usage limits have been reached for code reviews\" — confirm the start-anchor still rejects this quote."}
  ]},
  "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}
}}}}
JSON

# --- fetch: present (findings outrank a co-present EYES reaction) ----------
export FIXTURE="$FX_PRESENT"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: present' && ok "present: findings outrank the EYES reaction" || bad "present signal" "$OUT"
echo "$OUT" | grep -q 'thread-id: PRRT_codexUnresolved' && ok "surfaces pure Codex thread node id" || bad "pure Codex thread surfaced"
echo "$OUT" | grep -q 'thread-id: PRRT_codexWithOurReply' && ok "Codex thread with OUR reply stays resolve-eligible" || bad "our-reply thread eligible"
echo "$OUT" | grep -q 'reply-target: 111' && ok "surfaces reply-target (root databaseId)" || bad "surfaces reply-target"
echo "$OUT" | grep -q 'PRRT_codexResolved' && bad "RESOLVED Codex thread should be skipped" || ok "skips already-resolved Codex thread"
# Mixed thread: Codex root + human reply -> MIXED bucket, NOT a resolve target.
echo "$OUT" | grep -q 'thread-id: PRRT_mixed' && bad "mixed thread must NOT be a resolve target" || ok "mixed thread is not a resolve target"
echo "$OUT" | grep -q 'Codex thread with a human reply' && ok "mixed thread surfaced read-only" || bad "mixed thread surfaced" "$OUT"
echo "$OUT" | grep -q 'g.go:4' && ok "mixed thread shows its location" || bad "mixed thread location"
# Human / spoof / empty.
echo "$OUT" | grep -q 'DO NOT auto-resolve' && ok "human thread surfaced read-only" || bad "human surfaced" "$OUT"
echo "$OUT" | grep -q 'thread-id: PRRT_human' && bad "human thread must NOT be a resolve target" || ok "human thread is not a resolve target"
echo "$OUT" | grep -q 'thread-id: PRRT_spoof' && bad "Bot-spoof must NOT be a resolve target" || ok "Bot-spoof is not auto-resolved"
echo "$OUT" | grep -q 'PRRT_empty' && bad "empty-comments thread must appear in no bucket" || ok "empty-comments thread dropped"
echo "$OUT" | grep -q '@null' && bad "empty-comments thread leaked a @null author" || ok "no @null attribution"

# --- fetch: analyzing / done-clean / absent (reaction-driven) -------------
export FIXTURE="$FX_ANALYZING"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: analyzing' && ok "analyzing: Codex 👀 with no findings (and [bot]-suffix matched)" || bad "analyzing state" "$OUT"

export FIXTURE="$FX_DONECLEAN"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: done-clean' && ok "done-clean: Codex 👍 with no findings" || bad "done-clean state" "$OUT"

export FIXTURE="$FX_ABSENT"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: absent' && ok "absent: no Codex reaction (a human EYES does not count)" || bad "absent state" "$OUT"

export FIXTURE="$FX_ALL_RESOLVED"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: done-clean' && ok "done-clean when Codex's only work is resolved + 👍" || bad "all-resolved state" "$OUT"

# The post-sweep steady state: a leftover review body with all threads resolved
# must read done-reviewed, NOT present (which would loop forever).
export FIXTURE="$FX_DONE_REVIEWED"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: done-reviewed' && ok "done-reviewed: posted body + all threads resolved is NOT perpetual-present" || bad "done-reviewed state" "$OUT"

# --- fetch: codex-limited (usage cap) -------------------------------------
# A manual @codex review that rate-limits posts its cap notice in a REVIEW BODY +
# a 👀 — must read codex-limited, NOT done-reviewed (the cap body is not a real
# review) and NOT analyzing (the bounded wait must terminate, not merge on a
# phantom review).
export FIXTURE="$FX_CAP_REVIEW_BODY"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: codex-limited' && ok "codex-limited: cap notice in a review body (not done-reviewed/analyzing)" || bad "codex-limited via review body" "$OUT"

# The auto-review cap path (a top-level comment + 👀).

export FIXTURE="$FX_CAP_COMMENT"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: codex-limited' && ok "codex-limited: cap notice in a top-level comment" || bad "codex-limited via comment" "$OUT"

# The repo-wide credits-exhausted notice (a different wording) must also read codex-limited.
export FIXTURE="$FX_CAP_REPO_WIDE"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: codex-limited' && ok "codex-limited: repo-wide credits-exhausted notice (different wording)" || bad "codex-limited via repo-wide notice" "$OUT"

# A real review must win over an earlier cap: cap body + genuine review body →
# done-reviewed (codex-limited overrides only analyzing/absent, never a real review).
export FIXTURE="$FX_CAP_PLUS_REAL"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: done-reviewed' && ok "real review wins over an earlier cap (done-reviewed, not codex-limited)" || bad "real-review-wins" "$OUT"

# FALSE-POSITIVE GUARD: a genuine review whose prose mentions "usage limit" must NOT
# be discarded as a cap — it reads done-reviewed (the anchored predicate rejects it).
export FIXTURE="$FX_REAL_REVIEW_MENTIONS_CAP"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: done-reviewed' && ok "genuine review mentioning 'usage limit' is not a cap (done-reviewed)" || bad "false-positive guard" "$OUT"
echo "$OUT" | grep -q 'enforce any usage limit' && ok "...and its real findings are still surfaced in the body" || bad "real review body surfaced" "$OUT"

# The absent→codex-limited branch for a review-body cap (no reaction at all).
export FIXTURE="$FX_CAP_REVIEW_BODY_NO_REACTION"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: codex-limited' && ok "codex-limited: review-body cap with no reaction (absent branch)" || bad "codex-limited absent branch" "$OUT"

# A genuine review QUOTING the cap boilerplate on a later line is not a cap (start-anchor).
export FIXTURE="$FX_REVIEW_QUOTES_CAP"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: done-reviewed' && ok "review quoting the cap boilerplate stays done-reviewed (start-anchor)" || bad "review-quotes-cap guard" "$OUT"

# The phrase-2 counterpart: a header-led review quoting the repo-wide boilerplate stays done-reviewed.
export FIXTURE="$FX_REPO_WIDE_QUOTED"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: done-reviewed' && ok "review quoting the repo-wide boilerplate stays done-reviewed (start-anchor, phrase 2)" || bad "repo-wide-quotes guard" "$OUT"

# --- fetch: stop conditions (done-replied / merged / closed) ---------------
# An open Codex thread that already has OUR reply must read done-replied, not
# present — the addressed-findings terminal (no re-arm).
export FIXTURE="$FX_DONE_REPLIED"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: done-replied' && ok "done-replied: all open Codex threads already replied → addressed terminal" || bad "done-replied state" "$OUT"
echo "$OUT" | grep -q 'thread-id: PRRT_replied' && ok "done-replied still surfaces the thread (idempotent reply / resolve)" || bad "done-replied surfaces thread" "$OUT"

# A non-open PR stops regardless of an open unaddressed thread (PR-state outranks).
export FIXTURE="$FX_MERGED"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: merged' && ok "merged: non-open PR stops even with an open thread" || bad "merged state" "$OUT"
echo "$OUT" | grep -q 'thread-id:' && bad "merged should short-circuit before listing threads" || ok "merged short-circuits (no thread listing)"

export FIXTURE="$FX_CLOSED"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^CODEX: closed' && ok "closed: non-open PR stops" || bad "closed state" "$OUT"

# --- fetch: truncation marker --------------------------------------------
export FIXTURE="$FX_TRUNC"
OUT=$("$SUT" fetch 4242 2>/dev/null)
echo "$OUT" | grep -q '^TRUNCATED: yes' && ok "truncation emits a TRUNCATED: line" || bad "truncation marker" "$OUT"

# --- no resolve: the engine never resolves a thread (the author's last touch) ----------
if "$SUT" resolve PRRT_codexUnresolved >/dev/null 2>&1; then bad "resolve must not be a subcommand"; else ok "resolve is not a subcommand (usage error)"; fi
[ ! -s "$MUT_LOG" ] && ok "no resolveReviewThread mutation is ever sent" || bad "a mutation was sent" "$(cat "$MUT_LOG")"

# --- await: wakes ONCE, only when there is something to act on ------------
# await polls `fetch` on an interval instead of re-entering the skill per poll.
# --interval 0 keeps these deterministic (no real sleep). The behaviours that
# matter: settle immediately on an actionable/terminal state, keep waiting (bounded)
# on analyzing/absent, and — the whole point — wake exactly when Codex posts.

# Settles immediately on `present` and emits the FULL triage (not just the signal).
export FIXTURE="$FX_PRESENT"
OUT=$("$SUT" await 4242 --interval 0 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && ok "await: exit 0 on present" || bad "await present exit" "rc=$RC"
echo "$OUT" | grep -q '^CODEX: present' && ok "await: settles immediately on present" || bad "await present signal" "$OUT"
echo "$OUT" | grep -q 'thread-id: PRRT_codexUnresolved' && ok "await: hands back the full fetch triage, not just the state" || bad "await emits triage" "$OUT"
echo "$OUT" | grep -q '^AWAIT: wait-exhausted' && bad "await must NOT mark exhausted when it settled on present" || ok "await: no exhausted marker on an actionable settle"
{ echo "$OUT" | grep -q '^AWAIT: settled' && echo "$OUT" | grep -q '/ship:codex-sweep 4242'; } && ok "await: present emits a NEXT handoff line (fresh caller knows to run /ship:codex-sweep)" || bad "await present NEXT handoff" "$OUT"

# Settles immediately on a terminal (done-replied) — no waiting, no re-arm.
export FIXTURE="$FX_DONE_REPLIED"
OUT=$("$SUT" await 4242 --interval 0 2>/dev/null); RC=$?
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^CODEX: done-replied'; } && ok "await: settles immediately on a terminal (done-replied)" || bad "await terminal settle" "rc=$RC $OUT"
echo "$OUT" | grep -q '^AWAIT: wait-exhausted' && bad "await must NOT mark exhausted on a terminal" || ok "await: no exhausted marker on a terminal"
# Every settle — including a terminal — routes back through /ship:codex-sweep (so
# codex-limited's cap procedure / ship-queue's ledger+cross-model step are never
# stranded).
{ echo "$OUT" | grep -q '^AWAIT: settled' && echo "$OUT" | grep -q '/ship:codex-sweep 4242'; } && ok "await: a terminal settle also hands off to /ship:codex-sweep (uniform NEXT)" || bad "await terminal NEXT handoff" "$OUT"

# analyzing never settles → bounded wait, then a wait-exhausted marker (caller re-launches or settles no-show).
export FIXTURE="$FX_ANALYZING"
OUT=$("$SUT" await 4242 --interval 0 --max-analyzing 3 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && ok "await: exit 0 when the analyzing wait is exhausted (not a hard failure)" || bad "await analyzing exit" "rc=$RC"
echo "$OUT" | grep -q 'AWAIT: wait-exhausted after 3 polls, state=analyzing' && ok "await: bounds analyzing at --max-analyzing and reports it" || bad "await analyzing bound" "$OUT"

# absent gives up sooner than analyzing (Codex never picked the PR up).
export FIXTURE="$FX_ABSENT"
OUT=$("$SUT" await 4242 --interval 0 --max-absent 2 2>/dev/null); RC=$?
echo "$OUT" | grep -q 'AWAIT: wait-exhausted after 2 polls, state=absent' && ok "await: bounds absent at --max-absent (sooner than analyzing)" || bad "await absent bound" "$OUT"

# THE POINT: analyzing for the first 2 polls, then Codex posts → await wakes on `present`.
export AWAIT_COUNTER="$STUB/awaitcount"; : > "$AWAIT_COUNTER"
export AWAIT_SWITCH_AT=3; export FIXTURE="$FX_ANALYZING"; export FIXTURE2="$FX_PRESENT"
OUT=$("$SUT" await 4242 --interval 0 --max-analyzing 8 2>/dev/null); RC=$?
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^CODEX: present'; } && ok "await: waits through analyzing polls and wakes when Codex posts (analyzing → present)" || bad "await transition" "rc=$RC $OUT"
echo "$OUT" | grep -q '^AWAIT: wait-exhausted' && bad "await settled on present, must not report exhausted" || ok "await: a mid-wait post wins before the cap"
echo "$OUT" | grep -q 'thread-id: PRRT_codexUnresolved' && ok "await: emits the present triage after the transition" || bad "await transition triage" "$OUT"
unset AWAIT_SWITCH_AT FIXTURE2 AWAIT_COUNTER

# Each state's cap counts only its own polls: 2 absent polls do not use up the analyzing cap.
export AWAIT_COUNTER="$STUB/awaitcount2"; : > "$AWAIT_COUNTER"
export AWAIT_SWITCH_AT=3; export FIXTURE="$FX_ABSENT"; export FIXTURE2="$FX_ANALYZING"
OUT=$("$SUT" await 4242 --interval 0 --max-absent 5 --max-analyzing 3 2>/dev/null)
{ [ "$(cat "$AWAIT_COUNTER")" = 5 ] && echo "$OUT" | grep -q 'wait-exhausted after 3 polls, state=analyzing'; } \
  && ok "await: the analyzing cap counts only analyzing polls (2 absent + 3 analyzing)" || bad "await per-state counter" "polls=$(cat "$AWAIT_COUNTER") $OUT"
unset AWAIT_SWITCH_AT FIXTURE2 AWAIT_COUNTER

# Transient fetch failure: one blip is tolerated (retry), two in a row abort rc≠0.
export AWAIT_FAIL_FILE="$STUB/failcount"
# One failure then a real present → await recovers and settles (does not abort).
: > "$AWAIT_FAIL_FILE"; export AWAIT_FAIL_FIRST=1; export FIXTURE="$FX_PRESENT"
OUT=$("$SUT" await 4242 --interval 0 2>/dev/null); RC=$?
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^CODEX: present'; } && ok "await: tolerates a single transient fetch failure then settles" || bad "await transient recovery" "rc=$RC $OUT"
# Two failures in a row → give up with a non-zero exit (never a false 'settled')
# but STILL emit a NEXT handoff so the fresh-context caller is not stranded.
: > "$AWAIT_FAIL_FILE"; export AWAIT_FAIL_FIRST=2
OUT=$("$SUT" await 4242 --interval 0 2>/dev/null); RC=$?
[ "$RC" -ne 0 ] && ok "await: aborts non-zero after two consecutive fetch failures" || bad "await double-fail exit" "rc=$RC"
{ echo "$OUT" | grep -q 'fetch-failed twice' && echo "$OUT" | grep -q '/ship:codex-sweep 4242'; } && ok "await: a hard-failure abort still emits a NEXT handoff (caller not stranded)" || bad "await rc=1 NEXT handoff" "$OUT"
unset AWAIT_FAIL_FIRST AWAIT_FAIL_FILE

# Hard wall-clock ceiling settles the wait even when the per-state poll cap is never
# hit — the bound that the transient-flap path (which does not advance the cap) needs.
export FIXTURE="$FX_ANALYZING"
OUT=$("$SUT" await 4242 --interval 0 --max-wait 0 --max-analyzing 99 2>/dev/null); RC=$?
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q 'wall-clock'; } && ok "await: hard wall-clock ceiling forces wait-exhausted independent of the poll cap" || bad "await wall-clock ceiling" "rc=$RC $OUT"

# Non-integer flag value is rejected (parity with the valueless/unknown flag guards).
if "$SUT" await 4242 --interval abc >/dev/null 2>&1; then bad "await must reject a non-integer --interval"; else ok "await rejects a non-integer flag value"; fi

# await rejects a valueless trailing flag instead of spinning forever. It returns at once;
# the call is wrapped in a timeout when one is available (macOS ships `gtimeout`, not
# `timeout`) so a spin fails loudly instead of hanging the whole suite.
TIMEOUT=$(command -v timeout || command -v gtimeout || true)
if ${TIMEOUT:+$TIMEOUT 5} "$SUT" await 4242 --interval >/dev/null 2>&1; then bad "await must reject a valueless --interval"; else ok "await rejects a valueless trailing flag (no infinite spin)"; fi

# await preserves "surface read-only threads first" DURING the wait: an analyzing
# poll that already sees a HUMAN thread wakes once (not hides it for the window).
export FIXTURE="$FX_ANALYZING_HUMAN"
OUT=$("$SUT" await 4242 --interval 0 --max-analyzing 8 2>/dev/null); RC=$?
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^AWAIT: human/mixed'; } && ok "await: wakes to surface human/mixed feedback while Codex is still analyzing" || bad "await human-surface wake" "rc=$RC $OUT"
echo "$OUT" | grep -q 'DO NOT auto-resolve' && ok "await: hands back the human thread for surfacing" || bad "await surfaces the human thread" "$OUT"
# --surfaced suppresses the re-wake so the re-launched waiter keeps waiting for Codex.
OUT=$("$SUT" await 4242 --interval 0 --max-analyzing 3 --surfaced 2>/dev/null)
{ echo "$OUT" | grep -q 'wait-exhausted after 3 polls' && ! echo "$OUT" | grep -q '^AWAIT: human/mixed'; } && ok "await --surfaced: does not re-wake on the same human thread, waits for Codex" || bad "await --surfaced suppression" "$OUT"

# await rejects an unknown flag rather than treating it as the PR arg.
if "$SUT" await 4242 --bogus >/dev/null 2>&1; then bad "await must reject an unknown flag"; else ok "await rejects an unknown flag"; fi

# --- usage on bad subcommand ---------------------------------------------
if "$SUT" frobnicate >/dev/null 2>&1; then bad "unknown subcommand should exit non-zero"; else ok "unknown subcommand exits non-zero"; fi

# --- launch path resolves from a nested cwd -----------------------------------------
# /ship:pr and the pr-nudge hook launch the awaiter by the script's absolute path, so it
# resolves from ANY cwd, while a bare cwd-relative path 127s from a subdirectory. The
# human-feedback handoff names that same absolute path for the re-launch.
( cd "$HERE/.." && "$SUT" __nope__ >/dev/null 2>&1 ); rc_abs=$?
( cd "$HERE/.." && ./codex-sweep.sh __nope__ >/dev/null 2>&1 ); rc_rel=$?
{ [ "$rc_abs" -ne 127 ] && [ "$rc_rel" -eq 127 ]; } \
  && ok "await launch resolves from another cwd by absolute path (rc=$rc_abs); a cwd-relative path 127s (rc=$rc_rel)" \
  || bad "nested-cwd launch resolution" "absolute rc=$rc_abs (want !=127), cwd-relative rc=$rc_rel (want 127)"

# --- a cap notice past the 50th conversation comment, a Codex follow-up after our reply
#     (it needs a reply), and await with no PR (a usage error) ---
FX_MANY=$(mktemp)
jq -n '{data:{repository:{pullRequest:{title:"t",state:"OPEN",reactionGroups:[],
  comments:{totalCount:60,nodes:([range(59)|{author:{login:"somehuman",__typename:"User"},body:"chatter \(.)"}]
    + [{author:{login:"chatgpt-codex-connector",__typename:"Bot"},body:"You have reached your Codex usage limit for code reviews."}])},
  reviews:{pageInfo:{hasNextPage:false},nodes:[]},
  reviewThreads:{pageInfo:{hasNextPage:false},nodes:[]}}}}}' > "$FX_MANY"
FX_REPLIED=$(mktemp)
jq -n '{data:{repository:{pullRequest:{title:"t",state:"OPEN",reactionGroups:[],comments:{totalCount:0,nodes:[]},
  reviews:{pageInfo:{hasNextPage:false},nodes:[{author:{login:"chatgpt-codex-connector",__typename:"Bot"},body:"Two findings."}]},
  reviewThreads:{pageInfo:{hasNextPage:false},nodes:[
    {id:"PRRT_replied",isResolved:false,isOutdated:false,path:"a.go",line:3,
     comments:{pageInfo:{hasNextPage:false},nodes:[
       {databaseId:1,author:{login:"chatgpt-codex-connector",__typename:"Bot"},body:"bug here"},
       {databaseId:2,author:{login:"tester",__typename:"User"},body:"handled in the next commit"}]}}]}}}}}' > "$FX_REPLIED"
FX_FOLLOWUP=$(mktemp)
jq -n '{data:{repository:{pullRequest:{title:"t",state:"OPEN",reactionGroups:[],comments:{totalCount:0,nodes:[]},
  reviews:{pageInfo:{hasNextPage:false},nodes:[]},
  reviewThreads:{pageInfo:{hasNextPage:false},nodes:[
    {id:"PRRT_followup",isResolved:false,isOutdated:false,path:"a.go",line:3,
     comments:{pageInfo:{hasNextPage:false},nodes:[
       {databaseId:1,author:{login:"chatgpt-codex-connector",__typename:"Bot"},body:"bug here"},
       {databaseId:2,author:{login:"tester",__typename:"User"},body:"fixed"},
       {databaseId:3,author:{login:"chatgpt-codex-connector",__typename:"Bot"},body:"still broken on the empty path"}]}}]}}}}}' > "$FX_FOLLOWUP"
# Rows: name | fixture | extra env | want CODEX state
CASES=(
  "a cap notice after 50 conversation comments still reads codex-limited|$FX_MANY|STUB_PAGE_COMMENTS=1|codex-limited"
  "a Codex follow-up after our reply is present again|$FX_FOLLOWUP||present"
  "with no login, a Codex follow-up after a reply is still present|$FX_FOLLOWUP|STUB_NO_USER=1|present"
  "with no login, a thread whose last word is ours is done-replied|$FX_REPLIED|STUB_NO_USER=1|done-replied"
)
for row in "${CASES[@]}"; do
  IFS='|' read -r name fx extra want <<<"$row"
  if [ -n "$extra" ]; then got=$(env FIXTURE="$fx" "$extra" "$SUT" fetch 4242 2>/dev/null | sed -n 's/^CODEX: //p')
  else got=$(env FIXTURE="$fx" "$SUT" fetch 4242 2>/dev/null | sed -n 's/^CODEX: //p'); fi
  [ "$got" = "$want" ] && ok "$name" || bad "$name" "got CODEX: $got"
done
OUT=$(STUB_NO_PR=1 FIXTURE="$FX_FOLLOWUP" "$SUT" await --interval 0 2>&1); RC=$?
{ [ "$RC" -eq 2 ] && ! echo "$OUT" | grep -q '/ship:codex-sweep `' && echo "$OUT" | grep -q 'no open PR'; } \
  && ok "await with no PR is a usage error, not a blank handoff" || bad "await with no PR" "rc=$RC $OUT"
rm -f "$FX_MANY" "$FX_FOLLOWUP" "$FX_REPLIED"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
rm -rf "$STUB" "$FX_PRESENT" "$FX_ANALYZING" "$FX_ANALYZING_HUMAN" "$FX_DONECLEAN" "$FX_ABSENT" "$FX_ALL_RESOLVED" "$FX_DONE_REVIEWED" "$FX_DONE_REPLIED" "$FX_MERGED" "$FX_CLOSED" "$FX_TRUNC" "$FX_CAP_REVIEW_BODY" "$FX_CAP_COMMENT" "$FX_CAP_REPO_WIDE" "$FX_CAP_PLUS_REAL" "$FX_REAL_REVIEW_MENTIONS_CAP" "$FX_CAP_REVIEW_BODY_NO_REACTION" "$FX_REVIEW_QUOTES_CAP" "$FX_REPO_WIDE_QUOTED"
[ "$FAIL" -eq 0 ]
