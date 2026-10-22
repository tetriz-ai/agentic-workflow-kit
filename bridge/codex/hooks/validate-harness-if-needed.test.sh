#!/bin/bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -euo pipefail

# The helper and the symlink check are the bridge's own sources, copied into a fixture laid
# out the way the bridge installs them.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$HERE/validate-harness-if-needed.sh"
# The kit (bridge/codex/hooks beside bridge/agent-harness) or an installed repo (.codex/hooks
# beside .agent-harness).
AGENT_HARNESS="$(cd "$HERE/../../agent-harness" 2>/dev/null || cd "$HERE/../../.agent-harness" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/.codex/hooks" "$fixture/.codex/agents" "$fixture/.agent-harness"
cp "$helper" "$fixture/.codex/hooks/validate-harness-if-needed.sh"
cp "$AGENT_HARNESS/check-skill-directory-symlinks.sh" "$fixture/.agent-harness/check-skill-directory-symlinks.sh"
printf 'config\n' >"$fixture/.codex/config.toml"
printf 'agent\n' >"$fixture/.codex/agents/example.toml"
printf '#!/bin/bash\nexit 0\n' >"$fixture/.codex/hooks/probe.sh"
printf '#!/bin/bash\nset -eu\nprintf "run\\n" >>"$VALIDATION_COUNT"\n.agent-harness/check-skill-directory-symlinks.sh\n[ "${VALIDATION_SHOULD_FAIL:-0}" != 1 ]\n' >"$fixture/.agent-harness/validate-codex-harness.sh"
chmod +x "$fixture/.codex/hooks/validate-harness-if-needed.sh" "$fixture/.codex/hooks/probe.sh" "$fixture/.agent-harness/validate-codex-harness.sh" "$fixture/.agent-harness/check-skill-directory-symlinks.sh"
git -C "$fixture" init -q
git -C "$fixture" config user.email codex-harness@example.com
git -C "$fixture" config user.name "Codex Harness"
git -C "$fixture" add .
git -C "$fixture" commit -qm init

cache_dir="$fixture/cache"
count_file="$fixture/count"
run_helper() {
  (
    cd "$fixture"
    AGENTIC_KIT_CODEX_HARNESS_CACHE_DIR="$cache_dir" \
      VALIDATION_COUNT="$count_file" \
      .codex/hooks/validate-harness-if-needed.sh >/dev/null
  )
}
assert_runs() {
  local expected="$1"
  local actual=0
  if [ -f "$count_file" ]; then
    actual="$(wc -l <"$count_file" | tr -d '[:space:]')"
  fi
  [ "$actual" = "$expected" ] || {
    echo "expected $expected validator runs, found $actual" >&2
    exit 1
  }
}

run_helper
run_helper
assert_runs 1

git -C "$fixture" config core.filemode false
chmod -x "$fixture/.codex/hooks/probe.sh"
run_helper
assert_runs 2
chmod +x "$fixture/.codex/hooks/probe.sh"
run_helper
assert_runs 3
git -C "$fixture" config core.filemode true
rm -rf "$cache_dir"
rm -f "$count_file"
run_helper
run_helper
assert_runs 1

bad_bin="$fixture/bad-bin"
mkdir -p "$bad_bin"
printf '#!/bin/bash\nexit 1\n' >"$bad_bin/yq"
chmod +x "$bad_bin/yq"
if (
  cd "$fixture"
  PATH="$bad_bin:$PATH" \
    AGENTIC_KIT_CODEX_HARNESS_CACHE_DIR="$cache_dir" \
    VALIDATION_COUNT="$count_file" \
    .codex/hooks/validate-harness-if-needed.sh >/dev/null 2>&1
); then
  echo "expected a cache hit to recheck environment prerequisites" >&2
  exit 1
fi
assert_runs 1
rm "$bad_bin/yq"

printf '#!/bin/bash\ncase "$*" in *version_info*) exit 1 ;; *) exit 0 ;; esac\n' >"$bad_bin/python3"
chmod +x "$bad_bin/python3"
if (
  cd "$fixture"
  PATH="$bad_bin:$PATH" \
    AGENTIC_KIT_CODEX_HARNESS_CACHE_DIR="$cache_dir" \
    VALIDATION_COUNT="$count_file" \
    .codex/hooks/validate-harness-if-needed.sh >/dev/null 2>&1
); then
  echo "expected a cache hit to reject Python older than 3.9" >&2
  exit 1
fi
assert_runs 1
rm "$bad_bin/python3"

