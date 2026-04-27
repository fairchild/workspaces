---
status: done
category: followup
issue: 83
topic: remote-workspaces
priority: done
description: Remote workspace routing identity, non-local path sentinel, and local backend sendability boundary are shipped.
---

# Remote Workspace Identity & Sendability Follow-Up

## Status

Shipped. The original cleanup is no longer active P0 roadmap work.

The current implementation has:

- `Workspace.sessionRoutingID` for stable terminal routing independent of provider lifecycle IDs.
- `Workspace.terminalSessionIdentifier` as the routing identity fallback chain.
- `Workspace.remotePathSentinel` plus `localDirectoryURL` to prevent remote-only workspaces from exposing misleading host paths.
- `RemoteWorkspaceSessionRequest.sessionRoutingID` for remote backend session launch.
- `LocalWorkspaceContext` and `Workspace.localWorkspaceContext` so `LocalBackend` crosses actor boundaries with a sendable value type instead of a live SwiftData model.

Verification command used during backlog reconciliation:

```bash
rg -n "@unchecked Sendable|sessionRoutingID|remotePathSentinel|localWorkspaceContext" Sources Tests
```

The remaining `@unchecked Sendable` hits are service/test helper internals such as `RemoteBackendRegistry`, `ProcessRunner.State`, and mocks; `Workspace` itself is not one of them.

## Original Goals

The follow-up originally tracked three related pieces of technical debt:

1. SSH overloaded `Workspace.remoteId` as a local terminal-routing key.
2. Remote workspaces persisted `FileManager.default.temporaryDirectory` in `Workspace.path`.
3. `LocalBackend` accepted a live `Workspace` across actor boundaries, forcing model sendability workarounds.

Those concerns are now addressed in mainline code.

## Notes For Future Work

- Treat provider lifecycle identity (`remoteId`) and terminal routing identity (`sessionRoutingID` / `terminalSessionIdentifier`) as separate contracts.
- For remote-only providers such as Daytona and SSH, continue using `Workspace.remotePathSentinel` for persisted paths and `localDirectoryURL` for host-filesystem access checks.
- Lume remains host-file-backed by design, so `localDirectoryURL` should continue to expose its local workspace path.
- If another remote provider is added, add tests around `WorkspaceProviderTarget.terminalSessionIdentifier`, provider lifecycle methods, and local-path gating rather than reviving this completed follow-up wholesale.

## References

- `Sources/WorkspaceManagerCore/Models/Models.swift`
- `Sources/WorkspaceManagerCore/Services/Protocols.swift`
- `Sources/WorkspaceManagerCore/Services/LocalBackend.swift`
- `Sources/WorkspaceManagerCore/Services/DaytonaWorkspaceProvider.swift`
- `Tests/WorkspaceManagerTests/ModelsTests.swift`
- `Tests/WorkspaceManagerTests/LocalBackendTests.swift`
