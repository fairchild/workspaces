---
status: pending
category: followup
issue: 83
milestone: 1
topic: remote-workspaces
priority: 2
description: Separate SSH routing identity from provider IDs, remove placeholder remote paths, and eliminate Workspace @unchecked Sendable
---

# Remote Workspace Identity & Sendability Follow-Up

## Problem Statement

PR #55 made remote workspaces safer to use by gating local-path features and moving remote backends to a sendable session snapshot. The remaining technical debt is concentrated in three related areas:

1. SSH overloads `Workspace.remoteId` as a local terminal-routing key even though `remoteId` otherwise reads like a provider-managed identifier.
2. Remote workspaces still persist `FileManager.default.temporaryDirectory` in `Workspace.path`, which is a misleading placeholder rather than meaningful persisted state.
3. `Workspace` is still marked `@unchecked Sendable` because `LocalBackend` accepts a live SwiftData model across an actor boundary.

These are coupled enough that they should be cleaned up together, but they are not necessary to finish the current PR review round.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Provider identity semantics | Reserve `remoteId` for real backend/provider identifiers only | Avoid SSH-specific ambiguity and make delete/start/stop semantics easier to reason about |
| Terminal routing identity | Add a separate persisted `sessionRoutingID` for remote workspaces that need a local stable key | Keeps SSH session reuse stable without pretending it is a provider resource |
| Remote path persistence | Stop persisting `temporaryDirectory` for remote workspaces; use an explicit empty-path sentinel and gate all path consumers through `localDirectoryURL` | Avoid misleading persisted host paths without forcing an immediate SwiftData schema shape change |
| Local backend boundary | Introduce a sendable `LocalWorkspaceContext` value type and pass that into `LocalBackend` instead of `Workspace` | Removes the remaining need for `Workspace: @unchecked Sendable` |

## Implementation Phases

### Phase 1: Separate remote routing identity from provider identity

**Files to modify:**
- `Sources/WorkspaceManagerCore/Models/Models.swift` - add persisted `sessionRoutingID`, expose a computed terminal-session identifier, and document the different roles of `remoteId` vs. routing identity
- `Sources/WorkspaceManager/Views/MainWindow/SidebarWorkspaceController.swift` - assign `sessionRoutingID` for SSH workspaces at creation time instead of synthesizing meaning into `remoteId`
- `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift` and `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` - use the computed routing identity when building `HostTerminalSessionKey.remoteSandbox`

**Acceptance criteria:**
- [ ] SSH workspaces no longer require `remoteId` to exist just to reuse/open a terminal session
- [ ] Provider-managed backends still use `remoteId` for delete/start/stop/archive operations
- [ ] Session reuse behavior for SSH remains stable across app relaunches

### Phase 2: Remove placeholder host paths from remote persistence

**Files to modify:**
- `Sources/WorkspaceManagerCore/Models/Models.swift` - define the canonical remote sentinel for `path` and keep `localDirectoryURL` as the only supported host-path accessor
- `Sources/WorkspaceManager/Views/MainWindow/SidebarWorkspaceController.swift` - stop storing `temporaryDirectory` when creating Daytona or SSH workspaces
- `Tests/WorkspaceManagerTests/ModelsTests.swift` - cover the persisted sentinel behavior and ensure remote workspaces still decode/load correctly

**Acceptance criteria:**
- [ ] Newly-created remote workspaces no longer persist `/tmp` as their path
- [ ] No local-only feature regresses by accidentally reading the raw sentinel value
- [ ] Existing tests around `localDirectoryURL` and remote editor gating still pass

### Phase 3: Remove `Workspace: @unchecked Sendable`

**Files to modify:**
- `Sources/WorkspaceManagerCore/Services/Protocols.swift` - add a sendable `LocalWorkspaceContext` snapshot similar to `RemoteWorkspaceSessionRequest`
- `Sources/WorkspaceManagerCore/Services/LocalBackend.swift` - accept `LocalWorkspaceContext` for operations that currently take `Workspace`
- `Sources/WorkspaceManagerCore/Models/Models.swift` - expose a computed `localWorkspaceContext` and remove `@unchecked Sendable` from `Workspace`
- `Tests/WorkspaceManagerTests/LocalBackendTests.swift` - update helpers/tests to use the value-type context

**Acceptance criteria:**
- [ ] `Workspace` no longer needs explicit unchecked sendability
- [ ] `LocalBackend` behavior is unchanged for initialize/execute/create-terminal flows
- [ ] `swift build` no longer emits the current `Workspace` sendability warning from the model macro

## Verification Commands

```bash
./scripts/build-ghosttykit.sh
swift build
swift test
```

## Rollback Plan

If the cleanup introduces migration or session-reuse regressions:
- revert the `sessionRoutingID` and empty-path persistence changes together
- keep the current `remoteSessionRequest` refactor from PR #55 intact
- postpone the `LocalWorkspaceContext` work until the persistence/routing shape is validated separately

## References

- `Sources/WorkspaceManagerCore/Models/Models.swift`
- `Sources/WorkspaceManagerCore/Services/LocalBackend.swift`
- `Sources/WorkspaceManager/Views/MainWindow/SidebarWorkspaceController.swift`
- PR #55 (`codex/remote-compute-integration`)
