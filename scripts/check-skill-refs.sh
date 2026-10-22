#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
#
# Flags a bare `/<skill>` reference that names a shipped skill in place of its plugin-qualified
# name, for example the sweep skill without its `/ship:` prefix. Claude Code invokes a plugin
# skill only by the qualified name, so a bare one in a skill, script message or doc points the
# agent at a command that does not exist. Scans every *.md, *.sh, *.json, *.yaml, *.yml, *.toml and *.rules
# file and the starter githooks under the root, outside .git.
#
# Not flagged: a path or file name (`skills/pr/`, `setup.sh`), a qualified name
# (`/ship:pr`), and the fixture lines below, which test how a user's own CLAUDE.md with a bare
# kit skill name is treated, so the bare name is the point of the line. This script's own test
# plants bare names on purpose and is skipped.
#
# Usage: check-skill-refs.sh [root]   (default: the repo this script is in)
# Prints one `<file>:<line>: bare /<skill>, write /<plugin>:<skill>` per hit.
# Exit 0 clean, 1 on any hit, 2 when python3 is missing.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
command -v python3 >/dev/null 2>&1 || { echo "check-skill-refs: python3 is required" >&2; exit 2; }
python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
SKIP = {"scripts/check-skill-refs.test.sh"}
# file (relative to root) -> bare refs it may carry. Each is a fixture of a user's CLAUDE.md.
ALLOW = {
    "examples/edit-time-checks/setup.sh": {"review-panel"},
    "examples/edit-time-checks/story.md": {"review-panel"},
    "plugins/guards/scripts/post-edit-dispatcher.test.sh": {"review-panel"},
    "plugins/guards/scripts/validate-docs.test.sh": {"review-panel", "guide"},
}
skills = {}
pdir = os.path.join(root, "plugins")
for plugin in sorted(os.listdir(pdir)):
    sdir = os.path.join(pdir, plugin, "skills")
    if os.path.isdir(sdir):
        for skill in os.listdir(sdir):
            if os.path.isfile(os.path.join(sdir, skill, "SKILL.md")):
                skills[skill] = plugin
if not skills:
    print("check-skill-refs: no skills found under " + pdir, file=sys.stderr)
    sys.exit(2)
names = sorted(skills, key=len, reverse=True)
rx = re.compile(r"(?<![A-Za-z0-9_.:/~$>-])/(" + "|".join(map(re.escape, names)) +
                r")(?![A-Za-z0-9_-])(?!\.(?:sh|md|json|py|ya?ml|txt)\b)(?!/)")
exts = (".md", ".sh", ".json", ".yaml", ".yml", ".toml", ".rules")
hits = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
    for fn in sorted(filenames):
        path = os.path.join(dirpath, fn)
        rel = os.path.relpath(path, root)
        if rel in SKIP or not (fn.endswith(exts) or "/githooks/" in "/" + rel):
            continue
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for n, line in enumerate(text.split("\n"), 1):
            for m in rx.finditer(line):
                s = m.group(1)
                if s in ALLOW.get(rel, ()):
                    continue
                print(f"{rel}:{n}: bare /{s}, write /{skills[s]}:{s}")
                hits += 1
sys.exit(1 if hits else 0)
PY
