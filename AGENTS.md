# WorkspaceManager - Agent Context

Mac-native app for managing AI coding sessions with embedded terminal.

## Dev Verification Practice (required)

When changing terminal/keyboard/sidebar behavior, use this loop so future sessions can self-verify reliably:

1. Build pinned GhosttyKit and app:
   - `./scripts/build-ghosttykit.sh`
   - `swift build`
2. Launch only the debug binary:
   - `./scripts/launch-dev.sh --no-build`
   - shared-desktop mode (preferred when user is actively using machine): `./scripts/launch-dev.sh --no-build --no-activate`
3. Confirm the running process is the debug path (not `/Applications`):
   - `ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'`
4. Verify shortcut behavior:
   - `Cmd+B` toggles left sidebar
   - `Cmd+D` creates a visible right split for the focused terminal
5. If split fails, check launch logs in `.dev-data/logs/` for:
   - `"[GhosttyAppManager] action=new_split direction="`
6. Capture verification evidence without forcing app activation:
   - `./scripts/capture-window.sh`

Canonical reference:
- `docs/development/libghostty-integration.md` ("Shortcut + split contract" and "Agent self-verification runbook")
- `docs/development/shortcut-routing.md` ("Shortcut Routing Architecture")
- `backlog/shared-desktop-focus-contention-followup.md` (longer-term isolation follow-up)

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
| Understand the app | README.md | SPECS.md, backlog/ |
| Architectural decisions | ARCHITECTURE.md | backlog/ |
| Implement a component | SPECS.md (find relevant section) | Read whole file |
| libghostty internals | docs/development/libghostty-integration.md | - |
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

## Don't

- Don't modify Package.swift unless adding dependencies
- Don't read SPECS.md entirely - find the component you need
- Don't put service logic in Views - use Services/
- Don't store URLs directly in SwiftData models