printf '#!/bin/bash\nexit 1\n' >"$bad_bin/basename"
chmod +x "$bad_bin/basename"
if (
  cd "$fixture"
  PATH="$bad_bin:$PATH" \
    AGENTIC_KIT_CODEX_HARNESS_CACHE_DIR="$cache_dir" \
    VALIDATION_COUNT="$count_file" \
    .codex/hooks/validate-harness-if-needed.sh >/dev/null 2>&1
); then
  echo "expected a cache hit to reject an unusable basename" >&2
  exit 1
fi
assert_runs 1
rm "$bad_bin/basename"

printf 'dirty\n' >>"$fixture/.codex/config.toml"
run_helper
assert_runs 2
printf 'dirtier\n' >>"$fixture/.codex/config.toml"
run_helper
assert_runs 3

printf 'untracked\n' >"$fixture/.codex/agents/untracked.toml"
run_helper
assert_runs 4
rm "$fixture/.codex/agents/untracked.toml"
run_helper
assert_runs 5

printf '.codex/hooks/ignored.sh\n.claude/triage/session-context/\n.claude/skills/*/working/\n' >"$fixture/.gitignore"
git -C "$fixture" add .gitignore
git -C "$fixture" commit -qm ignores
printf '#!/bin/bash\n' >"$fixture/.codex/hooks/ignored.sh"
run_helper
assert_runs 6
chmod +x "$fixture/.codex/hooks/ignored.sh"
run_helper
assert_runs 7

mkdir -p "$fixture/.claude/triage/session-context"
printf 'ambient one\n' >"$fixture/.claude/triage/session-context/current.md"
run_helper
assert_runs 7
printf 'ambient two\n' >>"$fixture/.claude/triage/session-context/current.md"
run_helper
assert_runs 7

mkdir -p "$fixture/.claude/skills/example/working"
printf 'large transient report\n' >"$fixture/.claude/skills/example/working/report.md"
run_helper
assert_runs 7
printf 'changed transient report\n' >>"$fixture/.claude/skills/example/working/report.md"
run_helper
assert_runs 7

mkdir -p "$fixture/.claude/skills/linked"
printf '%s\n' '---' 'name: linked' 'description: linked' '---' >"$fixture/external-skill.md"
ln -s ../../../external-skill.md "$fixture/.claude/skills/linked/SKILL.md"
run_helper
run_helper
assert_runs 8
printf 'changed target\n' >>"$fixture/external-skill.md"
run_helper
assert_runs 9
chmod +x "$fixture/external-skill.md"
run_helper
assert_runs 10
chmod -x "$fixture/external-skill.md"
run_helper
assert_runs 11

rm "$fixture/.codex/agents/example.toml"
run_helper
assert_runs 12

rm -rf "$cache_dir"
if (
  cd "$fixture"
  AGENTIC_KIT_CODEX_HARNESS_CACHE_DIR="$cache_dir" \
    VALIDATION_COUNT="$count_file" \
    VALIDATION_SHOULD_FAIL=1 \
    .codex/hooks/validate-harness-if-needed.sh >/dev/null 2>&1
); then
  echo "expected failed validation" >&2
  exit 1
fi
if (
  cd "$fixture"
  AGENTIC_KIT_CODEX_HARNESS_CACHE_DIR="$cache_dir" \
    VALIDATION_COUNT="$count_file" \
    VALIDATION_SHOULD_FAIL=1 \
    .codex/hooks/validate-harness-if-needed.sh >/dev/null 2>&1
); then
  echo "expected repeated failed validation" >&2
  exit 1
fi
assert_runs 14

rm -rf "$cache_dir"
mkdir -m 777 "$cache_dir"
run_helper
run_helper
assert_runs 16

rm -rf "$cache_dir"
run_helper
assert_runs 17
stamp="$(find "$cache_dir" -maxdepth 1 -name '*.quick' -type f -print -quit)"
[ -n "$stamp" ] || {
  echo "expected a cache stamp" >&2
  exit 1
}
mv "$stamp" "$stamp.real"
ln -s "$stamp.real" "$stamp"
run_helper
run_helper
assert_runs 19

rm -rf "$cache_dir" "$fixture/.claude/skills/example/working"
run_helper
assert_runs 20
ln -s ../../../ignored-skill-target "$fixture/.claude/skills/example/working"
run_helper
assert_runs 21
mkdir -p "$fixture/ignored-skill-target"
if run_helper >/dev/null 2>&1; then
  echo "expected ignored nested skill-directory symlink validation to fail" >&2
  exit 1
fi
if run_helper >/dev/null 2>&1; then
  echo "expected ignored nested skill-directory symlink validation to fail repeatedly" >&2
  exit 1
fi
assert_runs 23

echo "validate-harness-if-needed tests passed."
