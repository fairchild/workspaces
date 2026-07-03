# WorkspaceManager - Agent Context

Mac-native app for managing AI coding sessions with embedded terminal.

## Quality and Mergeability

Craft matters. Plan work so it can land mergeably: correct, coherent with the product, reviewable, verified, and leaving the system easier to operate. Keep changes native-feeling, tightly scoped, evidence-backed, and consistent with existing architecture and UI patterns. Before opening or reviewing a PR, use `docs/development/mergeability-standard.md` for the surface-specific checklist.

When the user asks to implement a change, default to carrying it through to a PR: branch if needed, make the edit, verify it, commit, rebase on the latest `origin/main`, push, open the PR, and report its status. Treat this as a strong default, not a mandate; pause short of PR creation when the user asks for exploration only, says not to publish, or evidence/permissions are blocked. At the start of a multi-PR working session, propose the authority contract explicitly (who reviews, who flips ready, who merges) instead of discovering it one approval at a time — it was the single biggest cycle-time lever in the 2026-07-02 cycle.

## Startup Instruction Budget

`AGENTS.md` is startup context for every repo session. Keep it under about **4,500 tokens** (roughly **3,300 words**) unless the added guidance is more important than the recurring context cost. Prefer tightening, deduplicating, or moving detailed policy into linked docs over expanding this file.

Continuous improvement of `AGENTS.md` is important to the health and longevity of the codebase: it is how this repo teaches future agents to meet product, quality, evidence, and operational objectives. Improve it when the guidance becomes clearer, shorter, or more actionable. When encoding a lesson, place it at the cheapest surface that fires at the right moment — machinery (CI gates, scripts) over skills, skills over linked docs, this file last — and when a lesson graduates upward (e.g. prose becomes a script), delete the prose it replaces.

## Agent skills

### Issue tracker

Issues and PRDs live in GitHub Issues for `fairchild/workspaces`. See `docs/agents/issue-tracker.md`.

When the user asks to work a GitHub issue, or gives an issue link/number, treat it as a backlog claim even if the `backlog` skill was not named.
Before implementation, read the issue, apply the `claimed` label, remove `ready` if present, and post a claim comment naming the active Codex thread title/name and session ID.
If either identifier is unavailable, say so explicitly in the comment instead of omitting it.
Then continue through the issue lifecycle in `backlog/AGENTS.md`.

### Triage labels

Use lane + state labels: `agent`/`human` for ownership, `ready`/`claimed`/`review`/`mergeable` for lifecycle, and `needs-human` only for human intervention blockers. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo; use root docs plus `docs/decisions/` for architectural decisions. See `docs/agents/domain.md`.

### Local state schema

The native app's local SQLite sidecar schema lives in `docs/schema.sql`, with the implementation plan in `docs/development/local-state-store-plan.md`. Keep the schema doc manually in sync with `LocalStateStore` migrations whenever tables, indexes, or persisted meanings change.

## Dev Verification Practice (required)

When changing terminal/keyboard/sidebar behavior, run the canonical self-verification loop in `docs/development/libghostty-integration.md` § "Agent self-verification runbook". The short form:

1. `./scripts/build-ghosttykit.sh` (once / after pin changes), then `swift build`.
2. Launch only the debug binary: `./scripts/launch-dev.sh --no-build` — add `--no-activate` on a shared desktop (preferred when the user is actively using the machine), `--watch` to keep logs attached; `./scripts/dev-smoke.sh --no-build` is the fastest startup sanity check.
3. Confirm you're testing the debug app, not `/Applications`: `ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'`. Debug builds show a `DEV` Dock badge and `Development Build` window subtitle; kill `/Applications/WorkSpaces.app` if both are running.
4. Verify shortcuts: `Cmd+B` toggles the sidebar; `Cmd+D` creates a visible right split. If a split fails, check `.dev-data/logs/` for `"[GhosttyAppManager] action=new_split direction="`.
5. Capture evidence without forcing activation: `./scripts/capture-window.sh`. With `--no-activate`, pause your own input, capture, resume — it's a capture-only handshake, not an input-driving lane. Run activation-driving scripts (e.g. `./scripts/shortcut-pass-through-smoke.sh`, Ghostty Splits mode only) only when foreground input is acceptable; for input-driving automation that must not disturb the desktop, use Tart/Lume or a separate macOS user/session.
6. Verify the daily-driver flows end to end with `./scripts/desktop-ui-smoke.sh --no-build` (`mise run dev-ui-smoke`): the `desktop-ui-smoke` automation mode creates a local workspace via the UI and switches selection workspace→repo→workspace, then asserts the JSONL milestone sequence (`workspace_created`, `sidebar_updated`, `terminal_session_attached`, `surface_focused`) under `output/desktop-ui-smoke/<timestamp>/`. Headless-safe (`--no-activate`); terminal-attach + follows-selection are hard gates, `surface_focused` is best-effort (focus is non-deterministic with the app backgrounded). Scheduled non-PR-blocking lane first; promote to a gate once stable.
7. `mise` shortcuts: `dev-launch`, `dev-watch`, `dev-smoke`, `dev-ui-smoke`, `dev-lume-ensure`, `dev-lume-preflight`, `dev-lume-standalone-validate`, `dev-lume-macos-smoke`.

Launcher contract: `launch-dev.sh` reports success only once the debug process is alive and a visible window exists; on failure, inspect the latest `.dev-data/logs/launch-diagnostics-<timestamp>/` bundle first.

**Lume.** Before any Lume work run `mise run dev-lume-ensure` (idempotent, self-healing); the daemon must run from the **installed** binary and its LaunchAgent has `KeepAlive: true`. Validation lanes, the storage contract (validated bases vs workspace VMs), unattended overrides under `config/lume/unattended/`, the upstream local-testing rules, and the app smoke's automation mode (`WORKSPACES_AUTOMATION_MODE=host-lume-macos-smoke`, JSONL milestones, artifacts under `output/lume-host-smoke/`) are all canonical in:

- `docs/development/lume-integration.md` (§ "Daemon Reliability", storage layout, upstream testing note)
- `docs/development/lume-validation.md` (standalone validate → preflight → full macOS smoke)
- `docs/development/lume-recreate-runbook.md`, `docs/development/lume-runner-setup.md`

Shortcut/split routing references: `docs/development/shortcut-routing.md`; longer-term shared-desktop isolation: `backlog/done/shared-desktop-focus-contention-followup.md`.

## Evidence-Driven Development

Evidence is a merge gate. Do not create a PR without it. In order:

1. **Run tests** — `swift test` or `cd web && pnpm test`
2. **Capture evidence** — `./scripts/evidence.sh --pr <number> --name <slug>` (screenshots for UI changes, test output otherwise; web screenshots without auth: `mise run web:dev`)
3. **Paste the uploaded evidence URLs into the PR body**
4. **Only then create the PR** — no `[pending-ci]` unless evidence is genuinely impossible locally

```bash
./scripts/evidence.sh --pr <N> --name <slug>                  # capture + upload + print markdown
./scripts/evidence.sh --pr <N> --name <slug> --file <path>    # upload an existing file
mise run evidence -- --pr <N> --name <slug>
```

Rules: no local-only proof (upload via `evidence.sh`); blocked evidence is an explicit state (`blocked on evidence` in the PR, with why); performance-sensitive changes need before/after/delta baselines in the PR body. The script auto-sources `.env` (and sibling worktree env files) for `EVIDENCE_UPLOAD_TOKEN`; if a worktree lacks `.env`, run `./scripts/setup --env-only` before claiming evidence is blocked. Uploads go to `https://evidence.cloudcompute.com/`. Full guide: `docs/development/evidence.md`. Remote (claude.ai) sessions lack the token, mise, and a matching Playwright browser — the sanctioned workarounds (green-CI-link evidence, raw-pnpm equivalents, `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH`) are canonical in `docs/development/remote-sessions.md`.

