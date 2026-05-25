---
status: done
issue: 533
completed: 2026-05-25
resolution: promoted-to-github-issue
category: plan
pr: null
branch: null
score: null
retro_summary: null
---

# Tahoe VZ Backend Execution Brief (Terminal-First Defaults)

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

## Current Main Window Behavior (Locked)
This is the default app behavior, independent of VM backends.

1. App launch restores the last active repo overview, repo terminal, workspace terminal, or web view.
2. If the saved surface is invalid, fallback is:
   - most recent workspace
   - then most recent web view
   - then first repo overview
3. Repo rows open repo overviews.
4. Workspace rows open or resume their terminal sessions.
5. Web rows open embedded web views.
6. VM creation is never triggered at app launch.
7. VM creation/start occurs only when creating a new workspace configured for `vzLinuxTahoe`.

## UX Contract

### Active Surfaces
- `Repo overview`:
  - default non-terminal repo destination
  - used for workspace/web-view launch actions
- `Workspace terminal`:
  - primary coding surface for local or VM-backed workspaces
- `Web view`:
  - embedded browsing surface for global, repo-owned, or workspace-owned sources

### Sidebar Selection
- Sidebar selection drives both the visible surface and file tree/status panels where applicable.
- Repo selection shows overview; workspace selection changes the active terminal context.

### New Workspace Flow
1. User clicks `New Workspace`.
2. Workspace directory is created/copied as today.
3. If backend for that workspace is `vzLinuxTahoe`, create backend state + VM during creation flow.
4. The created workspace opens in the main terminal, matching local workspace behavior.

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
- Keep launch restoration state independent of backend choice so VZ workspaces participate in the same repo/workspace/web restore model.

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

The backend decisions here are still active, but the original host-pinned launch assumptions have been superseded by the current repo-overview / workspace-terminal model above. M2-M6 remain pending the current maintainability phase.

## Milestones

### M1: Terminal foundation and explicit context actions [x]
- [x] Add default terminal directory resolution for initial app startup.
- [x] Establish deterministic terminal selection behavior across repo/workspace changes.
- [x] Add explicit commands/actions to run against workspace context (instead of implicit terminal retargeting).

### M2: Backend abstraction + local conformance
- Land protocol/registry/routing in core.
- Keep local behavior stable.

### M3: VZ backend implementation
- VM lifecycle, image store, vmnet per workspace, SSH execution, allowlist enforcement.

### M4: Workspace creation integration
- New workspace creation triggers VZ VM creation when backend is `vzLinuxTahoe`.
- Preserve the existing open-surface model after creation by opening the created workspace terminal directly.

### M5: CLI routing and flags
- `workspaces run` backend-aware.
- Add `--host`, `--vm`, and vm lifecycle subcommands.

### M6: test/docs hardening
- Add tests and update docs with final behavior contract.

## Validation Checklist
- App launch restores the last active repo overview, repo terminal, workspace terminal, or web view.
- Selecting workspaces switches to the correct persistent workspace terminal without stale session reuse.
- Creating a VZ workspace creates workspace + VM and opens the created workspace terminal.
- `workspaces run` on VZ workspace defaults to VM for general commands.
- `xcodebuild`/`swift build`/`swift test` auto-route to host in `auto`.
- Existing workspaces remain `local` after migration.
- Unsupported hosts cleanly fall back to local backend.

## Repo Baseline Capture (When Starting Implementation)
- `git rev-parse HEAD`
- Record output in implementation notes/PR description.
