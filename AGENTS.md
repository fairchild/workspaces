# WorkspaceManager - Agent Context

Mac-native app for managing AI coding sessions with embedded terminal.

## How Context Is Organized

This file holds repo-wide invariants plus a routing table; surface guidance lives in nested `AGENTS.md` files (`Sources/`, `Tests/`, `web/`, `web-next/`, `backlog/`). Claude Code auto-loads them per directory; if your harness doesn't, read your surface's file before editing (§ Routing maps tasks to files). `CLAUDE.md` symlinks to `AGENTS.md` at every level — read one, not both.

## Quality and Mergeability

Craft matters. Plan work to land mergeably: correct, native-feeling, tightly scoped, reviewable, evidence-backed, consistent with existing architecture and UI patterns, and leaving the system easier to operate. Before opening or reviewing a PR, run the surface checklist in `docs/development/mergeability-standard.md`; substantive PRs run the `codex-review-loop` skill first (skip codex for metadata/docs-only diffs).

Default to carrying an implementation request through to a PR: branch if needed, edit, verify, commit, rebase on latest `origin/main`, push, open the PR, report status. Pause short of the PR when the user wants exploration only, says not to publish, or evidence/permissions are blocked. At the start of a multi-PR session, propose the authority contract up front (who reviews, who flips ready, who merges).

## Startup Instruction Budget

Root `AGENTS.md` is startup context for every session: keep it under about **4,500 tokens**, measured with a tokenizer (word/char counts are unreliable proxies); nested `AGENTS.md` files are conditional context, same discipline per surface. Encode each lesson at the cheapest surface that fires at the right moment — machinery (CI gates, scripts) over skills over linked docs over these files — and when a lesson graduates upward, delete the prose it replaces.

## Issues, Labels, Coordination

Issues and PRDs live in GitHub Issues for `fairchild/workspaces` (`docs/agents/issue-tracker.md`). Any issue link/number or ask to work an issue is a backlog claim, `backlog` skill named or not: read the issue, apply `claimed` (remove `ready`), post a claim comment naming the active Codex thread title/name and session ID (say explicitly if either is unavailable), then follow the lifecycle in `backlog/AGENTS.md`.

Labels: `agent`/`human` ownership, `ready`/`claimed`/`review`/`mergeable` lifecycle, `needs-human` only for human-intervention blockers. **Agent-authored PRs carry exactly one `author:<agent>` label** naming yourself (e.g. `author:claude-code`), created if missing. Both: `docs/agents/triage-labels.md` (slugs: § "Author Labels").

Agents coordinate through the GitHub-native state machine — issue labels and PR review, not chat or Discussions (why: `docs/decisions/factory-label-control-plane.md`).

## Evidence-Driven Development

Evidence is a merge gate. Do not create a PR without it. In order:

1. **Run tests** — `swift test`, `cd web-next && pnpm test`, or `cd web && pnpm test`
2. **Capture evidence** — for macOS-app UI, first choice is the app evidence lane: `./scripts/evidence.sh --pr <number> --fixture <scenario>` (fixture state, operator-scope window snapshot, upload — no activation, no focus steal). Otherwise `./scripts/evidence.sh --pr <number> --name <slug>` (test output; web screenshots without auth: `mise run web:dev`).
3. **Paste the uploaded evidence URLs into the PR body**
4. **Only then create the PR** — no `[pending-ci]` unless evidence is genuinely impossible locally

Rules: no local-only proof (upload via `evidence.sh`); blocked evidence is an explicit state (`blocked on evidence` in the PR, with why); performance-sensitive changes need before/after/delta baselines in the PR body. Setup, token sourcing, fallback lanes, troubleshooting: `docs/development/evidence.md`. Remote (claude.ai) sessions lack the token, mise, and a matching Playwright browser — sanctioned workarounds: `docs/development/remote-sessions.md`.

## High-Signal Lessons (unconditional)

