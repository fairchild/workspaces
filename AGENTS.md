# WorkspaceManager - Agent Context

Mac-native app for managing AI coding sessions with embedded terminal.

## How Context Is Organized

This file carries repo-wide invariants and a routing table; surface-specific guidance lives in nested `AGENTS.md` files (`Sources/`, `Tests/`, `web/`, `web-next/`, `backlog/`), which Claude Code loads automatically when working under those directories. If your harness doesn't auto-load nested files, read the file for the surface you're touching before editing — the § Routing table maps tasks to files. `CLAUDE.md` is a symlink to `AGENTS.md` at every level; read one, not both.

## Quality and Mergeability

Craft matters. Plan work so it can land mergeably: correct, coherent with the product, reviewable, verified, and leaving the system easier to operate. Keep changes native-feeling, tightly scoped, evidence-backed, and consistent with existing architecture and UI patterns. Before opening or reviewing a PR, use `docs/development/mergeability-standard.md` for the surface-specific checklist. Substantive PRs run the `codex-review-loop` skill before opening (skip codex for metadata/docs-only diffs).

When the user asks to implement a change, default to carrying it through to a PR: branch if needed, make the edit, verify it, commit, rebase on the latest `origin/main`, push, open the PR, and report its status. Pause short of PR creation when the user asks for exploration only, says not to publish, or evidence/permissions are blocked. At the start of a multi-PR working session, propose the authority contract explicitly (who reviews, who flips ready, who merges) instead of discovering it one approval at a time.

## Startup Instruction Budget

Root `AGENTS.md` is startup context for every session: keep it under about **4,500 tokens**, measured directly with a tokenizer — word/char counts are not reliable proxies. Nested `AGENTS.md` files are conditional context; the same discipline applies per surface. When encoding a lesson, place it at the cheapest surface that fires at the right moment — machinery (CI gates, scripts) over skills, skills over linked docs, these files last — and when a lesson graduates upward, delete the prose it replaces.

## Issues, Labels, Coordination

Issues and PRDs live in GitHub Issues for `fairchild/workspaces` (`docs/agents/issue-tracker.md`). When the user asks to work an issue or gives an issue link/number, treat it as a backlog claim even if the `backlog` skill was not named: read the issue, apply the `claimed` label (removing `ready` if present), post a claim comment naming the active Codex thread title/name and session ID — say so explicitly if either is unavailable — then continue through the lifecycle in `backlog/AGENTS.md`.

Labels: `agent`/`human` for ownership, `ready`/`claimed`/`review`/`mergeable` for lifecycle, `needs-human` only for human intervention blockers (`docs/agents/triage-labels.md`). **Agent-authored PRs carry exactly one `author:<agent>` label** naming yourself (e.g. `author:claude-code`), created if missing — slug rules: `docs/agents/triage-labels.md` § "Author Labels".

Agents coordinate through the GitHub-native state machine — issue labels and PR review, not chat or Discussions (why: `docs/decisions/factory-label-control-plane.md`).

## Evidence-Driven Development

Evidence is a merge gate. Do not create a PR without it. In order:

1. **Run tests** — `swift test`, `cd web-next && pnpm test`, or `cd web && pnpm test`
2. **Capture evidence** — for macOS-app UI, first choice is the app evidence lane: `./scripts/evidence.sh --pr <number> --fixture <scenario>` (fixture state, operator-scope window snapshot, upload — no activation, no focus steal). Otherwise `./scripts/evidence.sh --pr <number> --name <slug>` (test output; web screenshots without auth: `mise run web:dev`).
3. **Paste the uploaded evidence URLs into the PR body**
4. **Only then create the PR** — no `[pending-ci]` unless evidence is genuinely impossible locally

Rules: no local-only proof (upload via `evidence.sh`); blocked evidence is an explicit state (`blocked on evidence` in the PR, with why); performance-sensitive changes need before/after/delta baselines in the PR body. Setup, token sourcing, fallback lanes, troubleshooting: `docs/development/evidence.md`. Remote (claude.ai) sessions lack the token, mise, and a matching Playwright browser — sanctioned workarounds: `docs/development/remote-sessions.md`.

## High-Signal Lessons (unconditional)

- **Never use bare `self-hosted` for workflows in this repo.** Use GitHub-hosted macOS (`macos-15`) for generic build/test jobs, `[self-hosted, tart-ui]` for UI/perf automation, `[self-hosted, lume-macos]` for agent execution (preferred, with ubuntu-latest fallback), and `[self-hosted, signing-host]` for release/signing/notarization.
- **Ship a diagnostic probe instead of your third guess.** When you're guessing, stop and instrument.
- **The tracker lags the code — verify before planning from it.** Before sequencing work from open issues, `rg` the acceptance criteria against the tree; close what's done in the same cycle that ships it (`Closes #N` in every implementing PR).

Full ledger with history and the surface-specific lessons: `docs/agents/lessons.md`.

## Conventions

- Commit hygiene: no screenshot artifacts (`output/`) in commits unless explicitly requested. Never delete build/test state with ad-hoc `rm -rf` — it trips shell-permission prompts that stall unattended sessions; use the surface's allowlisted cleaner (see its `AGENTS.md`) or an existing script/mise task, and file the gap if none covers your case.
- New standalone Python utilities are single-file UV scripts: `#!/usr/bin/env -S uv run --script` plus a PEP 723 metadata block. Prefer `uv run --script <path>` in docs/examples; package/module layout only when explicitly requested or tooling requires it.
- File purpose blocks: where a file's purpose isn't obvious from its name, it opens with a ≈2–4 line present-tense doc block stating what it does and why. Add one when creating or substantially editing such a file; keep them accurate — `head`/`rg` over these blocks is the fast index when exploring.
- Two web apps, not interchangeable: `web-next/` is active (all new web work); `web/` is maintenance mode. Each directory's `AGENTS.md` has the details.
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
| Terminal / keyboard / sidebar / desktop UI | `Sources/AGENTS.md`; runbook: `docs/development/libghostty-integration.md` § "Agent self-verification runbook" |
| Swift tests | `Tests/AGENTS.md` |
| `web/` dashboard (maintenance mode) | `web/AGENTS.md` |
| `web-next/` (active web app) | `web-next/AGENTS.md`, then `web-next/CONTRIBUTING.md` |
| Issue lifecycle / backlog | `backlog/AGENTS.md` |
| Lume VMs | `mise run dev-lume-ensure` first; `docs/development/lume-integration.md` |
| Milestone delivery / subagent fan-out | `.agents/skills/drive/SKILL.md` / `.agents/skills/subagent-delegation/SKILL.md` |
| Symbol/task → file lookup | `docs/agents/code-map.md` |
| Lessons ledger | `docs/agents/lessons.md` |
| Architecture decisions / product domain | `docs/decisions/`, `docs/agents/domain.md` |
| HTML prototypes | `prototypes/README.md` |
| Original spec | `docs/original_spec.md` — find the component you need; don't read it entirely |
