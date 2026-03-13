# WorkspaceManager - Agent Context

Mac-native app for managing AI coding sessions with embedded terminal.

## Dev Verification Practice (required)

When changing terminal/keyboard/sidebar behavior, use this loop so future sessions can self-verify reliably:

1. Build pinned GhosttyKit and app:
   - `./scripts/build-ghosttykit.sh`
   - `swift build`
2. Launch only the debug binary:
   - fastest startup sanity check: `./scripts/dev-smoke.sh --no-build`
   - `./scripts/launch-dev.sh --no-build`
   - shared-desktop mode (preferred when user is actively using machine): `./scripts/launch-dev.sh --no-build --no-activate`
   - keep logs attached while debugging launcher/startup issues: `./scripts/launch-dev.sh --no-build --watch`
   - direct binary fallback if the launcher is being debugged:
     `WORKSPACES_DATA_DIR=.dev-data/workspacemanager WORKSPACES_APP_VARIANT=dev .build/arm64-apple-macosx/debug/WorkspaceManager`
3. Confirm the running process is the debug path (not `/Applications`):
   - `ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'`
4. Distinguish the debug app from the installed app:
   - debug launches set `WORKSPACES_APP_VARIANT=dev`
   - the debug app shows a `DEV` Dock badge and `Development Build` window subtitle
   - if both apps are running, kill `/Applications/WorkspaceManager.app` before testing
5. Verify shortcut behavior:
   - `Cmd+B` toggles left sidebar
   - `Cmd+D` creates a visible right split for the focused terminal
6. If split fails, check launch logs in `.dev-data/logs/` for:
   - `"[GhosttyAppManager] action=new_split direction="`
7. Capture verification evidence without forcing app activation:
   - `./scripts/capture-window.sh`
   - when using `--no-activate`, pause your own keyboard/mouse input first, capture, then resume
   - treat `--no-activate` as a capture-only shared-desktop handshake, not an input-driving automation lane
   - run activation-driving scripts such as `./scripts/shortcut-pass-through-smoke.sh` only when foreground input is acceptable and `Terminal Multiplexing Mode` is set to `Ghostty Splits`
   - if you need input-driving automation without disturbing the active desktop, use Tart/Lume or a separate macOS user/session
8. `mise` convenience tasks:
   - `mise run dev-launch`
   - `mise run dev-watch`
   - `mise run dev-smoke`
   - `mise run dev-lume-preflight`
   - `mise run dev-lume-standalone-validate`
   - `mise run dev-lume-macos-smoke`

For real-host Lume validation:

1. Prove Lume itself first:
   - `./scripts/lume-standalone-validate.sh`
   - `mise run dev-lume-standalone-validate`
2. Run the fast machine preflight for the app layer:
   - `./scripts/lume-host-preflight.sh`
   - `mise run dev-lume-preflight`
3. Run the full smoke when you need a real macOS VM end to end:
   - `./scripts/lume-host-macos-smoke.sh`
   - `mise run dev-lume-macos-smoke`
4. The app smoke uses a dev-only app automation mode, not fixture providers:
   - `WORKSPACES_AUTOMATION_MODE=host-lume-macos-smoke`
   - it writes JSONL milestones to the configured `WORKSPACES_AUTOMATION_EVENTS_PATH`
   - artifacts land under `output/lume-host-smoke/<timestamp>/`
5. Lume storage contract:
   - standalone validated bases live under `~/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases`
   - app-created workspace VMs live under `~/Library/Application Support/WorkspaceManager/LumeStorage/workspace-vms`
   - only the standalone validator may mark a base ready, via `~/Library/Application Support/WorkspaceManager/LumeValidatedBases/<vmName>.json`
6. Workspaces-owned unattended overrides for stock base prep live under:
   - `config/lume/unattended/`
   - current full-flow Tahoe override: `config/lume/unattended/tahoe-workspaces-v23.yml`
   - current from-scratch recovery helper: `config/lume/unattended/tahoe-workspaces-v18-official-run-bootstrap-ssh.yml`
