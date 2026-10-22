#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# codex-sweep - the engine for the post-PR Codex review sweep.
#
# Why this exists: right after `gh pr create` Codex posts its review ~1-2 min
# later. Instead of the human having to come back, run /ship:pr-feedback, and address by
# hand, the /ship:pr skill launches `await` (below) as a background task; it polls in a
# shell loop — zero tokens — and wakes the agent once, when there is something to
# act on. This script is the deterministic fetch/await the skill drives.
#
# Unlike /ship:pr-feedback's engine, it filters to the hosted Codex reviewer (the
# codex_reviewer_login setting, default `chatgpt-codex-connector`) so the sweep never
# acts on a human's thread, surfaces human threads read-only, and computes the CODEX
# state the skill branches on. It never resolves a thread: that is the author's last
# touch before merge.
#
# Subcommands:
#   fetch <PR>                 triage list (Codex review body + Codex unresolved
#                              threads with thread-id & reply-target, human
#                              unresolved threads surface-only) + a CODEX: signal
#                              the skill branches on — one of present | done-replied
#                              | done-reviewed | done-clean | analyzing | absent |
#                              codex-limited | merged | closed (all but present/
#                              analyzing/absent are stop states; codex-limited is a
#                              stop — Codex hit its usage cap and will not review).
#   await <PR>                 poll `fetch` on an interval, WITHOUT an LLM turn per
#                              poll (the wait is a shell sleep = zero tokens), and
#                              print the triage only once the state is actionable
#                              (`present`) or terminal — so the caller wakes once,
#                              not once per poll. `analyzing`/`absent` keep waiting,
#                              bounded (--max-analyzing/--max-absent); at the cap it
#                              appends an `AWAIT: wait-exhausted` marker. This is what
#                              /ship:pr and /queue:ship-queue launch as a background Bash instead
#                              of a timed re-arm loop.
# Replies are a plain `gh api ... -F in_reply_to=<reply-target> -f body=…` (REST),
# same as /ship:pr-feedback — this script does not reply.
#
# Usage:  codex-sweep.sh fetch [PR]        (no PR -> current branch's PR)
#         codex-sweep.sh await [PR] [--interval N] ...
# Exits non-zero on a hard failure (no gh/jq, no PR, query error) so a caller
# never mistakes "couldn't fetch" for "clean / no Codex".

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# The hosted Codex reviewer's GitHub bot login (setting codex_reviewer_login); paired with a
# __typename==Bot check so a squatted human account cannot impersonate it.
# shellcheck source=../../scripts/kit-config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/kit-config.sh" 2>/dev/null || kit_config() { :; }
CODEX_LOGIN="$(kit_config codex_reviewer_login "${CODEX_REVIEWER_LOGIN:-}")"
: "${CODEX_LOGIN:=chatgpt-codex-connector}"

command -v gh >/dev/null 2>&1 || { echo "codex-sweep: 'gh' not installed/authed" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "codex-sweep: 'jq' not installed" >&2; exit 1; }

# shellcheck source=../../scripts/lib/gh-pr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/gh-pr.sh" \
  || { echo "codex-sweep: gh-pr.sh missing" >&2; exit 1; }

