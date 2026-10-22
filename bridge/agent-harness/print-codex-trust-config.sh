#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

cat <<EOF
# Add this to ~/.codex/config.toml, then start a new Codex session in this repo.
[projects."$ROOT"]
trust_level = "trusted"
EOF
