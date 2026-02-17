---
status: pending
category: plan
pr: null
branch: null
score: null
retro_summary: null
completed: null
---

# Tahoe VZ Backend Execution Brief (Host-Terminal-First Defaults)

## Why This File Exists
`backlog/isolation-strategies.md` remains the long-form research and option analysis.
This file is the execution-ready plan with locked decisions and implementation order.

## Decision Lock
- Target codebase only: repository root (`.`)
- Runtime path: native `Virtualization.framework` backend first (`vzLinuxTahoe`)
- Host requirements for VZ backend: macOS 26+ (Tahoe), Apple Silicon only
- Rollout: VZ is default for new workspaces on supported hosts; existing workspaces remain `local`
- VM networking: NAT default, per-workspace logical network, unrestricted egress in phase 1
- Filesystem model: RW virtiofs workspace mount
- Command channel: SSH host->guest
- Extra mounts: external allowlist only (outside repo/workspace)
- Build/test behavior: host-default via command auto-routing in `auto` mode
- Out of scope phase 1: interactive VM terminal, entitlement automation for production signing, NanoClaw code edits

## Host Terminal Default Behavior (Locked)
This is the default app behavior, independent of VM backends.

1. App launch opens a live host terminal rooted at `~/code` by default.
2. If `~/code` does not exist:
   - Use `$HOME/code` if resolvable.
   - Otherwise use `$HOME`.
3. Main terminal remains host-context by default.
4. Selecting a workspace in the sidebar does not automatically retarget the main terminal.
5. Users can spawn additional host terminals from the main context.
6. VM creation is never triggered at app launch.
7. VM creation/start occurs only when creating a new workspace configured for `vzLinuxTahoe`.

## UX Contract

### Terminal Modes
- `Host` mode:
  - label: `Host`
  - default cwd: resolved host default directory (normally `~/code`)
  - used for app startup and regular terminal sessions
- `Workspace` mode (future extension in phase 2):
  - explicit action required
  - not auto-selected by sidebar changes

### Sidebar Selection
- Sidebar selection drives file tree/status panels.
- Sidebar selection does not change main terminal cwd automatically.

### New Workspace Flow
1. User clicks `New Workspace`.
2. Workspace directory is created/copied as today.
3. If backend for that workspace is `vzLinuxTahoe`, create backend state + VM during creation flow.
4. Main terminal stays in host mode after creation unless user explicitly chooses a workspace-run action.

## Execution Routing Contract
- `auto` target:
  - VZ workspace: execute in VM except known host-routed build/test commands.
  - Local workspace: execute on host.
- `--host`: force host execution.
- `--vm`: force VM execution for VZ workspaces.
- Auto-route host commands (initial set):
  - `xcodebuild`
  - `swift build`
  - `swift test`

## Data/Model Additions
- Keep `Workspace.backendIdentifier`.
- Add `Workspace.backendState` payload (serialized backend runtime metadata).
- Add host terminal defaults in app settings/state:
  - `defaultHostTerminalDirectory` (string path, default resolves to `~/code`)
  - optional `mainTerminalMode` (`host` now; future extensible)

## File Change Map (Planned)

### New backend/infra files
- `Sources/WorkspaceManagerCore/Services/WorkspaceBackend.swift`
- `Sources/WorkspaceManagerCore/Services/BackendRegistry.swift`
- `Sources/WorkspaceManagerCore/Services/CommandRouting.swift`
- `Sources/WorkspaceManagerCore/Services/VZTahoeBackend.swift`
- `Sources/WorkspaceManagerCore/Services/VZRuntimeChecks.swift`
- `Sources/WorkspaceManagerCore/Services/VZImageStore.swift`
- `Sources/WorkspaceManagerCore/Services/VZNetworkManager.swift`
- `Sources/WorkspaceManagerCore/Services/VZSSHExecutor.swift`
- `Sources/WorkspaceManagerCore/Services/MountAllowlist.swift`

### Existing core files
- `Sources/WorkspaceManagerCore/Services/Protocols.swift`
- `Sources/WorkspaceManagerCore/Services/LocalBackend.swift`
- `Sources/WorkspaceManagerCore/Services/Errors.swift`
- `Sources/WorkspaceManagerCore/Models/Models.swift`

### App/UI files
- `Sources/WorkspaceManager/App/WorkspaceManagerApp.swift`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift`
- `Sources/WorkspaceManager/Views/Components/TerminalView.swift`
- `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift`
- `Sources/WorkspaceManager/Views/MainWindow/NewWorkspaceSheet.swift`

### CLI
- `Sources/WorkspaceManagerCLI/main.swift`

### Docs/config
- `WorkspaceManager.entitlements`
- `README.md`
- `ARCHITECTURE.md`

## Status

M1 complete (host-terminal-first defaults shipped 2026-02-15). M2-M6 pending refinement gate.

## Milestones

### M1: Host terminal default foundation [x]
- [x] Add host terminal default directory resolution.
- [x] Pin main terminal to host mode on launch and selection changes.
- [x] Add explicit commands/actions to run against workspace context (instead of implicit terminal retargeting).

### M2: Backend abstraction + local conformance
- Land protocol/registry/routing in core.
- Keep local behavior stable.

### M3: VZ backend implementation
- VM lifecycle, image store, vmnet per workspace, SSH execution, allowlist enforcement.

### M4: Workspace creation integration
- New workspace creation triggers VZ VM creation when backend is `vzLinuxTahoe`.
- Preserve host terminal mode after creation.

### M5: CLI routing and flags
- `workspaces run` backend-aware.
- Add `--host`, `--vm`, and vm lifecycle subcommands.

### M6: test/docs hardening
- Add tests and update docs with final behavior contract.

## Validation Checklist
- App launch shows a live host terminal rooted at default host directory.
- Selecting workspaces does not auto-switch terminal cwd.
- Creating a VZ workspace creates workspace + VM; main terminal stays host.
- `workspaces run` on VZ workspace defaults to VM for general commands.
- `xcodebuild`/`swift build`/`swift test` auto-route to host in `auto`.
- Existing workspaces remain `local` after migration.
- Unsupported hosts cleanly fall back to local backend.

## Repo Baseline Capture (When Starting Implementation)
- `git rev-parse HEAD`
- Record output in implementation notes/PR description.