cmd_fetch() {
  local pr
  pr=$(gh_pr_number codex-sweep "${1:-}") || exit 1
  gh_pr_repo codex-sweep || exit 1

  local gql='
  query($owner:String!,$name:String!,$num:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$num){
        title
        state
        reactionGroups{ content users(first:20){ nodes{ login } } }
        comments(last:100){ totalCount nodes{ author{login __typename} body } }
        reviews(first:100){ pageInfo{hasNextPage} nodes{ author{login __typename} state body } }
        reviewThreads(first:100){ pageInfo{hasNextPage} nodes{
          id isResolved isOutdated path line
          comments(first:30){ pageInfo{hasNextPage} nodes{ databaseId author{login __typename} body } }
        } }
      }
    }
  }'
  local json
  json=$(gh_pr_graphql codex-sweep "$pr" "$gql") || exit 1
  local p='.data.repository.pullRequest'

  local title; title=$(printf '%s' "$json" | jq -r "$p.title // \"\"")

  # ── Stop condition: PR no longer open ──────────────────────────────────────
  # A merged/closed PR ends the sweep: there is nothing left to address, and a
  # re-arm against it would spin forever. This outranks every Codex signal, so a
  # PR merged mid-sweep stops the loop on the very next wake.
  local pr_state; pr_state=$(printf '%s' "$json" | jq -r "$p.state // \"OPEN\"")
  if [ "$pr_state" != "OPEN" ]; then
    local term; case "$pr_state" in MERGED) term="merged" ;; *) term="closed" ;; esac
    printf '=== Codex sweep — PR #%s — %s — %s ===\n' "$pr" "$SLUG" "$title"
    printf 'CODEX: %s\n' "$term"
    printf '\nPR #%s is %s — sweep stops (nothing to address on a %s PR).\n' "$pr" "$pr_state" "$term"
    return 0
  fi

  local cl="$CODEX_LOGIN"
  # The acting account — the login the sweep replies as. A Codex-rooted thread is
  # actionable only if every comment is Codex's or ours; a third-party (human) reply
  # makes it mixed → surface-only (replying would step into the human's open
  # discussion). Empty (offline) degrades safe: only all-Codex threads stay actionable.
  local me; me=$(gh api user -q .login 2>/dev/null || true)

  # A Codex thread is "pure" — actionable — only when its root is
  # the Codex bot, it is unresolved, AND every comment is Codex's or ours: a
  # third-party reply makes it MIXED, surfaced but never acted on (replying/
  # resolving would step on the human's open discussion). Defined here (above the
  # state signal) because the signal counts these threads. thread-id names the thread
  # for a human; reply-target (root comment databaseId) feeds the REST in_reply_to.
  # nodes|length>0 guards nodes[0] null.
  local codex_root="(.comments.nodes|length)>0 and .comments.nodes[0].author.login==\$cl and .comments.nodes[0].author.__typename==\"Bot\" and (.isResolved|not)"
  # With no login for us (`gh api user` failed), every Codex-rooted thread counts as ours and is
  # judged by its last comment's author: Codex's last word needs a reply, anyone else's is one.
  local all_ours=".comments.nodes | all(.author.login==\$cl or .author.login==\$me)"
  [ -n "$me" ] || all_ours="true"
  # A pure Codex thread whose last word is Codex's is the only kind that needs action.
  # Codex spoke last: a thread we never replied to, or a Codex follow-up after our reply.
  local needs_reply="((.comments.nodes | last | .author.login) == \$cl)"

  # The Codex state — the signal the skill branches on. A fixed wait is wrong
  # (Codex's lag is not bounded) and its PR-body reaction is the real progress
  # signal. Order matters — earlier wins:
  #   present      — a pure Codex thread whose last comment is Codex's remains (never
  #                  answered, or Codex followed up on our reply) → act now.
  #   done-replied — pure Codex threads remain but EVERY one ends with our reply
  #                  → findings addressed, awaiting the author's resolve. STOP, do
  #                  NOT re-arm. (Counting an already-replied thread as work is the
  #                  perpetual-"present" spin; this is its terminal.)
  #   done-reviewed— Codex posted a review body but no unresolved pure thread is
  #                  left → handled. STOP. (The body is a summary, not a re-trigger.)
  #   done-clean   — Codex 👍'd the PR and posted nothing → reviewed, no comments. STOP.
  #   analyzing    — Codex 👀'd but has not posted yet → still working. Bounded
  #                  re-arm. Codex drops the 👀 once it posts, so this never lingers.
  #   absent       — no Codex review and no reaction → maybe not picked up. Bounded
  #                  re-arm, then stop.
  # (A non-open PR is handled earlier — merged/closed stops before this point.)
  # Two identity subtleties, both load-bearing:
  #   - Reviews/threads: author is `chatgpt-codex-connector`, __typename==Bot — we
  #     require BOTH (a human squatting the login but typed User is not Codex). A
  #     mixed/human thread is excluded from the act-signal (surface-only). With an
  #     empty `me` (the login lookup failed) a Codex-rooted thread is judged by its
  #     last comment's author, so a Codex follow-up still reads as `present`.
  #   - Reactions: GitHub types the SAME bot as `chatgpt-codex-connector[bot]` /
  #     __typename User in the reaction users connection, so the reaction matcher
  #     strips a trailing [bot] and does NOT require Bot typename. Lower stakes — a
  #     reaction only steers WAITING, never a reply/resolve.
  # The cap-notice predicate — ONE source of truth, reused by $rb, the limited
  # detector, and the body display so they can never drift. Two anchors, both
  # load-bearing, so a genuine review is never misread as a cap and discarded:
  #   - a cap PHRASE — either "reached your Codex usage limit" (the per-request cap) or
  #     "Codex usage limits have been reached for code reviews" (the repo-wide
  #     credits-exhausted notice, delivered as a top-level comment) — not the bare words
  #     "usage limit", else a real rate-limit/quota finding (plausible in this repo)
  #     matches; each phrase is kept as specific as the observed wording so an organic
  #     review sentence about usage limits cannot flip a real review to codex-limited;
  #   - the START of the body (`^.{0,60}`) — the cap notice IS delivered as the body, so
  #     it leads; a real review that merely QUOTES the boilerplate has it on a later
  #     line after a review header/prose, and `.` not crossing a newline keeps the match
  #     to the first line. (Case-insensitive `i` flag, so no [Cc] needed.)
  # This is the single point of failure for the codex-limited terminal — if Codex
  # changes the cap wording or stops leading with it, revisit it here.
  local cap_re="^.{0,60}(reached your codex usage limit|codex usage limits have been reached for code reviews)"
  local state
  state=$(printf '%s' "$json" | jq -r --arg cl "$cl" --arg me "$me" --arg cap "$cap_re" "
    ([$p.reviews.nodes[] | select(.author.login==\$cl and .author.__typename==\"Bot\" and ((.body//\"\")|gsub(\"\\\\s\";\"\"))!=\"\" and (((.body//\"\")|test(\$cap;\"i\"))|not))] | length) as \$rb
    | ([$p.reviewThreads.nodes[] | select($codex_root and ($all_ours))] | length) as \$openpure
    | ([$p.reviewThreads.nodes[] | select($codex_root and ($all_ours) and $needs_reply)] | length) as \$act
    | (($p.reactionGroups // []) | any(.[]; .content==\"EYES\"      and ((.users.nodes // []) | any(.[]; (.login|sub(\"\\\\[bot\\\\]\$\";\"\"))==\$cl)))) as \$eyes
    | (($p.reactionGroups // []) | any(.[]; .content==\"THUMBS_UP\" and ((.users.nodes // []) | any(.[]; (.login|sub(\"\\\\[bot\\\\]\$\";\"\"))==\$cl)))) as \$up
    | if \$act > 0 then \"present\" elif \$openpure > 0 then \"done-replied\" elif \$rb > 0 then \"done-reviewed\" elif \$up then \"done-clean\" elif \$eyes then \"analyzing\" else \"absent\" end") \
    || { echo "codex-sweep: failed computing the Codex state signal (jq error)" >&2; exit 1; }

  # Codex rate-limit: Codex posts a cap notice ($cap_re) instead of reviewing, so the
  # WAITING states (analyzing/absent) must terminate, not spin. Two surfaces carry it —
  # an AUTO review caps via a top-level comment, a MANUAL `@codex review` via a review
  # BODY — both scanned here. $rb (above) excludes a cap body so the cap does not read
  # as done-reviewed and starve this override (scoped to analyzing/absent); a genuine
  # review body still counts in $rb, so a real review after a cap wins.
  local limited
  limited=$(printf '%s' "$json" | jq -r --arg cl "$cl" --arg cap "$cap_re" "
    ([$p.comments.nodes[]? | select((.author.login|sub(\"\\\\[bot\\\\]\$\";\"\"))==\$cl) | select((.body//\"\")|test(\$cap;\"i\"))] | length)
    + ([$p.reviews.nodes[]?  | select((.author.login|sub(\"\\\\[bot\\\\]\$\";\"\"))==\$cl) | select((.body//\"\")|test(\$cap;\"i\"))] | length)")
  if [ "${limited:-0}" -gt 0 ] && { [ "$state" = "absent" ] || [ "$state" = "analyzing" ]; }; then
    state="codex-limited"
  fi

  # Display the real review body — but withhold a cap notice (kept in lockstep with
  # $rb above), so a capped PR does not print review text under a "codex-limited" banner.
  local body
  body=$(printf '%s' "$json" | jq -r --arg cl "$cl" --arg cap "$cap_re" "
    $p.reviews.nodes[] | select(.author.login==\$cl and .author.__typename==\"Bot\" and ((.body//\"\")|gsub(\"\\\\s\";\"\"))!=\"\" and (((.body//\"\")|test(\$cap;\"i\"))|not))
    | \"[\(.state)]:\n\" + ((.body) | split(\"\n\") | map(\"    \" + .) | join(\"\n\"))")

  local codex_threads
  codex_threads=$(printf '%s' "$json" | jq -r --arg cl "$cl" --arg me "$me" "
    $p.reviewThreads.nodes[]
    | select($codex_root and ($all_ours))
    | \"• \(.path):\(.line // \"?\")  [UNRESOLVED\(if .isOutdated then \" · outdated\" else \"\" end)]  thread-id: \(.id)  reply-target: \(.comments.nodes[0].databaseId)\n\"
      + (.comments.nodes | map(\"    @\(.author.login): \" + ((.body)|gsub(\"\n\";\" \"))) | join(\"\n\"))")

  # MIXED: Codex-rooted but a non-Codex, non-acting-account (human) reply joined.
  # Surface only — do NOT resolve (it would close the human's discussion too).
  local mixed_threads
  mixed_threads=$(printf '%s' "$json" | jq -r --arg cl "$cl" --arg me "$me" "
    $p.reviewThreads.nodes[]
    | select($codex_root and (($all_ours)|not))
    | \"• \(.path):\(.line // \"?\")  [UNRESOLVED — Codex thread with a human reply; DO NOT auto-resolve]  reply-target: \(.comments.nodes[0].databaseId)\n\"
      + (.comments.nodes | map(\"    @\(.author.login): \" + ((.body)|gsub(\"\n\";\" \"))) | join(\"\n\"))")

  # Scope boundary: never auto-resolve a human's thread. "human" = root comment is
  # not the Codex bot; a zero-comment thread is dropped from every bucket.
  local human_threads
  human_threads=$(printf '%s' "$json" | jq -r --arg cl "$cl" "
    $p.reviewThreads.nodes[]
    | select((.comments.nodes|length)>0 and (.isResolved|not) and (.comments.nodes[0].author.login!=\$cl or .comments.nodes[0].author.__typename!=\"Bot\"))
    | \"• \(.path):\(.line // \"?\")  by @\(.comments.nodes[0].author.login)  [UNRESOLVED — DO NOT auto-resolve]\"")

  section() { printf '\n── %s ──\n' "$1"; if [ -n "$2" ]; then printf '%s\n' "$2"; else printf '  (none)\n'; fi; }

  printf '=== Codex sweep — PR #%s — %s — %s ===\n' "$pr" "$SLUG" "$title"
  printf 'CODEX: %s\n' "$state"
  section "CODEX REVIEW BODY" "$body"
  section "CODEX UNRESOLVED THREADS (fix → reply; the author resolves)" "$codex_threads"
  section "MIXED THREADS — Codex + human reply (surface only)" "$mixed_threads"
  section "HUMAN UNRESOLVED THREADS (surface only)" "$human_threads"

  # No-silent-truncation guard (same posture as pr-feedback.sh). Emit a
  # machine-greppable TRUNCATED line the skill checks before claiming coverage —
  # a >100-item surface means the Codex list above is incomplete.
  # The conversation comments are read newest-first in one page of 100 (a cap notice is
  # recent); more than that also counts as truncated.
  local trunc
  trunc=$(printf '%s' "$json" | jq -r "([$p.reviews.pageInfo.hasNextPage,$p.reviewThreads.pageInfo.hasNextPage,(($p.comments.totalCount // 0) > 100)]+[$p.reviewThreads.nodes[].comments.pageInfo.hasNextPage]) | any")
  if [ "$trunc" = "true" ]; then
    printf '\nTRUNCATED: yes — a surface exceeds the page size; the Codex list is NOT complete. Paginate / surface to the human before claiming full coverage.\n'
  fi
  return 0
}

cmd_await() {
  # Wait for Codex WITHOUT spending an LLM turn per poll. Re-arming a wake per poll
  # re-enters the whole /ship:codex-sweep skill in a fresh LLM turn, re-caching the
  # ambient session just to read one word and reschedule. Here the wait is a plain shell sleep between `fetch`
  # calls (zero tokens), and the caller wakes ONCE — when there is something to act
  # on. `fetch` still owns the state signal; this only decides when to stop waiting
  # and hand back its triage.
  #
  # Exit contract (so the caller never mistakes a wait for a result):
  #   0 — reached an actionable/terminal state; the full `fetch` triage is on stdout
  #       (its `CODEX:` line is `present` or a stop state), OR the bounded wait was
  #       exhausted (an extra `AWAIT: wait-exhausted …` line is appended so the caller
  #       can re-launch or settle it as no-show).
  #   1 — hard failure (propagated from `fetch`: no gh/jq, no PR, GraphQL error).
  # A hard wall-clock ceiling (max_wait, default 720s ≈ 12 min, below how long a
  # background command is expected to survive) bounds the loop regardless of poll count OR transient-failure
  # retries. The per-state poll caps only bound *successful* polls, so a flapping
  # fetch (fail, ok, fail, ok…) never advances them and never trips the
  # two-in-a-row abort — the poll caps alone cannot bound wall-clock; max_wait does.
  # A longer wait is handled by re-launch on the `wait-exhausted` handoff, never by
  # one process outliving that ceiling. (Like any within-session waiter, if the
  # session itself ends before it settles the wake is lost — distinct from
  # wait-exhausted, which does wake the caller.)
  local pr="" interval=120 max_analyzing=6 max_absent=3 max_wait=720 surfaced=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval|--max-analyzing|--max-absent|--max-wait)
        # Guard the value: a trailing valueless flag (`await 4242 --interval`) would
        # make `shift 2` fail and, with the count unconsumed, spin this detached
        # process forever without ever waking the caller.
        [ $# -ge 2 ] || { echo "codex-sweep: await: $1 needs a value" >&2; return 2; }
        case "$1" in
          --interval)      interval="$2" ;;
          --max-analyzing) max_analyzing="$2" ;;
          --max-absent)    max_absent="$2" ;;
          --max-wait)      max_wait="$2" ;;
        esac
        shift 2 ;;
      --surfaced) surfaced=1; shift ;;   # already surfaced human/mixed threads once — don't re-wake for them
      -*) echo "codex-sweep: await: unknown flag '$1'" >&2; return 2 ;;
      *)  [ -z "$pr" ] && pr="$1"; shift ;;
    esac
  done
  for v in "$interval" "$max_analyzing" "$max_absent" "$max_wait"; do
    case "$v" in ''|*[!0-9]*) echo "codex-sweep: await: --interval/--max-* must be non-negative integers" >&2; return 2 ;; esac
  done
  # Resolve the PR up front so every handoff line names a concrete PR — a no-arg
  # manual run would otherwise emit `/ship:codex-sweep ` with a blank number.
  if [ -z "$pr" ]; then pr=$(gh pr view --json number -q .number 2>/dev/null || true); fi
  if [ -z "$pr" ]; then
    echo "codex-sweep: await: no PR number given and no open PR for this branch — pass the PR number" >&2
    return 2
  fi

  local start=$SECONDS
  local attempt=0 polls_absent=0 polls_analyzing=0 fails=0 out rc state last_out=""
  while :; do
    # Capture fetch's stdout; a hard failure exits its subshell non-zero.
    out=$(cmd_fetch "$pr"); rc=$?
    if [ "$rc" -ne 0 ]; then
      # Tolerate a transient blip (network/rate-limit) once — abort only on two in a
      # row. On abort still emit a NEXT handoff, so the fresh-context caller woken by
      # the failed background task is never left without an instruction (else Codex's
      # review is silently dropped — the outcome await exists to prevent).
      fails=$((fails+1))
      if [ "$fails" -ge 2 ]; then
        printf '%s' "$out"
        printf '\nAWAIT: fetch-failed twice — NEXT: run `/ship:codex-sweep %s` to retry the sweep or surface the failure to the author.\n' "$pr"
        echo "codex-sweep: await: fetch failed twice, giving up" >&2
        return 1
      fi
    else
      fails=0
      last_out=$out
      attempt=$((attempt+1))                           # count only successful state polls
      state=$(printf '%s\n' "$out" | sed -n 's/^CODEX: //p' | head -1)
      case "$state" in
        analyzing|absent)
          # Preserve the skill's "surface read-only threads first, in every state"
          # invariant *during* the wait: if fetch already found HUMAN/MIXED unresolved
          # threads (both carry the "DO NOT auto-resolve" marker), wake once so the
          # agent can surface that human feedback now, instead of hiding it for the
          # whole window. The caller re-launches with --surfaced to resume waiting for
          # Codex without re-waking on the same threads.
          if [ "$surfaced" -eq 0 ] && printf '%s\n' "$out" | grep -qE 'DO NOT auto-resolve'; then
            printf '%s\n' "$out"
            printf '\nAWAIT: human/mixed PR feedback is present while Codex is %s — NEXT: run `/ship:codex-sweep %s` to surface it (read-only, never resolve), then re-launch `"%s" await %s --surfaced` (background; the absolute path resolves from any cwd) to keep waiting for Codex.\n' "$state" "$pr" "$SELF" "$pr"
            return 0
          fi
          ;;                                           # not settled yet — keep waiting (bounded below)
        *)                                             # present or any stop state → emit triage + wake the caller
          printf '%s\n' "$out"
          # The caller wakes in a FRESH context (this ran in the background), so route
          # EVERY settle back through `/ship:codex-sweep`, which owns the per-state handling
          # — fix+reply on `present`, the usage-cap guidance on `codex-limited`,
          # human/mixed-thread surfacing, a clean/`merged`/`closed` report. A per-state
          # trailer here would strand `codex-limited` (skip its cap procedure and any
          # caller's follow-up step), so the handoff is uniform.
          printf '\nAWAIT: settled (state=%s) — waiting complete. NEXT: run `/ship:codex-sweep %s` to act on the triage above. Do NOT wait again.\n' "$state" "$pr"
          return 0 ;;
      esac
      # Per-state poll caps, each counting only the polls spent in that state: `absent` (Codex
      # never picked the PR up) gives up sooner than `analyzing` (Codex is 👀 and working).
      case "$state" in absent) polls_absent=$((polls_absent+1)) ;; analyzing) polls_analyzing=$((polls_analyzing+1)) ;; esac
      if { [ "$state" = "absent" ]    && [ "$polls_absent" -ge "$max_absent" ]; } ||
         { [ "$state" = "analyzing" ] && [ "$polls_analyzing" -ge "$max_analyzing" ]; }; then
        printf '%s\n' "$out"
        printf '\nAWAIT: wait-exhausted after %s polls, state=%s — NEXT: run `/ship:codex-sweep %s` to re-launch await if still worth waiting, or settle as no-show.\n' "$( [ "$state" = absent ] && echo "$polls_absent" || echo "$polls_analyzing")" "$state" "$pr"
        return 0
      fi
    fi
    # Hard wall-clock backstop, guarding the single sleep: never start a sleep that
    # would push total elapsed past max_wait, so transient-failure retries (which do
    # not advance the per-state poll cap) can't outlive the survival window.
    if [ "$(( (SECONDS - start) + interval ))" -ge "$max_wait" ]; then
      [ -n "$last_out" ] && printf '%s\n' "$last_out"
      printf '\nAWAIT: wait-exhausted (wall-clock ~%ss, last state=%s) — NEXT: run `/ship:codex-sweep %s` to re-launch await if still worth waiting, or settle as no-show.\n' "$max_wait" "${state:-none}" "$pr"
      return 0
    fi
    sleep "$interval"
  done
}

case "${1:-}" in
  fetch)   shift; cmd_fetch "$@" ;;
  await)   shift; cmd_await "$@" ;;
  *) echo "usage: codex-sweep.sh fetch [PR] | await [PR] [--interval N] [--max-analyzing N] [--max-absent N] [--max-wait SEC] [--surfaced]" >&2; exit 2 ;;
esac
