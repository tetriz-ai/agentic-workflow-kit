#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -uo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# The kit's command segmenter (simple_commands, leading_cd_dir, tool_cwd), a copy of
# shared/cwd-resolve.sh. Without it the git and gh denies cannot classify: block.
_SEGMENTER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/cwd-resolve.sh"
[ -r "$_SEGMENTER" ] || { echo "Blocked by policy: $_SEGMENTER is missing; re-run the bridge sync." >&2; exit 2; }
# shellcheck source=lib/cwd-resolve.sh
. "$_SEGMENTER"
kit_export_compat_env

INPUT="$(kit_read_stdin)"
kit_debug_hook_payload "pre-bash" "$INPUT"
COMMAND="$(kit_command_from_payload "$INPUT")"

# run_blocking_hook / run_advisory_hook <plugin> <script>: run a kit plugin script on the
# payload, unless the kit's Codex plugin has claimed this call (kit_claim).
run_blocking_hook() {
  local script
  script="$(kit_script "$1" "$2")"
  [ -x "$script" ] || return 0
  printf '%s' "$INPUT" | kit_claim "$1" "$2" || return 0
  printf '%s' "$INPUT" | "$script"
}

run_advisory_hook() {
  local script
  script="$(kit_script "$1" "$2")"
  [ -x "$script" ] || return 0
  printf '%s' "$INPUT" | kit_claim "$1" "$2" || return 0
  printf '%s' "$INPUT" | "$script" || true
}

# curl/wget piped into a shell, through any filters (`| tee f | bash`), sudo or env (with
# their options), an absolute path (`| /bin/bash`), and any of sh, bash, zsh, dash, ksh
# (bridge/agent-harness/pre-bash-policy.test.sh). Newlines and tabs are flattened first so a
# multi-line command is one string.
CURL_TO_SHELL_RE='(^|[;&|(`[:space:]])(curl|wget)([[:space:]][^|;]*)?(\|[^|;]*)*\|[[:space:]]*((sudo|env)([[:space:]]+-[^[:space:]]+)*[[:space:]]+)*([^[:space:]|]*/)?(ba|z|da|k)?sh([;&|)`[:space:]]|$)'
if printf '%s' "$COMMAND" | tr '\n\r\t' '   ' | grep -Eq "$CURL_TO_SHELL_RE"; then
  echo "Blocked by policy: do not pipe curl/wget output into a shell." >&2
  echo "Download the script, inspect it, pin the source/version, then run an explicit command if still needed." >&2
  exit 2
fi

POLICY_COMMAND="${COMMAND//\\/}"
# The raw command, and each simple command that runs git or gh (after VAR=value prefixes,
# wrappers and keywords), one per line: every deny below is checked against both.
GIT_LINES="$(simple_commands "$POLICY_COMMAND" git)"
GH_LINES="$(simple_commands "$POLICY_COMMAND" gh)"
SHELL_COMMAND_PREFIX='(^|[;&|()])[[:space:]]*'
GIT_GLOBAL_OPTION='([[:space:]]+(-[cC]([^;&|[:space:]]+|[[:space:]]+[^;&|[:space:]]+)|--(git-dir|work-tree|namespace|super-prefix|config-env|exec-path|attr-source|list-cmds)(=[^;&|[:space:]]+|[[:space:]]+[^;&|[:space:]]+)|--(bare|no-pager|paginate|no-replace-objects|no-optional-locks|no-lazy-fetch|literal-pathspecs|glob-pathspecs|noglob-pathspecs|icase-pathspecs|no-advice)|-[pP]))'
PROTECTED_REFSPEC="[\"']?\\+?([^;&|[:space:]\"']*:)?(refs/heads/)?(main|master)[\"']?([[:space:];&|()]|$)"
GIT_PUSH_RE="${SHELL_COMMAND_PREFIX}([^;&|()[:space:]]*/)?git${GIT_GLOBAL_OPTION}*[[:space:]]+[\"']?push[\"']?([^;&|]*[[:space:]])${PROTECTED_REFSPEC}"
GIT_PUSH_ALIAS_RE="${SHELL_COMMAND_PREFIX}([^;&|()[:space:]]*/)?git[^;&|]*-[cC][[:space:]]+[^;&|[:space:]]*alias\\.[^;&|[:space:]]*=push([^;&|]*[[:space:]])${PROTECTED_REFSPEC}"
if printf '%s\n%s\n' "$POLICY_COMMAND" "$GIT_LINES" | grep -Eq "$GIT_PUSH_RE|$GIT_PUSH_ALIAS_RE"; then
  echo "Blocked by policy: agents must not push directly to main or master." >&2
  exit 2
