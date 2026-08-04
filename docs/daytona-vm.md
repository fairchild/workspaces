# Daytona Cloud Workspaces

Historical note: this document describes the original Daytona-specific remote workspace flow. The current provider architecture that also includes Lume is documented in [VM Workspace Providers and Lume](vm-provider-architecture.md).

Remote Linux sandboxes via [Daytona](https://www.daytona.io), integrated alongside local workspaces.

## What It Does

Click "New Workspace" on any repo, pick "Remote VM", and get an SSH terminal into a cloud Linux sandbox — same sidebar, same workflow as local workspaces. The sandbox lifecycle (stop, start, archive, delete) is managed from the context menu.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  SidebarView                                                 │
│  ┌──────────────┐  context menu                              │
│  │ WorkspaceRow  │──→ Stop / Start / Archive / Delete        │
│  │ (cloud icon)  │                                           │
│  └──────┬───────┘                                            │
│         │ click                                              │
├─────────┼────────────────────────────────────────────────────┤
│  ContentView                                                 │
│         │                                                    │
│         ▼                                                    │
│  handleRemoteWorkspaceSelection()                            │
│    ├─ if stopped/archived → startSandbox() first             │
│    ├─ getSSHCommand()                                        │
│    └─ activateHostSession(key: .backendSession(daytona, id), │
│         customCommand: sshCommand)                           │
│              │                                               │
│              ▼                                               │
│  GhosttyTerminal launches SSH process                        │
├──────────────────────────────────────────────────────────────┤
│  DaytonaBackend (actor)                                      │
│    └─ ProcessRunner → uv run --script                        │
│         → daytona-sandbox-manager.py                         │
│              └─ Daytona Python SDK → REST API                │
└──────────────────────────────────────────────────────────────┘
```

## Session Identity

Remote sessions use `HostTerminalSessionKey.backendSession(providerID: "daytona", instanceID: sessionRoutingID)` rather than a filesystem path. For Daytona, `sessionRoutingID` currently matches the sandbox UUID for new records, but it is persisted as a routing identifier distinct from provider lifecycle/status state.

The `HostTerminalSession` has a `customCommand` field. When set, the terminal launches that command (the SSH invocation) instead of the user's default shell.

## Sandbox States

| App Status | Daytona State | Compute | Disk | Resume |
|-----------|---------------|---------|------|--------|
| Active | `started` | Running | Live | Instant |
| Stopped | `stopped` | Off | Preserved | Fast (seconds) |
| Archived | `archived` | Off | Cold storage | Slower (restore) |

On launch, `syncCloudWorkspaceStatuses()` queries the Daytona API and reconciles local workspace status with the actual sandbox state. This handles cases where sandboxes were stopped or archived externally (auto-stop, dashboard, etc.).

## Data Model

```swift
// Workspace (SwiftData @Model)
backendIdentifier: String  // "daytona" for remote, "local" for local
remoteId: String?          // Daytona sandbox UUID for provider lifecycle/status
sessionRoutingID: String?  // terminal routing key / backend session identity
statusRaw: String          // "active", "stopped", "archived"
path: String               // "/__workspace_manager_remote__" sentinel for remote-only rows
```

Remote Daytona rows now persist a named remote-path sentinel instead of `FileManager.default.temporaryDirectory`. `FileManager.default.temporaryDirectory` is still used as a transient working directory when launching the SSH command, but it is no longer the stored identity for the workspace row.

## Backend Layer

`DaytonaBackend` is an actor conforming to `DaytonaBackendProtocol`. Currently implemented as a Python CLI bridge:

```
Swift → ProcessRunner → uv run --script daytona-sandbox-manager.py <subcommand>
                         → Daytona Python SDK → REST API
                         → JSON stdout → Codable decode
```

### Commands

| Subcommand | SDK Call | Returns |
|-----------|---------|---------|
| `create --name X [--clone-url URL]` | `daytona.create()` + `ssh_access()` + `git.clone()` | `{sandbox_id, ssh_command, state}` |
| `ssh-command --sandbox-id X` | `sandbox.create_ssh_access()` | `{sandbox_id, ssh_command, state}` |
| `start --sandbox-id X` | `sandbox.start(timeout=180)` | `{sandbox_id, ssh_command, state}` |
| `stop --sandbox-id X` | `sandbox.stop(timeout=180)` | `{stopped: true}` |
| `archive --sandbox-id X` | `sandbox.stop()` + `sandbox.archive()` | `{archived: true}` |
| `delete --sandbox-id X` | `sandbox.delete()` | `{deleted: true}` |
| `list` | `daytona.list()` | `[{sandbox_id, state}]` |

### Credentials

The Python script reads `DAYTONA_API_KEY` from `~/.env` (key=value format) or from the environment directly. The Daytona SDK target is `https://app.daytona.io/api`.

## UX Details

### Progress Indicators

- **Creating**: Spinner + "Creating cloud workspace..." appears under the repo immediately when "Create" is clicked
- **Connecting**: Overlay dims the terminal with "Connecting to X..." while SSH access is being set up
- **Lifecycle actions**: Inline status text below the workspace row ("Stopping...", "Starting...", "Archiving...")
- **Sidebar sync**: When an SSH process exits (ctrl-d), the sidebar selection updates to match the new active terminal

### Auto-Start on Selection

Clicking a stopped or archived workspace automatically starts the sandbox and connects. The user doesn't need to right-click → Start first.

### Race Protection

Only one remote connection can be in-flight at a time. Clicking a second cloud workspace while one is connecting is ignored. Stale completions (where the user navigated elsewhere before the async call finished) are discarded.

## File Map

| File | Role |
|------|------|
| `scripts/daytona-sandbox-manager.py` | Python CLI bridge to Daytona SDK |
| `Sources/WorkspaceManagerCore/Services/DaytonaBackend.swift` | Swift actor wrapping the CLI |
| `Sources/WorkspaceManagerCore/Services/Protocols.swift` | `DaytonaBackendProtocol` |
| `Sources/WorkspaceManagerCore/Models/Models.swift` | `WorkspaceStatus` enum, `sandboxId` field |
| `Sources/WorkspaceManagerCore/Services/HostTerminalSessionCoordinator.swift` | `.backendSession` key type |
| `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` | Remote selection, connecting overlay, status sync |
| `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift` | Lifecycle actions, creation progress |
| `Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift` | Cloud icon, status badges, inline progress |
| `Sources/WorkspaceManager/Views/MainWindow/NewWorkspaceSheet.swift` | Local/Remote VM picker |

## Future Work

See `backlog/done/daytona-native-swift-api-plan.md` — replace the Python CLI bridge with direct URLSession calls to the Daytona REST API, eliminating the `uv`/Python dependency and enabling streaming progress updates.
