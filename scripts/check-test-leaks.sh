#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Runs each *.test.sh and reports any test that leaves behind a temp dir or file it created
# with `mktemp` and did not remove. Exit 1 on a leak. Nothing is ever removed.
# TMPDIR points at an empty directory first, and that directory is compared before and after.
# Where mktemp ignores TMPDIR (seen on macOS), its output lands in the system temp folder, which
# every other process of the user shares; there a `mktemp` shim first on PATH logs each path the
# real mktemp returns, and a logged path that still exists after the test is the leak, so other
# processes' files are never counted. A test that calls mktemp by absolute path, or replaces
# PATH, is not seen in that mode. CI's Linux run uses the TMPDIR mode.
# Usage: scripts/check-test-leaks.sh [test path...]   (default: every *.test.sh)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
if [ "$#" -eq 0 ]; then
  set --
  while IFS= read -r t; do set -- "$@" "$t"; done < <(find plugins bridge shared scripts -name '*.test.sh' 2>/dev/null | sort)
fi
REAL_MKTEMP="$(command -v mktemp)"
leaks=0
for t in "$@"; do
  probe="$(mktemp -d)"
  base="$(TMPDIR="$probe" bash -c 'dirname "$(mktemp -u)"')"
  if [ "$base" = "$probe" ]; then
    before="$(ls -A "$base" 2>/dev/null | sort)"
    TMPDIR="$probe" bash "$t" >/dev/null 2>&1
    # xcrun_db is the cache Apple's developer tools write into TMPDIR whenever a test runs one of
    # them (a plain /usr/bin/git does); only that exact top-level name is not the test's leftover.
    new="$(comm -13 <(printf '%s\n' "$before") <(ls -A "$base" 2>/dev/null | sort) | grep -v '^$' | grep -vx 'xcrun_db' || true)"
  else
    # The shim logs every path mktemp hands the test (made absolute), then prints it.
    mkdir "$probe/shim"; : > "$probe/made"
    printf '#!/bin/sh\nout=$("%s" "$@") || exit $?\ncase "$out" in /*) p="$out" ;; *) p="$PWD/$out" ;; esac\nprintf "%%s\\n" "$p" >> "%s"\nprintf "%%s\\n" "$out"\n' \
      "$REAL_MKTEMP" "$probe/made" > "$probe/shim/mktemp"
    chmod +x "$probe/shim/mktemp"
    TMPDIR="$probe" PATH="$probe/shim:$PATH" bash "$t" >/dev/null 2>&1
    new="$(while IFS= read -r f; do [ -n "$f" ] && { [ -e "$f" ] || [ -L "$f" ]; } && printf '%s\n' "$f"; done < "$probe/made" | sort -u)"
  fi
  if [ -n "$new" ]; then
    echo "LEAK: $t left $(printf '%s\n' "$new" | wc -l | tr -d '[:space:]') entr(y/ies) in $base: $(printf '%s\n' "$new" | head -3 | tr '\n' ' ')"
    leaks=$((leaks + 1))
  fi
  rm -rf "$probe"
done
[ "$leaks" -eq 0 ] && echo "no test leaves temp files behind ($# tests)" || { echo "$leaks test(s) leak temp files"; exit 1; }