7. Upstream Lume local-testing note:
   - do not point the standalone validator at raw `libs/lume/.build/debug/lume`
   - for local upstream validation, use `libs/lume/scripts/install-local.sh` into an isolated install dir and point `LUME_BIN` at that installed binary
   - `install-local.sh --no-background-service` unloads the current `com.trycua.lume_daemon` LaunchAgent during cleanup, so restart the daemon manually or reinstall the LaunchAgent before normal Workspaces validation
8. Canonical Lume docs:
   - `docs/development/lume-integration.md`
   - `docs/development/lume-validation.md`
   - `docs/development/lume-recreate-runbook.md`

Launcher contract:
- `launch-dev.sh` should only report success once the debug process is still alive and a visible app window exists.
- if startup fails, inspect the latest `.dev-data/logs/launch-diagnostics-<timestamp>/` bundle first.

Canonical reference:
- `docs/development/libghostty-integration.md` ("Shortcut + split contract" and "Agent self-verification runbook")
- `docs/development/shortcut-routing.md` ("Shortcut Routing Architecture")
- `backlog/shared-desktop-focus-contention-followup.md` (longer-term isolation follow-up)

## Evidence-Driven Development

Verify your work visually, then present evidence to the user. Don't just say it works — prove it.

- **Self-verify**: Use Tart VMs (`/tart-gui-automation`) to build, launch, and screenshot the app in an isolated environment.
- **Present evidence**: Open HTML artifacts in the browser (`open <path>`), render screenshots inline in chat, and show test output. The user should see the proof without asking twice.
- **Tests are evidence too**: Run `swift test` and show the summary. Green tests are necessary but not sufficient — visual confirmation of UI changes is expected.
- **Treat visual proof as a merge gate for UI work**: For changes that affect UI, terminal behavior, keyboard handling, sidebar behavior, windowing, launch flow, or visual appearance, do not request review, call the PR ready, or merge until the PR itself contains visual evidence from the exact commit under review.
- **Minimum PR evidence for UI work**: Include at least one rendered screenshot or equivalent visual artifact in the PR description or comments, the exact verification commands used, and a linked log or artifact path. If the change affects interaction, include a second screenshot or short recording that proves the result.
- **Capture performance baselines early when work is performance-sensitive**: For changes that could affect launch time, terminal responsiveness, repo loading, focus restoration, rendering cost, or other user-visible performance, gather baseline metrics before making changes unless equivalent baseline data is already provided as input to the task.
- **Compare before and after on the same footing**: Re-run the same performance measurement at the end of the work with the same or clearly described workload, environment, and metric source, then include before/after/delta in the PR discussion.
- **Call out meaningful performance changes explicitly**: If a like-for-like comparison shows a meaningful delta, a target boundary crossing, or missing metrics, say so directly in the PR and final summary. If the comparison is not like-for-like, state that it is not directly comparable rather than implying confidence.
- **Blocked evidence is an explicit state**: If you cannot produce visual evidence, say so clearly in the PR and in chat as `blocked on evidence`, explain why, and do not merge unless the user explicitly approves shipping without that proof.
- **Do not rely on local-only proof**: Local screenshots, logs, and perf results are useful during development, but they are not sufficient close-out evidence unless they are attached to or clearly linked from the PR discussion.

## High-Signal Lessons

- **Never use bare `self-hosted` for workflows in this repo.** Use GitHub-hosted macOS (`macos-17`) for generic build/test jobs, `[self-hosted, tart-ui]` for UI/perf automation, and `[self-hosted, signing-host]` for release/signing/notarization.
- **Keep terminal surfaces nearly chrome-free.** Repo overview pages can carry metadata and actions, but terminal views should default to the canvas with minimal surrounding UI.
- **Prefer quiet discoverability over persistent controls.** Avoid right-click-only primary actions, but also avoid always-visible sidebar affordances that add noise. Hover-visible scoped actions are usually the right compromise.
- **Persist selection state by stable IDs, not live SwiftData objects.** Restore and fallback logic should resolve models late and validate them against current data before selection.
- **Release version metadata must have one source of truth.** Tag, app version, and packaged artifact version should be validated against each other before a release is created.
- **If the app opens or closes unexpectedly on a dev machine, check the launching process first.** On this project, CI/self-hosted runner behavior can look like an app bug.

