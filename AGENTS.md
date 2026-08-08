# WorkspaceManager - Agent Context

Mac-native app for managing AI coding sessions with embedded terminal.

## Quality and Mergeability

Craft matters. Plan work so it can land mergeably: correct, coherent with the product, reviewable, verified, and leaving the system easier to operate. Keep changes native-feeling, tightly scoped, evidence-backed, and consistent with existing architecture and UI patterns. Before opening or reviewing a PR, use `docs/development/mergeability-standard.md` for the surface-specific checklist. Substantive PRs run the `codex-review-loop` skill before opening (reflect → directed codex review → attributed reactions; skip codex for metadata/docs-only diffs).

When the user asks to implement a change, default to carrying it through to a PR: branch if needed, make the edit, verify it, commit, rebase on the latest `origin/main`, push, open the PR, and report its status. Treat this as a strong default, not a mandate; pause short of PR creation when the user asks for exploration only, says not to publish, or evidence/permissions are blocked. At the start of a multi-PR working session, propose the authority contract explicitly (who reviews, who flips ready, who merges) instead of discovering it one approval at a time.

## Startup Instruction Budget

`AGENTS.md` is startup context for every repo session. Keep it under about **4,500 tokens** unless the added guidance is more important than the recurring context cost; measure tokens directly — word count is not a reliable proxy, especially on table-dense content. Prefer tightening, deduplicating, or moving detailed policy into linked docs over expanding this file.

Continuous improvement of `AGENTS.md` is important to the health of the codebase: it is how this repo teaches future agents to meet product, quality, evidence, and operational objectives. Improve it whenever guidance can become clearer, shorter, or more actionable. When encoding a lesson, place it at the cheapest surface that fires at the right moment — machinery (CI gates, scripts) over skills, skills over linked docs, this file last — and when a lesson graduates upward (e.g. prose becomes a script), delete the prose it replaces.

## Agent skills

### Issue tracker

Issues and PRDs live in GitHub Issues for `fairchild/workspaces`. See `docs/agents/issue-tracker.md`.

When the user asks to work a GitHub issue, or gives an issue link/number, treat it as a backlog claim even if the `backlog` skill was not named: read the issue, apply the `claimed` label (removing `ready` if present), and post a claim comment naming the active Codex thread title/name and session ID — say so explicitly if either is unavailable — then continue through the issue lifecycle in `backlog/AGENTS.md`.

### Triage labels

Use lane + state labels: `agent`/`human` for ownership, `ready`/`claimed`/`review`/`mergeable` for lifecycle, and `needs-human` only for human intervention blockers. See `docs/agents/triage-labels.md`.

**Author label (required on agent-authored PRs).** The GitHub account is shared across all agents, so when you open a PR, add exactly one `author:<agent>` label naming yourself (e.g. `author:claude-code`, `author:codex`), creating the label if it doesn't exist yet. Slug rules, vocabulary, and rationale: `docs/agents/triage-labels.md` § "Author Labels".

### Domain docs

Single-context repo; use root docs plus `docs/decisions/` for architectural decisions. See `docs/agents/domain.md`.

### Local state schema

The native app's local SQLite sidecar schema lives in `docs/schema.sql` (implementation plan: `docs/development/local-state-store-plan.md`). Keep the schema doc manually in sync with `LocalStateStore` migrations whenever tables, indexes, or persisted meanings change.

## Dev Verification Practice (required)

When changing terminal/keyboard/sidebar behavior, run the canonical self-verification loop in `docs/development/libghostty-integration.md` § "Agent self-verification runbook" — this is the short form:

1. `./scripts/build-ghosttykit.sh` (once / after pin changes), then `swift build`.
2. Launch only the debug binary: `./scripts/launch-dev.sh --no-build` (`--no-activate` on a shared desktop with the user present, `--watch` to keep logs attached); `./scripts/dev-smoke.sh --no-build` is the fastest sanity check. On launch failure, inspect the newest `.dev-data/logs/launch-diagnostics-<timestamp>/` bundle.
3. Confirm you're testing the debug app (`DEV` Dock badge + persistent toolbar badge), not `/Applications`: `ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'`; kill `/Applications/WorkSpaces.app` if both are running.
4. Verify shortcuts (`Cmd+B` sidebar, `Cmd+D` split) via logs — app logging is `os.Logger` (subsystem `com.cloudcompute.workspaces`), which does **not** land in `.dev-data/logs/` (stdout/stderr only). Start `/usr/bin/log stream --predicate 'subsystem == "com.cloudcompute.workspaces"' --level info --style compact` before triggering; expect `"[GhosttyAppManager] action=new_split direction="`.
5. Capture evidence without forcing activation: `./scripts/capture-window.sh` (capture-only, not input-driving; with `--no-activate`, pause your own input during capture). Reserve activation-driving scripts for when foreground input is acceptable; otherwise use Tart/Lume or a separate macOS user/session.
6. Run `./scripts/desktop-ui-smoke.sh --no-build` (`mise run dev-ui-smoke`) end to end — headless-safe UI lane; gate semantics and milestone details are in the runbook.
7. `mise` shortcuts: `dev-launch`, `dev-watch`, `dev-smoke`, `dev-ui-smoke`, plus the `dev-lume-*` family.

**Lume.** Run `mise run dev-lume-ensure` before any Lume work (idempotent, self-healing). Daemon requirements, storage contract, validation lanes, unattended overrides, and the app smoke's automation mode are canonical in `docs/development/lume-integration.md`, `lume-validation.md`, `lume-recreate-runbook.md`, `lume-runner-setup.md`.

Shortcut/split routing: `docs/development/shortcut-routing.md`. Shared-desktop isolation: `backlog/done/shared-desktop-focus-contention-followup.md`.

## Evidence-Driven Development

Evidence is a merge gate. Do not create a PR without it. In order:

1. **Run tests** — `swift test`, `cd web-next && pnpm test`, or `cd web && pnpm test`
2. **Capture evidence** — for macOS-app UI, first choice is the app evidence lane: `./scripts/evidence.sh --pr <number> --fixture <scenario>` (fixture state, operator-scope window snapshot, upload — no activation, no focus steal). Otherwise `./scripts/evidence.sh --pr <number> --name <slug>` (test output; web screenshots without auth: `mise run web:dev`).
3. **Paste the uploaded evidence URLs into the PR body**
4. **Only then create the PR** — no `[pending-ci]` unless evidence is genuinely impossible locally

Rules: no local-only proof (upload via `evidence.sh`); blocked evidence is an explicit state (`blocked on evidence` in the PR, with why); performance-sensitive changes need before/after/delta baselines in the PR body. Setup, token sourcing, fallback lanes, and troubleshooting: `docs/development/evidence.md`. Remote (claude.ai) sessions lack the token, mise, and a matching Playwright browser — the sanctioned workarounds are canonical in `docs/development/remote-sessions.md`.

PR summary style: prefer concise Markdown links for completed checks/artifacts (e.g. `[Web CI passed](url)`) — readability preference, not a merge gate.

## High-Signal Lessons

- **Never use bare `self-hosted` for workflows in this repo.** Use GitHub-hosted macOS (`macos-15`) for generic build/test jobs, `[self-hosted, tart-ui]` for UI/perf automation, `[self-hosted, lume-macos]` for agent execution (preferred, with ubuntu-latest fallback), and `[self-hosted, signing-host]` for release/signing/notarization.
- **Keep terminal surfaces nearly chrome-free.** Repo overview pages can carry metadata and actions, but terminal views default to the canvas with minimal surrounding UI.
- **Prefer quiet discoverability over persistent controls.** Avoid right-click-only primary actions, but also avoid always-visible sidebar affordances that add noise. Hover-visible scoped actions are usually the right compromise.
- **Persist selection state by stable IDs, not live SwiftData objects.** Restore and fallback logic should resolve models late and validate them against current data before selection.
- **Release version metadata must have one source of truth.** Tag, app version, and packaged artifact version should be validated against each other before a release is created.
- **If the app opens or closes unexpectedly on a dev machine, check the launching process first.** CI/self-hosted runner behavior can look like an app bug.
- **Vercel `Sandbox.create({env: {...}})` does NOT propagate to `sandbox.runCommand()`.** Write env vars to an `env.sh` and `source` it at the top of the script. See `docs/development/agent-chat-sandbox.md` § "Claude CLI Authentication".
- **Ship a diagnostic probe instead of your third guess.** Terminal arc #306→#309: two guess-fixes merged green and failed in production; one probe found the root cause in one ship cycle. When you're guessing, stop and instrument.
- **"Tests green" ≠ "works in production" for agent paths.** For changes touching `createSandbox`, `restoreSnapshot`, `createTerminalSandbox`, or `streamOutput`, send a real chat message in production and read the agent stream before declaring victory.
- **The tracker lags the code — verify before planning from it.** Repeated grooming passes have found open issues whose work had already shipped. Before sequencing work from open issues, `rg` the acceptance criteria against the tree; close what's done in the same cycle that ships it (`Closes #N` in every implementing PR).

