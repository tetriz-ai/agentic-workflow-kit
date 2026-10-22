# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-22

### Added

- Initial release.
- A selectable plugin marketplace for Claude Code and Codex: review, review-lenses, ship, plan, queue, worktrees, guards, learn and starter, plus an `all` bundle.
- A review panel of focused lenses with cross-model Codex, Claude and open-code-review lenses, a review cadence nudge and opt-in domain lenses chosen by the files a diff touches.
- Guard hooks: a configurable commit gate, a lockfile sync gate, pinned `npx`, format on edit, and generated-file and doc-health advisories.
- Skills to ship and plan work: pull requests, PR feedback, the hosted Codex reviewer sweep, GitHub issues, design docs, task breakdowns, ADRs, and queue and bug-hunt runs, plus `/starter:setup` for the repo files and a bridge for Codex.

[Unreleased]: https://github.com/tetriz-ai/agentic-workflow-kit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/tetriz-ai/agentic-workflow-kit/releases/tag/v0.1.0