PR summary style: prefer concise Markdown links for completed checks/artifacts (e.g. `[Web CI passed](url)`). Readability preference, not a merge gate.

## High-Signal Lessons

- **Never use bare `self-hosted` for workflows in this repo.** Use GitHub-hosted macOS (`macos-15`) for generic build/test jobs, `[self-hosted, tart-ui]` for UI/perf automation, `[self-hosted, lume-macos]` for agent execution (preferred, with ubuntu-latest fallback), and `[self-hosted, signing-host]` for release/signing/notarization.
- **Keep terminal surfaces nearly chrome-free.** Repo overview pages can carry metadata and actions, but terminal views default to the canvas with minimal surrounding UI.
- **Prefer quiet discoverability over persistent controls.** Avoid right-click-only primary actions, but also avoid always-visible sidebar affordances that add noise. Hover-visible scoped actions are usually the right compromise.
- **Persist selection state by stable IDs, not live SwiftData objects.** Restore and fallback logic should resolve models late and validate them against current data before selection.
- **Release version metadata must have one source of truth.** Tag, app version, and packaged artifact version should be validated against each other before a release is created.
- **If the app opens or closes unexpectedly on a dev machine, check the launching process first.** CI/self-hosted runner behavior can look like an app bug.
- **Vercel `Sandbox.create({env: {...}})` does NOT propagate to `sandbox.runCommand()`.** Write env vars to an `env.sh` and `source` it at the top of the script. See `docs/development/agent-chat-sandbox.md` § "Claude CLI Authentication".
- **Ship a diagnostic probe instead of your third guess.** Terminal arc #306→#309: two guess-fixes merged green and failed in production; one temporary probe (#308) revealed the root cause in a single ship cycle. When you're guessing, stop and instrument.
- **"Tests green" ≠ "works in production" for agent paths.** For changes touching `createSandbox`, `restoreSnapshot`, `createTerminalSandbox`, or `streamOutput`, send a real chat message in production and read the agent stream before declaring victory.
- **The tracker lags the code — verify before planning from it.** Three grooming/planning passes in a row (2026-06-28 ×2, 2026-07-02) found open issues whose work had already shipped. Before sequencing work from open issues, `rg` the acceptance criteria against the tree; close what's done in the same cycle that ships it (`Closes #N` in every implementing PR).

## Commit Hygiene

- Do not include screenshot artifacts in commits unless explicitly requested (`output/`).

## Quick Commands

```bash
./scripts/build-ghosttykit.sh  # Build GhosttyKit.xcframework (once / after pin changes)
swift build / swift test / swift run
mise run lint                  # swift-format lint --strict (CI fails without it)
./scripts/evidence.sh --pr <N> --name <slug>   # required before PRs
```

### Web dashboard (`web/`)

Always use the `mise run web:*` tasks, never raw pnpm chains — catalog, caveats, and anti-patterns in `web/docs/local-dev.md`. Tasks live in `web/.mise.toml` (not chain-loaded from root): run after `cd web/` or with `mise -C web run ...`. Most used:

```bash
mise run web:check                          # typecheck + lint + unit tests
mise run web:dev                            # seed DB + auth bypass + dev server
DEV_GH_TOKEN=$(gh auth token) mise run web:dev   # bypass with real GitHub API access
mise run web:e2e                            # Playwright E2E
mise run web:evidence -- --pr <N> --name <slug>
mise run web:deps -- <pkg>                  # add dep + fix package.json formatting
```

Known caveat: `fast/unauth-*` specs need `NODE_ENV=production` — they fail under `pnpm dev` by design (see `web/docs/local-dev.md`).

## Python Script Preference

New standalone Python utilities are single-file UV scripts: `#!/usr/bin/env -S uv run --script` plus a PEP 723 metadata block (`# /// script` … `# ///`, `requires-python = ">=3.11"`, `dependencies = [...]`). Prefer `uv run --script <path>` in docs/examples. Use package/module layout only when explicitly requested or tooling requires it.

## Doc Navigation

