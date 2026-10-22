#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Sourced by validate-context-budgets.sh, which parses skill frontmatter with yq.
#
# Resolve yq by PARSING WITH IT, not by looking it up. Two ways a lookup answers wrongly rather than
# emptily: a git client launched from the GUI inherits launchd's PATH, which carries neither
# Homebrew prefix, so an installed yq is invisible to `command -v`; and kislyuk's python-yq answers
# to the same name, satisfies `command -v`, and rejects `-o json`, which would report every file it
# is pointed at as malformed.
#
# Prints the resolved binary on success; returns 1 having printed nothing when none works.
resolve_yq() {
  local cand
  for cand in yq /opt/homebrew/bin/yq /usr/local/bin/yq; do
    if printf 'probe: 1\n' | "$cand" -o json . >/dev/null 2>&1; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

# The message every caller gives when resolve_yq comes back empty.
yq_missing_hint() {
  echo "no working yq found, and this gate parses YAML with it. It needs mikefarah's yq —" >&2
  echo "kislyuk's python-yq answers to the same name and will not do. Install it:" >&2
  echo "  brew install yq   (or download a release from https://github.com/mikefarah/yq)" >&2
}
