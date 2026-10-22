#!/usr/bin/env bash
# Copyright 2026 The agentic-workflow-kit Authors
# SPDX-License-Identifier: MIT
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$KIT_ROOT" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as scratch:
    fixture = Path(scratch)
    for hook, plugin, delegate in [
        ('pre-push', 'ship', 'pre-push-pr-drift-check.sh'),
        ('post-checkout', 'worktrees', 'worktree-hydrate.sh'),
    ]:
        marker = fixture / (hook + '.result')
        env = dict(os.environ, HOME=str(fixture))
        env.pop('AGENTIC_KIT_SHIP_DIR', None)
        env.pop('AGENTIC_KIT_WORKTREES_DIR', None)
        for marketplace in ['agentic-workflow-kit', 'unrelated-marketplace']:
            delegate_path = fixture / '.claude/plugins/cache' / marketplace / plugin / '1/scripts' / delegate
            delegate_path.parent.mkdir(parents=True)
            delegate_path.write_text('#!/bin/bash\nprintf "%s" "' + marketplace + '" > "' + str(marker) + '"\n')
            if marketplace == 'unrelated-marketplace':
                os.utime(delegate_path, (2000000000, 2000000000))
        subprocess.run(['bash', str(root / 'plugins/starter/files/githooks' / hook), '00000000', 'new', '1'], env=env, input=b'', check=True)
        assert marker.read_text() == 'agentic-workflow-kit', hook + ' delegated to another marketplace'
        marker.unlink()
        own = fixture / '.claude/plugins/cache/agentic-workflow-kit' / plugin / '1/scripts' / delegate
        own.unlink()
        subprocess.run(['bash', str(root / 'plugins/starter/files/githooks' / hook), '00000000', 'new', '1'], env=env, input=b'', check=True)
        assert not marker.exists(), hook + ' fell back to another marketplace'
print('passed=4 failed=0')
PY
