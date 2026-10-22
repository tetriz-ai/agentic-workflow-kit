# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# shellcheck shell=bash
# Library: worktree-aware cwd resolution for PreToolUse(Bash) git hooks.
#
# Sourced by review-cadence.sh (review plugin) and by commit-gate.sh and
# lockfile-gate.sh (guards plugin); each plugin carries a byte-identical copy. The
# Bash tool reports the SESSION cwd, so worktree work done via an inline
# `cd <wt> && git ...` would otherwise be attributed to the main checkout, keying
# cadence state, or running a commit or lockfile DENY gate, against the wrong tree.
# These helpers recover the real target before resolving the repo toplevel.
#
# Callers may run under `set -e`: every function returns 0 / falls back to empty,
# so a no-match never aborts the caller. The source line in each hook is
# unguarded on purpose — for a DENY gate a missing lib must fail LOUD, not let the
# gate mis-resolve silently.
#
#   git_toplevel <dir>           -> repo toplevel for <dir>, empty on failure.
#   tool_cwd <payload>           -> the directory a hook's command runs in: Codex's
#                                   `tool_input.workdir` (or `input.workdir`, `workdir`),
#                                   else the payload's `cwd`; empty when none. Needs jq.
#   leading_cd_dir <cmd> <base>  -> a leading `cd <dir>` target resolved against
#                                   <base>, else empty.
#   simple_commands <cmd> <name>...
#                                -> each simple command in <cmd> run as one of <name>,
#                                   from that word on, one per line.
#   find_git_sub <cmd> <sub> <base>
#                                -> prints "1 <dir>" when a simple command in <cmd>
#                                   runs `git <sub>` (<dir>: its `-C` directories
#                                   resolved against <base>, else empty), else "0".
#                                   Read it with `read -r found dir < <(find_git_sub ...)`.
#
# Scope: leading_cd_dir recognises a leading `cd <dir>` (the inline-cd worktree form),
# also inside a leading `(` or `{`; a SECOND bare `cd` it deliberately bails on.
# find_git_sub reads `git -C <dir>`. `pushd`, a `cd` later in the command, and a git
# named through a variable (`G=git; $G commit`) are not followed, so a DENY-gate caller
# is best-effort for those forms, not airtight; the repo's merge gate is the backstop.