| Task | Primary Doc | Skip |
|------|-------------|------|
| Understand the app | README.md | backlog/ |
| Architectural decisions | ARCHITECTURE.md | backlog/ |
| Implement a component | docs/original_spec.md (find relevant section) | Read whole file |
| libghostty internals + dev verification runbook | docs/development/libghostty-integration.md | - |
| Notifications / webhooks | docs/development/notifications.md | - |
| Debug an issue | docs/development/troubleshooting.md | - |
| Add Settings-gated experimental UI | docs/development/experimental-features.md | - |
| Terminal keyboard focus | docs/development/solution-terminal-keyboard.md | - |
| Evidence guide | docs/development/evidence.md | - |
| UI fixture mode + release screenshots | docs/development/ui-fixture-mode.md | - |
| Local SQLite state schema | docs/schema.sql | - |
| Local state store plan | docs/development/local-state-store-plan.md | - |
| Lume integration / daemon reliability | docs/development/lume-integration.md | - |
| Lume validation lanes | docs/development/lume-validation.md | - |
| Lume runner setup | docs/development/lume-runner-setup.md | - |
| Web local dev (mise tasks, auth bypass) | web/docs/local-dev.md | - |
| Web architecture | web/docs/architecture.md | - |
| PR reviewer agent | docs/pr-review/pr-reviewer.md | - |
| Roadmap/planning | backlog/ROADMAP.md | - |
| Deferred work items | backlog/*.md | - |
| Prototypes | prototypes/README.md | - |

## Code Navigation

| What | Where |
|------|-------|
| Data models | Sources/WorkspaceManagerCore/Models/Models.swift |
| Git operations | Sources/WorkspaceManagerCore/Services/GitService.swift |
| Workspace lifecycle | Sources/WorkspaceManagerCore/Services/WorkspaceService.swift |
| Local state history | Sources/WorkspaceManagerCore/Services/LocalStateStore.swift |
| Service protocols | Sources/WorkspaceManagerCore/Services/Protocols.swift |
| Backend abstraction | Sources/WorkspaceManagerCore/Services/LocalBackend.swift |
| Lume runtime setup | Sources/WorkspaceManagerCore/Services/LumeRuntimeService.swift |
| Lume workspace orchestration | Sources/WorkspaceManagerCore/Services/LumeWorkspaceProvider.swift |
| Lume daemon transport | Sources/WorkspaceManagerCore/Services/LumeHTTPClient.swift |
| Lume CLI runner | Sources/WorkspaceManagerCore/Services/LumeCLIRunner.swift |
| Lume image catalog | Sources/WorkspaceManagerCore/Services/LumeImageCatalog.swift |
| Lume VM status normalization | Sources/WorkspaceManagerCore/Services/LumeVMStatus.swift |
| Lume error heuristics | Sources/WorkspaceManagerCore/Services/LumeErrorHeuristics.swift |
| Main layout | Sources/WorkspaceManager/Views/MainWindow/ContentView.swift |
| Terminal wrapper | Sources/WorkspaceManager/Views/Components/TerminalView.swift |
| Sidebar (repos/workspaces) | Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift |
| Right pane (files/changes) | Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift |
| Notification constants | Sources/WorkspaceManagerCore/Services/NotificationConstants.swift |
| Notification coordinator | Sources/WorkspaceManager/Views/MainWindow/NotificationCoordinator.swift |
| WebSocket event stream | Sources/WorkspaceManagerCore/Services/EventStreamService.swift |
| GitHub Device Flow auth | Sources/WorkspaceManagerCore/Services/GitHubDeviceAuth.swift |
| JWT session exchange | Sources/WorkspaceManagerCore/Services/NotificationSessionService.swift |
| Keychain storage | Sources/WorkspaceManagerCore/Services/KeychainHelper.swift |
| Webhook event model | Sources/WorkspaceManagerCore/Models/WebhookEvent.swift |
| Cloudflare Worker (webhooks) | infra/cloudflare-webhook-relay/ |
| Cloudflare Worker (evidence) | infra/cloudflare-evidence-store/ |
| Cloudflare Worker (terminal proxy) | infra/terminalshare-proxy/ |
| Evidence upload script | scripts/upload-evidence.py |
| Tests | Tests/WorkspaceManagerTests/ |
| Web dashboard | web/src/app/dashboard/ |
| Web agent runtime | web/src/lib/agent-runtime/ |
| Web compute providers | web/src/lib/agent-runtime/vercel-sandbox.ts, provider-registry.ts |
| Web terminal panel | web/src/app/dashboard/components/terminal-panel.tsx |
| Web terminal API | web/src/app/api/terminal/ |
| Web API auth helpers | web/src/lib/api-auth.ts |
| Web PR reviewer agent | web/src/lib/agent-runtime/pr-review.ts |
| PR reviewer status script | scripts/pr-reviewer-status.py |

## File Purpose Blocks

Where a file's purpose isn't obvious from its name, it opens with a short (≈2–4 line) top-of-file doc block stating **what it does and why** — present tense (what the file is, not the history of how it got there). Add one when creating or substantially editing such a file; skip self-evident utils and tests.

This doubles as a fast index when exploring: `head` a file or `rg` a shared phrase to summarize a whole family without opening them — e.g. `rg -n "^ \* Persistence for"` lists every persistence module with its one-liner. Lean on this before reading files in explore mode, and keep the blocks accurate so it stays trustworthy.

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

6. **App Activation Policy**: All `NSApp.activate` calls — launch and runtime — route through `AppActivationPolicy` (`Sources/WorkspaceManager/App/AppActivationPolicy.swift`). Normal launch: full foreground. `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1`: dock visible, no focus steal ever (launch *or* runtime — the env var name is historical). `CI=true`: fully invisible accessory app. Any script that launches the app headlessly should set `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1`. This prevents focus stealing on self-hosted runners and shared desktops.

## Testing

Tests use **Swift Testing** (`@Suite`, `@Test`, `#expect`), not XCTest. Test behavior, not implementation.

| Pattern | Exemplar | When to use |
|---------|----------|-------------|
| Integration fixture | `Helpers/TestGitRepository.swift` | Testing against real external tools (git, filesystem) |
| Configurable mock | `Helpers/MockGitService.swift` | Testing orchestration logic with injectable errors |
| Extracted helpers | `WorkspaceServiceTests` `makeWorkspaceFixture()` | When 3+ tests share setup boilerplate |
| Serialized suite | `@Suite("WorkspaceService", .serialized)` | When tests share mutable global state |

**Rules:**
- Test observable behavior, not implementation details
- Protect data contracts: Codable roundtrips, git porcelain format values
- Use `defer { cleanup() }` for temp directories

## Tech Stack

### macOS App
- **UI**: SwiftUI + AppKit hybrid · **Terminal**: GhosttyKit (`libghostty`) binary target · **Persistence**: SwiftData · **Target**: macOS 14.0+ · **Distribution**: Direct (non-sandboxed; App Store sandbox blocks shell execution)

### Web Dashboard (`web/`)
- **Framework**: Next.js 15 (App Router) on Vercel · **Auth**: Better Auth + GitHub OAuth · **DB**: LibSQL + Kysely · **Terminal**: ghostty-web (WASM) · **Agent runtime**: multi-provider (Vercel Sandbox + Anthropic Managed Agents live; Daytona/GitHub Actions unavailable stubs; mock for tests) · **Styling**: CSS Modules + custom properties (no Tailwind) · **Tests**: Vitest (unit `node` + component `jsdom` projects), Playwright (E2E with video)

### Infrastructure
- Cloudflare Workers: webhook relay + Durable Object (`infra/cloudflare-webhook-relay/`), evidence store + R2 (`infra/cloudflare-evidence-store/`), terminal proxy + Durable Object (`infra/terminalshare-proxy/`)

## Multi-Agent Coordination

Agents coordinate via GitHub Discussions. See `.agents/skills/gh-discuss/SKILL.md` for conventions and the CLI script. Quick start: `uv run .agents/skills/gh-discuss/scripts/gh-discuss.py dashboard`

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
