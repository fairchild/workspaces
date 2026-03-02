---
topic: daytona
relates_to: after:vz-tahoe-execution-brief-plan
priority: 2
description: Replace Python CLI bridge with native Swift HTTP calls to Daytona REST API
---

# Daytona Native Swift API Integration

## Problem Statement

The Daytona backend currently shells out to a Python script (`scripts/daytona-sandbox-manager.py`) via `ProcessRunner` for every sandbox operation. Each call spawns `uv run --script`, which resolves dependencies and starts a Python interpreter. This adds ~1-2s latency per operation, requires `uv` on the host, prevents streaming progress updates, and makes error handling fragile (JSON-over-stdout/stderr).

Replacing the Python bridge with direct HTTP calls from Swift eliminates all external dependencies, enables streaming progress (SSE or polling), and cuts per-operation latency to network round-trip time only.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| HTTP client | `URLSession` (stdlib) | No external dependencies, async/await native, sufficient for REST |
| Auth storage | `~/.env` file → Keychain | Keychain is the macOS-native credential store; fall back to env var for dev |
| SSH token handling | Direct from API response | Same as Python — `POST /sandbox/{id}/ssh-access` returns `sshCommand` + `token` |
| Timeout handling | Poll sandbox state after start/stop | API returns immediately; SDK polls internally. We replicate with async polling |

## Daytona REST API Reference

### Base URL & Auth

```
Base: https://app.daytona.io/api
Auth: Authorization: Bearer <DAYTONA_API_KEY>
```

### Endpoints We Use

| Operation | Method | Endpoint | Notes |
|-----------|--------|----------|-------|
| Create | `POST /sandbox` | Body: `{"name": "...", "target": "us"}` |
| Get | `GET /sandbox/{id}` | Returns full sandbox object |
| List | `GET /sandbox/paginated?page=1&limit=50` | Returns `{items, total, page, totalPages}` |
| Start | `POST /sandbox/{id}/start` | Returns sandbox object |
| Stop | `POST /sandbox/{id}/stop` | Returns sandbox object |
| Archive | `POST /sandbox/{id}/archive` | Must be stopped first |
| Delete | `DELETE /sandbox/{id}` | Permanent |
| SSH Access | `POST /sandbox/{id}/ssh-access?expiresInMinutes=480` | Returns `{sshCommand, token, expiresAt}` |
| Git Clone | `POST /sandbox/{id}/toolbox/git/clone` | Body: `{"url": "...", "path": "/home/daytona/..."}` |

### Sandbox State Enum

```
started, stopped, archived, creating, starting, stopping, archiving,
restoring, destroying, destroyed, error, build_failed, pending_build,
building_snapshot, pulling_snapshot, resizing, unknown
```

### Response Shape (Sandbox Object)

```json
{
  "id": "abc123",
  "name": "my-sandbox",
  "state": "started",
  "desiredState": "started",
  "target": "us",
  "cpu": 2, "memory": 4, "disk": 20, "gpu": 0,
  "user": "daytona",
  "createdAt": "...", "updatedAt": "...",
  "autoStopInterval": 30,
  "autoArchiveInterval": 60
}
```

### SSH Access Response

```json
{
  "id": "access-id",
  "sandboxId": "sandbox-id",
  "token": "eyJhb...",
  "expiresAt": "2024-01-01T12:00:00Z",
  "sshCommand": "ssh -p 2222 daytona@sandbox-id.ssh.daytona.io -o StrictHostKeyChecking=no"
}
```

## Architecture

```
┌─────────────────────────────────────────────┐
│  DaytonaBackend (actor)                     │
│                                             │
│  Before:  runCommand → ProcessRunner → uv   │
│                          → Python → SDK     │
│                          → stdout JSON      │
│                                             │
│  After:   DaytonaHTTPClient                 │
│           → URLSession → REST API           │
│           → Codable decode                  │
│                                             │
│  Protocol unchanged — views don't change    │
└─────────────────────────────────────────────┘
```

## Implementation Phases

### Phase 1: HTTP Client + Core Operations

**Files to create:**
- `Sources/WorkspaceManagerCore/Services/DaytonaHTTPClient.swift` — URLSession wrapper with auth, base URL, error handling

**Files to modify:**
- `Sources/WorkspaceManagerCore/Services/DaytonaBackend.swift` — Replace `runCommand` internals with HTTP calls. Keep the actor, keep `DaytonaBackendProtocol` conformance unchanged.
- `Sources/WorkspaceManagerCore/Services/Protocols.swift` — No changes needed (protocol is stable)

**Acceptance criteria:**
- [ ] All existing operations work: create, start, stop, archive, delete, list, getSSHCommand
- [ ] No Python or `uv` dependency at runtime
- [ ] `swift build` succeeds, all tests pass
- [ ] API key loaded from environment variable (same as current)

### Phase 2: Credential Management

**Files to modify:**
- `Sources/WorkspaceManagerCore/Services/DaytonaBackend.swift` — Add Keychain lookup with env var fallback
- `Sources/WorkspaceManager/Views/` — Add a settings/preferences UI for entering the API key (or detect from `~/.env`)

**Acceptance criteria:**
- [ ] API key stored in Keychain on first successful use
- [ ] Graceful error when no key configured (not a crash)
- [ ] Settings UI to enter/update key

### Phase 3: Streaming Progress

**Files to modify:**
- `Sources/WorkspaceManagerCore/Services/DaytonaBackend.swift` — Add state polling during long operations (create, start, stop, archive)
- `Sources/WorkspaceManagerCore/Services/Protocols.swift` — Add progress callback parameter to lifecycle methods

**Acceptance criteria:**
- [ ] Create shows intermediate states: "Creating..." → "Starting..." → "Ready"
- [ ] Stop/archive show polling progress
- [ ] Sidebar status messages update in real-time

### Phase 4: Cleanup

**Files to delete:**
- `scripts/daytona-sandbox-manager.py` — No longer needed
- `scripts/daytona-spike.py` — Initial exploration script

**Acceptance criteria:**
- [ ] No Python scripts in the Daytona path
- [ ] `ProcessRunner` no longer used for Daytona operations
- [ ] `resolveUV()` removed from DaytonaBackend

## Verification Commands

```bash
swift build
swift test
./scripts/launch-dev.sh --no-build --no-activate
# Test full lifecycle: create → SSH → stop → start → archive → start → delete
```

## Rollback Plan

The Python script remains in git history. If the native client has issues, revert `DaytonaBackend.swift` to the `runCommand`-based implementation. The protocol layer is unchanged so views are unaffected.

## References

- `Sources/WorkspaceManagerCore/Services/DaytonaBackend.swift` — Current implementation
- `Sources/WorkspaceManagerCore/Services/Protocols.swift` — `DaytonaBackendProtocol`
- `scripts/daytona-sandbox-manager.py` — Python CLI being replaced
- Daytona API: `https://app.daytona.io/api` (Bearer token auth)
- Python SDK source: `daytona_api_client` package (reverse-engineered endpoints above)