# tool_cwd <payload>: the first non-empty of tool_input.workdir, input.workdir, workdir, cwd. A
# relative workdir is joined onto the payload's cwd, not the hook process's own directory.
# `//` is not used: it only skips null/false, so `"workdir":""` would shadow the cwd.
tool_cwd() {
  printf '%s' "$1" | jq -r '
    def str: if type == "string" and . != "" then . else null end;
    (.cwd | str) as $cwd
    | ([.tool_input.workdir, .input.workdir, .workdir] | map(str) | map(select(. != null)) | first) as $w
    | if $w == null then ($cwd // empty)
      elif ($w | startswith("/")) or $cwd == null then $w
      else ($cwd | rtrimstr("/")) + "/" + $w end' 2>/dev/null || true
}

# Resolve the git toplevel for a directory; empty string on failure.
git_toplevel() {
  local dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  # `cd --` so a dir that begins with `-` is treated as a path, not an option.
  (cd -- "$dir" && git rev-parse --show-toplevel 2>/dev/null) || true
}

# leading_cd_dir extracts a leading `cd <dir>` target from a compound command
# (`cd <dir> && ...` or `cd <dir>; ...`). The Bash tool reports the session cwd,
# so worktree work done via inline cd would otherwise be attributed to the main
# checkout and the cadence state keyed there. A relative target resolves
# against base; empty for commands with no leading cd.
leading_cd_dir() {
  local cmd="$1" base="$2" rest target
  rest=${cmd#"${cmd%%[![:space:]]*}"}
  # A leading subshell or group: `(cd <dir> && ...)`, `{ cd <dir>; ...; }`.
  while :; do
    case "$rest" in
      '('*) rest=${rest#\(} ;;
      '{'[[:space:]]*) rest=${rest#\{} ;;
      *) break ;;
    esac
    rest=${rest#"${rest%%[![:space:]]*}"}
  done
  case "$rest" in
    cd[[:space:]]*) ;;
    *) return 0 ;;
  esac
  rest=${rest#cd}
  rest=${rest#"${rest%%[![:space:]]*}"}
  # Strip any `cd` option flags (-L/-P/-e/-@, combinable) before the path token,
  # honouring `--` as end-of-options. Without this, `cd -P <wt> && git commit` —
  # a common symlink-resolving inline-cd form — would extract `-P` as the target,
  # drop the real worktree path, and fall back to the tool cwd, silently skipping
  # the gate this resolves for.
  while :; do
    case "$rest" in
      --[[:space:]]*) rest=${rest#--}; rest=${rest#"${rest%%[![:space:]]*}"}; break ;;
      --)             return 0 ;;
      -*)             local flag=${rest%%[[:space:]]*}; rest=${rest#"$flag"}; rest=${rest#"${rest%%[![:space:]]*}"} ;;
      *)              break ;;
    esac
  done
  local after
  case "$rest" in
    \"*) target=${rest#\"}; target=${target%%\"*}; after=${rest#\"*\"} ;;
    \'*) target=${rest#\'}; target=${target%%\'*}; after=${rest#\'*\'} ;;
    *)   target=${rest%%[[:space:];&|]*}; after=${rest#"$target"} ;;   # stop at a separator or whitespace
  esac
  # A second leading `cd` means the git command runs in a LATER cwd than this
  # first target (`cd A && cd B && git commit` lands in B, not A). Attribution is
  # then ambiguous, so bail to the safe fallback rather than mis-key cadence state
  # on the wrong worktree. `after` is whatever follows this cd's target;
  # strip the leading separator run and check whether the next command is `cd`.
  after=${after#"${after%%[![:space:];&|]*}"}
  case "$after" in cd[[:space:]]*) return 0 ;; esac
  # Expand a leading ~ (a common inline-cd form). $VAR and other shell expansions
  # are left as-is — they cannot be expanded without eval, and an unresolved
  # target safely falls back to the tool cwd via git_toplevel below.
  case "$target" in
    \~)   [ -n "${HOME:-}" ] && target=$HOME ;;
    \~/*) [ -n "${HOME:-}" ] && target=$HOME/${target#\~/} ;;
  esac
  [ -n "$target" ] || return 0
  case "$target" in
    /*) printf '%s' "$target" ;;
    *)  if [ -n "$base" ]; then printf '%s/%s' "$base" "$target"; else printf '%s' "$target"; fi ;;
  esac
}

# simple_commands <cmd> <name>...: prints one line per simple command in <cmd> whose command
# word is one of <name> (or a path ending in /<name>): that word and the words after it,
# separated by single spaces. <cmd> is split on `; & | ( ) { }`, backticks and newlines, with
# quote marks and backslashes dropped (so `bash -c "git commit"` and `\git commit` are read,
# and `echo "git commit"` is an echo). Before the command word a piece may hold `VAR=value`
# assignments, shell keywords (`if`, `then`, `!`, ...), wrappers (`env`, `sudo`, `doas`,
# `time`, `timeout`, `command`, `exec`, `nice`, `nohup`, `xargs`, `stdbuf`, `ionice`,
# `caffeinate`, `eval`, `builtin`, with their options and a numeric argument such as a
# timeout's duration) and `sh -c`/`bash -c`. Returns 0.
simple_commands() {
  local cmd="$1" seg tok i n wrapped name hit
  shift
  local -a w
  while IFS= read -r seg; do
    read -r -a w <<<"$seg"
    n=${#w[@]}; i=0; wrapped=0; hit=0
    while [ "$i" -lt "$n" ]; do
      tok=${w[$i]}
      for name in "$@"; do
        case "$tok" in "$name"|*/"$name") hit=1 ;; esac
      done
      [ "$hit" = 1 ] && break
      case "$tok" in
        [A-Za-z_]*=*) i=$((i + 1)); continue ;;
        if|then|else|elif|do|while|until|'!'|time|env|command|exec|sudo|doas|nice|nohup|builtin|eval|timeout|xargs|stdbuf|ionice|caffeinate)
          wrapped=1; i=$((i + 1)); continue ;;
        sh|bash|zsh|dash|ksh|*/sh|*/bash|*/zsh|*/dash|*/ksh)
          case "${w[$((i + 1))]:-}" in -*c*) wrapped=1; i=$((i + 2)); continue ;; esac ;;
      esac
      if [ "$wrapped" -eq 1 ] && { [[ "$tok" == -* ]] || [[ "${w[$((i - 1))]}" == -* ]] || [[ "$tok" =~ ^[0-9][0-9.]*[smhd]?$ ]]; }; then
        i=$((i + 1)); continue
      fi
      break
    done
    [ "$hit" = 1 ] || continue
    printf '%s\n' "${w[*]:$i}"
  done < <(printf '%s\n' "$cmd" | tr -d "\"'\\\\" | tr ';&|(){}`' '\n\n\n\n\n\n\n\n')
  return 0
}

# find_git_sub <cmd> <sub> <base>: does any simple command in <cmd> (see simple_commands) run
# `git <sub>`? After `git` or a path ending in `/git` come git's global options, then the
# subcommand, which must equal <sub> exactly (`commit-graph` is not `commit`) or be an alias
# whose first word is <sub> in the repo the command runs in. Prints "1 <dir>" (<dir>: its `-C`
# directories resolved against <base>, else empty) or "0"; returns 0.
find_git_sub() {
  local cmd="$1" sub="$2" base="$3" line tok i n dir alias_val
  local -a w
  while IFS= read -r line; do
    read -r -a w <<<"$line"
    n=${#w[@]}; i=1; dir=""
    while [ "$i" -lt "$n" ]; do
      tok=${w[$i]}
      case "$tok" in
        -C) dir="${dir:+$dir/}${w[$((i + 1))]:-}"; case "${w[$((i + 1))]:-}" in /*) dir=${w[$((i + 1))]} ;; esac; i=$((i + 2)) ;;
        -c|--git-dir|--work-tree|--namespace|--config-env) i=$((i + 2)) ;;
        -*) i=$((i + 1)) ;;
        *) break ;;
      esac
    done
    [ "$i" -lt "$n" ] || continue
    if [ -n "$dir" ]; then
      case "$dir" in
        \~)   dir=${HOME:-\~} ;;
        \~/*) dir=${HOME:-\~}/${dir#\~/} ;;
      esac
      case "$dir" in
        /*) ;;
        *)  dir=${base:+$base/}$dir ;;
      esac
    fi
    if [ "${w[$i]}" != "$sub" ]; then
      # An alias in the repo the command runs in (`git ci` with alias.ci=commit).
      alias_val=$(git -C "${dir:-${base:-.}}" config --get "alias.${w[$i]}" 2>/dev/null || true)
      [ "${alias_val%%[[:space:]]*}" = "$sub" ] || continue
    fi
    printf '1 %s\n' "$dir"
    return 0
  done < <(simple_commands "$cmd" git)
  printf '0\n'
  return 0
}