fi

# A bare `git push` (flags and at most a remote; also `git push -u origin HEAD`, whose `HEAD` or
# `@` refspec is the current branch) pushes the current branch, whose name is not in the
# command. Read HEAD where the push runs (its `git -C <dir>`, else the payload's cwd or workdir)
# and block on main/master, or when the branch cannot be read (a detached HEAD). The same check
# checked by bridge/agent-harness/pre-bash-policy.test.sh.
# `--all` and `--mirror` push every branch, main included.
if printf '%s\n' "$GIT_LINES" | grep -Eq '^([^ ]*/)?git( [^ ]+)* push( [^ ]+)* --(all|mirror)( |$)'; then
  echo "Blocked by policy: git push --all or --mirror pushes main or master too. Push the one branch." >&2
  exit 2
fi
# The directory the push runs in: its leading `cd <dir>`, else the payload's workdir or cwd.
PAYLOAD_CWD="$(tool_cwd "$INPUT")"
CD_DIR="$(leading_cd_dir "$COMMAND" "$PAYLOAD_CWD")"
[ -z "$CD_DIR" ] || PAYLOAD_CWD="$CD_DIR"
bare_push_dir() { # bare_push_dir <simple command>: prints the push's directory when it is a bare push
  local -a w; local i n dir="${PAYLOAD_CWD:-.}" positional=0
  read -r -a w <<<"$1"; n=${#w[@]}
  [ "$n" -gt 0 ] || return 1
  case "${w[0]}" in git|*/git) ;; *) return 1 ;; esac
  i=1
  while [ "$i" -lt "$n" ]; do
    case "${w[$i]}" in
      -C) case "${w[$((i + 1))]:-}" in /*) dir="${w[$((i + 1))]}" ;; *) dir="$dir/${w[$((i + 1))]:-}" ;; esac; i=$((i + 2)) ;;
      -c|--git-dir|--work-tree|--namespace) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "${w[$i]:-}" = push ] || return 1
  for ((i = i + 1; i < n; i++)); do
    case "${w[$i]}" in
      -*) ;;
      *:*) return 1 ;;
      HEAD|@) ;;
      *) positional=$((positional + 1)) ;;
    esac
  done
  [ "$positional" -le 1 ] || return 1
  printf '%s' "$dir"
}
while IFS= read -r seg; do
  push_dir="$(bare_push_dir "$seg")" || continue
  cur_branch="$(git -C "$push_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  case "$cur_branch" in
    master|main) echo "Blocked by policy: HEAD is on $cur_branch; do not push directly from main or master. Work on a feature branch." >&2; exit 2 ;;
    '') echo "Blocked by policy: cannot read the current branch (detached HEAD?); refusing a bare git push. Push an explicit non-main refspec instead." >&2; exit 2 ;;
  esac
done <<<"$GIT_LINES"

GH_GLOBAL_OPTION='([[:space:]]+((-[RH]|--(repo|hostname))([^;&|[:space:]]+|[[:space:]]+[^;&|[:space:]]+)|--help))'
GH_MERGE_RE="${SHELL_COMMAND_PREFIX}([^;&|()[:space:]]*/)?gh${GH_GLOBAL_OPTION}*[[:space:]]+[\"']?pr[\"']?${GH_GLOBAL_OPTION}*[[:space:]]+[\"']?merge[\"']?([^[:alnum:]_-]|$)"
GH_API_MERGE_RE="${SHELL_COMMAND_PREFIX}([^;&|()[:space:]]*/)?gh${GH_GLOBAL_OPTION}*[[:space:]]+[\"']?api[\"']?[^;&|]*(pulls/[^/;&|[:space:]]+/merge([^[:alnum:]_-]|$)|/merges([^[:alnum:]_-]|$)|graphql[^;&|]*mergePullRequest)"
if printf '%s\n%s\n' "$POLICY_COMMAND" "$GH_LINES" | grep -Eq "$GH_MERGE_RE|$GH_API_MERGE_RE"; then
  echo "Blocked by policy: agents must not merge pull requests or branches." >&2
  exit 2
fi

run_blocking_hook guards block-unpinned-npx.sh || exit $?
run_blocking_hook guards commit-gate.sh || exit $?
run_blocking_hook guards lockfile-gate.sh || exit $?

ADVISORY_OUTPUT="$(
  {
    run_advisory_hook review review-cadence.sh
    run_advisory_hook ship pr-nudge.sh
  } 2>/dev/null
)"

if [ -n "$ADVISORY_OUTPUT" ]; then
  printf '%s' "$ADVISORY_OUTPUT" | kit_merge_hook_outputs "PreToolUse"
fi

exit 0