- **Every lane needing macOS is GitHub-hosted `macos-15`** — generic build/test, the UI smoke lane (`ui-smoke-advisory.yml`), agent evidence (`_evidence.yml`), and release/signing/notarization; agent and metadata jobs run `ubuntu-latest`. No self-hosted runner is registered for this repo at all — `blue-workspaces` was deregistered on 2026-08-13, after `lume-macos` and `tart-ui` — so `.github/actionlint.yaml` allows no self-hosted label and a `runs-on` naming one fails lint. Reaching for `signing-host` does not fall back to hosted; it queues forever. Perf benchmarks are not a CI lane: they run laptop-local, opt-in per run, per `docs/decisions/perf-measurement-laptop-optin.md`.
- **Ship a diagnostic probe instead of your third guess.** When you're guessing, stop and instrument.
- **The tracker lags the code — verify before planning from it.** Before sequencing work from open issues, `rg` the acceptance criteria against the tree; close what's done in the same cycle that ships it (`Closes #N` in every implementing PR).

Full ledger with history and the surface-specific lessons: `docs/agents/lessons.md`.

## Conventions

- Commit hygiene: no screenshot artifacts (`output/`) unless explicitly requested. Never `rm -rf` build/test state — it trips shell-permission prompts that stall unattended sessions; use the surface's allowlisted cleaner (its `AGENTS.md`) or an existing script/mise task; file the gap if none fits.
- New standalone Python utilities: single-file UV scripts (`#!/usr/bin/env -S uv run --script` + PEP 723 block), invoked as `uv run --script <path>` in docs/examples; package layout only when explicitly requested or tooling requires it.
- File purpose blocks: files whose purpose isn't obvious from the name open with a ≈2–4 line present-tense what-and-why block. Add one when creating or substantially editing such a file; keep them accurate — `head`/`rg` over these blocks is the fast exploration index.
- Two web apps, not interchangeable: `web-next/` is active (all new web work); `web/` is maintenance mode.
- Any script or automation that launches the app headlessly sets `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1` — never steal desktop focus (activation modes: `Sources/AGENTS.md` § Key Patterns).
- Don't modify `Package.swift` unless adding dependencies.

## Quick Commands

```bash
./scripts/build-ghosttykit.sh  # Build GhosttyKit.xcframework (once / after pin changes)
swift build / swift test / swift run
mise run lint                  # swift-format lint --strict (CI fails without it)
./scripts/evidence.sh --pr <N> --name <slug>   # required before PRs
```

## Routing

| Working on | Read first |
|---|---|
| Planning or any non-trivial change | `GLOSSARY.md` (product domain language); `CONTEXT-MAP.md` → `docs/agents/GLOSSARY.md` (Factory language) |
| Terminal / keyboard / sidebar / desktop UI | `Sources/AGENTS.md` (dev-verification loop **required**); runbook: `docs/development/libghostty-integration.md` § "Agent self-verification runbook" |
| Swift tests | `Tests/AGENTS.md` |
| `web/` dashboard (maintenance mode) | `web/AGENTS.md` |
| `web-next/` (active web app) | `web-next/AGENTS.md`, then `web-next/CONTRIBUTING.md` |
| Issue lifecycle / backlog | `backlog/AGENTS.md` |
| Lume VMs | `mise run dev-lume-ensure` first; `docs/development/lume-integration.md` |
| Release / signing / notarization | `RELEASING.md`; runner lanes: `CONTRIBUTING.md` § "CI Runner Lanes" |
| Milestone delivery / subagent fan-out | `.agents/skills/drive/SKILL.md` / `.agents/skills/subagent-delegation/SKILL.md` |
| Symbol/task → file lookup | `docs/agents/code-map.md` |
| Lessons ledger | `docs/agents/lessons.md` |
| Architecture decisions / product domain | `docs/decisions/`, `docs/agents/domain.md` |
| HTML prototypes | `prototypes/README.md` |
| Original spec | `docs/original_spec.md` — find the component you need; don't read it entirely |