## Commit Hygiene

- Do not include screenshot artifacts in commits unless explicitly requested (`output/`).

## Quick Commands

```bash
./scripts/build-ghosttykit.sh  # Build GhosttyKit.xcframework (required once/after pin changes)
swift build   # Build
swift test    # Test
swift run     # Run
```

## Python Script Preference

- Prefer single-file UV scripts for new standalone Python utilities.
- Make scripts directly executable with shebang:
  - `#!/usr/bin/env -S uv run --script`
- Include PEP 723 metadata block at the top of each script:
  - `# /// script`
  - `# requires-python = ">=3.11"`
  - `# dependencies = [...]` (use `[]` when stdlib-only)
  - `# ///`
- Prefer `uv run --script <path>` in docs/examples; direct execution is acceptable for executable files.
- Only use non-UV Python layout when explicitly requested or when project tooling requires package/module structure.

## Doc Navigation

| Task | Primary Doc | Skip |
|------|-------------|------|
| Understand the app | README.md | backlog/ |
| Architectural decisions | ARCHITECTURE.md | backlog/ |
| Implement a component | docs/original_spec.md (find relevant section) | Read whole file |
| libghostty internals | docs/development/libghostty-integration.md | - |
| Notifications / webhooks | docs/development/notifications.md | - |
| Debug an issue | docs/development/troubleshooting.md | - |
| Terminal keyboard focus | docs/development/solution-terminal-keyboard.md | - |
| Roadmap/planning | backlog/ROADMAP.md | - |
| Deferred work items | backlog/*.md | - |

## Code Navigation

| What | Where |
|------|-------|
| Data models | Sources/WorkspaceManagerCore/Models/Models.swift |
| Git operations | Sources/WorkspaceManagerCore/Services/GitService.swift |
| Workspace lifecycle | Sources/WorkspaceManagerCore/Services/WorkspaceService.swift |
| Service protocols | Sources/WorkspaceManagerCore/Services/Protocols.swift |
| Backend abstraction | Sources/WorkspaceManagerCore/Services/LocalBackend.swift |
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
| Cloudflare Worker (infra) | infra/cloudflare-webhook-relay/ |
| Tests | Tests/WorkspaceManagerTests/ |

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

6. **CI Activation Policy**: The app auto-detects CI via the `CI` env var and uses `.accessory` activation policy (no dock, no Cmd+Tab, no focus steal). Three modes:
   - Normal launch: `.regular` + `activate()` — full foreground
   - `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1`: `.regular`, no `activate()` — dock visible, no focus steal
   - `CI=true`: `.accessory` — fully invisible

   This prevents the app from stealing focus on self-hosted runners. Any script that launches the app headlessly should set `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1`. See `WorkspaceManagerApp.swift` `AppDelegate`.

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

- **UI**: SwiftUI + AppKit hybrid
- **Terminal**: GhosttyKit (`libghostty`) binary target
- **Persistence**: SwiftData
- **Target**: macOS 14.0+
- **Distribution**: Direct (non-sandboxed, App Store sandbox blocks shell execution)

## Multi-Agent Coordination

Agents coordinate via GitHub Discussions. See `.agents/skills/gh-discuss/SKILL.md` for conventions and the CLI script.

Quick start: `uv run .agents/skills/gh-discuss/scripts/gh-discuss.py dashboard`

Milestone delivery: use `.agents/skills/drive/SKILL.md` to plan first, refresh the latest milestone state from GitHub, and execute issues to completion one at a time.

## Don't

- Don't modify Package.swift unless adding dependencies
- Don't read docs/original_spec.md entirely - find the component you need
- Don't put service logic in Views - use Services/
- Don't store URLs directly in SwiftData models
