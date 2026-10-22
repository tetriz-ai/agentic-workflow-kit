# Validating the review cadence + panel

How to confirm this harness piece actually does what it intends - the cadence
auto-nudges, the nudge reaches the agent, and the panel reviews and grades.
Three layers, cheapest first.

## Layer 1 - logic (automated, re-runnable)

Proves the hook counts correctly, emits the right nudge JSON at the threshold,
never blocks, and is worktree-isolated. Feeds the exact stdin JSON Claude Code
sends and asserts the exact `additionalContext` JSON it consumes.

```bash
# from a clone of the kit
bash plugins/review/scripts/review-cadence.test.sh   # expect: ... failed=0
bash plugins/review/skills/codex-lens/scripts/codex-lens.test.sh
bash plugins/review/skills/claude-lens/scripts/claude-lens.test.sh
bash plugins/review/skills/review-panel/scripts/counterpart-lens.test.sh
```

The counterpart suite also proves the Codex lens contract for non-Codex authoring
sessions: it routes the Claude marker, an arbitrary explicit runtime name, and the
no-Codex-marker default to the real Codex lens with a stubbed CLI. The Claude case
also asserts the existing model, effort, sandbox, prompt, and status grammar.

## Layer 2 - mechanism (one-time, per Claude Code version)

Proves a PreToolUse hook's `hookSpecificOutput.additionalContext` actually
reaches the agent's context on this version (it is in the binary's Zod
validator and the injection path is not event-gated). To re-prove on a new
version, wire a throwaway PreToolUse(Bash) hook that emits
`{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"<sentinel>"}}`
for a sentinel command, reload, run the sentinel command, and confirm the
sentinel appears in the agent context (it must NOT be in the command's own
stdout, so the only path it could arrive is the injection).

Also verify the runtime marker and Claude CLI contract on each supported CLI
version. A Claude child command must see `CLAUDE_CODE_SESSION_ID`; a Codex shell
must see `CODEX_SESSION_ID`. Run `claude --help` and confirm the lens flags remain
available, then execute one authenticated `claude-lens.sh` smoke against a small
committed range. A supported runtime's missing marker, an unsupported flag, or a
non-`FINDINGS` result is a lens failure—not a clean review. Unknown non-Codex
runtimes intentionally take the audited `source=default engine=codex` route.

## Layer 3 - end-to-end live smoke (the real proof)

Proves the whole chain in a real session: commit cadence -> hook computes the
count -> nudge lands in the agent's context with no prompting -> panel runs.

1. Temporarily activate the hook with a low threshold so it fires fast. In a
   settings file the session loads (`.claude/settings.local.json`), add:
   ```json
   { "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
       { "type": "command",
         "command": "REVIEW_CADENCE_COMMITS=2 REVIEW_CADENCE_LINES=50 <abs path>/plugins/review/scripts/review-cadence.sh",
         "timeout": 10 } ] } ] } }
   ```
   (Use an absolute path to the script in a clone of the kit. With the plugin installed, set
   the plugin's `review_cadence_commits` and `review_cadence_lines` settings instead.)
2. Reload the session (settings/hooks are snapshotted at session start).
3. `rm -rf .claude/review-cadence` to start the count clean.
4. Make commits: `git commit --allow-empty -m smoke-N`. The 1st initializes the
   baseline silently; once `git rev-list --count baseline..HEAD` reaches the
   threshold, the next `git commit` PreToolUse injects the `[review-cadence]`
   nudge into the agent context - visible with no prompting.
5. The commit must still succeed (soft / non-blocking).
6. Run `/review:review-panel cadence` to confirm the fan-out runs and resets the cadence.
7. Tear down: run the smoke in a throwaway repo and delete it, or remove the temporary hook
   from settings and `rm -rf .claude/review-cadence`.

## What "passing" looks like

- Layer 1: `FAIL=0`.
- Layer 2: the sentinel token shows up in the agent context.
- Layer 3: after the threshold commit, the `[review-cadence]` nudge appears
  automatically; the commit is not blocked; `/review:review-panel` returns graded
  findings (or "nothing to review" on an empty diff) and rebaselines.