## Commit Hygiene

- Do not include screenshot artifacts in commits unless explicitly requested (`output/`).
- Never delete build/test state with ad-hoc `rm -rf` — it trips shell-permission prompts that stall unattended sessions. In `web-next/`, use `pnpm run clean [build|data|artifacts|deps|all] [--dry-run]` (allowlisted; see `web-next/CONTRIBUTING.md` § "Cleaning up"). Elsewhere, prefer an existing script/mise task, and file the gap if none covers your case.

## Quick Commands

```bash
./scripts/build-ghosttykit.sh  # Build GhosttyKit.xcframework (once / after pin changes)
swift build / swift test / swift run
mise run lint                  # swift-format lint --strict (CI fails without it)
./scripts/evidence.sh --pr <N> --name <slug>   # required before PRs
```

### Web dashboard (`web/`, maintenance mode — see § Two Web Apps)

Always use the `mise run web:*` tasks, never raw pnpm chains — full catalog, caveats, and anti-patterns in `web/docs/local-dev.md`. Tasks live in `web/.mise.toml` (not chain-loaded from root): run after `cd web/` or with `mise -C web run ...`. Most used: `web:check` (typecheck + lint + unit tests), `web:dev` (seeded dev server + auth bypass), `web:e2e`, `web:evidence -- --pr <N> --name <slug>`, `web:deps -- <pkg>`.

`web-next/` (active app) has no mise integration — plain `pnpm`, per `web-next/CONTRIBUTING.md`.

## Python Script Preference

New standalone Python utilities are single-file UV scripts: `#!/usr/bin/env -S uv run --script` plus a PEP 723 metadata block (`# /// script` … `# ///`, `requires-python = ">=3.11"`, `dependencies = [...]`). Prefer `uv run --script <path>` in docs/examples. Use package/module layout only when explicitly requested or tooling requires it.

## Doc and Code Navigation

Task → doc and symbol → file pointer tables live in `docs/agents/code-map.md`, moved out of this file for the token budget. Check there before grepping cold.

## File Purpose Blocks

Where a file's purpose isn't obvious from its name, it opens with a short (≈2–4 line) top-of-file doc block stating **what it does and why** — present tense (what the file is, not the history of how it got there). Add one when creating or substantially editing such a file; skip self-evident utils and tests.

This doubles as a fast index when exploring: `head` a file or `rg` a shared phrase (e.g. `rg -n "^ \* Persistence for"`) to summarize a whole family without opening them. Lean on this before reading files in explore mode, and keep the blocks accurate so it stays trustworthy.

## Key Patterns

1. **URL Storage**: SwiftData can't store URLs directly. Store as String, access via computed property:
   ```swift
   var path: String  // stored
   var workspaceURL: URL { URL(fileURLWithPath: path) }  // computed
   ```

2. **Protocol-based DI**: Services define protocols in `Protocols.swift`, actors conform. Views receive services via SwiftUI `@Environment`. See `WorkspaceManagerApp.swift` for the `EnvironmentKey` wiring.

3. **Actor Services**: `GitService` and `WorkspaceService` are actors. Inject via protocol (`GitServiceProtocol`, `WorkspaceServiceProtocol`) for testability.

4. **Terminal Recreation**: Use `.id(workspace.id)` to force terminal recreation when workspace changes.

5. **Keyboard Focus**: Ghostty-style retry-based focus restoration. See `docs/development/solution-terminal-keyboard.md`.

6. **App Activation Policy**: All `NSApp.activate` calls — launch and runtime — route through `AppActivationPolicy` (`Sources/WorkspaceManager/App/AppActivationPolicy.swift`). Normal launch: full foreground. `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1`: dock visible, no focus steal ever (launch *or* runtime — the env var name is historical). `CI=true`: fully invisible accessory app. Any script that launches the app headlessly should set `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1`.

## Testing

Tests use **Swift Testing** (`@Suite`, `@Test`, `#expect`), not XCTest. Test behavior, not implementation.

| Pattern | Exemplar | When to use |
|---------|----------|-------------|
| Integration fixture | `Helpers/TestGitRepository.swift` | Testing against real external tools (git, filesystem) |
| Configurable mock | `Helpers/MockGitService.swift` | Testing orchestration logic with injectable errors |
| Extracted helpers | `WorkspaceServiceTests` `makeWorkspaceFixture()` | When 3+ tests share setup boilerplate |
| Serialized suite | `@Suite("WorkspaceService", .serialized)` | When tests share mutable global state |
| Launch-scaled budget | `Helpers/LaunchBudget.swift` | Any deadline in a test that launches child processes |

**Rules:**
- Test observable behavior, not implementation details
- Protect data contracts: Codable roundtrips, git porcelain format values
- Use `defer { cleanup() }` for temp directories
- For behavior-preserving refactors, verify tests bind by mutating the extracted logic and confirming failures; a surviving mutation means the test gets rewritten, not the check dropped.
- Wait on the observable state change, not a tuned wall clock — child-process round trips span two orders of magnitude between a laptop and a loaded runner (0.3s vs 35s measured), so scale any such deadline from `Helpers/LaunchBudget.swift` and measure the whole round trip. Where a real-time bound genuinely *is* the property (an OS-imposed ceiling), gate that one test with a named reason.

## Two Web Apps

Two Next.js apps in this repo are not interchangeable:

- **`web-next/`** is the active app — sessions-first UI, deployed at `folio.cloudcompute.com`, also embedded locally in the macOS app over loopback HTTP (`web-next/docs/decisions/embedded-native-contract.md`). New web work happens here — stack + local dev: `web-next/CONTRIBUTING.md`.
- **`web/`** has been in maintenance mode since #754 (2026-07-08): no new development, old chat/terminal demoted, still serves GitHub webhook ingestion. Its managed PR reviewer was retired separately (`docs/decisions/managed-reviewer-retirement.md`). Stack + local dev: `web/README.md`.

## Multi-Agent Coordination

Agents coordinate through the GitHub-native state machine — issue labels (`docs/agents/triage-labels.md`) and PR review, not chat or Discussions (why: `docs/decisions/factory-label-control-plane.md`).

### QA of the web/ app

`qa-web-agent` (`.claude/agents/qa-web-agent.md`) is the project-local subagent for `web/` testing — Explore (black-box), Author (spec-first, human-gated), Heal (selector drift vs regression). Invoke via `/qa` (`.claude/commands/qa.md`): `explore [area]`, `author <slug>`, `heal [test-path]`, `run`, `ledger`. Coverage is measured against `web/tests/LEDGER.md` (behavior → test → last-verified date), not line-coverage %; new behaviors worth automating land in the ledger with a matching spec and test.

Milestone delivery: use `.agents/skills/drive/SKILL.md` to plan first, refresh the latest milestone state from GitHub, and execute issues to completion one at a time. For fanning work out across parallel implementation subagents, the repo-specific brief + gate conventions are in `.agents/skills/subagent-delegation/SKILL.md`.

## Prototypes

Self-contained HTML prototypes live in `prototypes/<project-name>/` — standalone files you can open directly in a browser, for exploring layout/interaction/design choices before implementation. See `prototypes/README.md` for the index.

## Don't

- Don't modify Package.swift unless adding dependencies
- Don't read docs/original_spec.md entirely - find the component you need
- Don't put service logic in Views - use Services/
- Don't store URLs directly in SwiftData models
