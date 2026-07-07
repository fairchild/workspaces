# WorkSpaces Automation API V1

The Automation API is a local app-shell control plane for trusted processes
running inside WorkSpaces terminal tiles. V1 is intentionally narrow: a caller
can discover its live shell context, list in-scope surfaces, and request core
tile mutations relative to its own tile.

This is the wire and maintainer reference. For example-first usage, see
[Automation API Guide](../automation-api.md). For rationale and future-expansion
boundaries, see [Automation API V1 Decision](../decisions/automation-api-v1.md).

The API is experimental and disabled by default. Enable it from the
Experimental Features settings, or force it on for development with:

```bash
WORKSPACES_AUTOMATION_API=1
```

## Trust Boundary

The listener is separate from the Claude hook listener. It binds a local Unix
domain socket named `automation.sock`, protected by its own `automation.lock`,
under the user-private WorkSpaces application support directory.

Terminal surfaces receive only the minimum discovery environment:

```bash
WORKSPACES_AUTOMATION_SOCKET=/path/to/automation.sock
WORKSPACES_AUTOMATION_HANDLE=<opaque capability handle>
```

The handle is the authority. Requests for scoped routes send it as
`x-workspaces-automation-handle`; requests do not get to name their tile,
surface, or host session. The app resolves the handle against its live mapping
to recover the caller tile, host session, surface kind, window scope, app
scope, and capabilities. Missing, stale, disabled, out-of-scope, or
under-capable handles fail closed. Context responses do not echo the handle.

Restart WorkSpaces after changing the Automation API experiment. Terminal
processes only receive automation environment when their surface is created.

Allowed and denied requests are appended to `automation-audit.jsonl` next to
the socket state. The audit log stores route-level metadata and error codes,
not terminal input or output.

## Invariants

- The socket listener is distinct from `AgentHookListener`.
- Only same-user local processes that can reach the user-private socket can
  connect.
- Scoped routes require `x-workspaces-automation-handle`.
- The server resolves caller identity from its live handle registry.
- Scoped requests must not accept caller-supplied `tileID`, `surfaceID`, or
  `hostSessionID`.
- Capabilities are enforced before each scoped operation.
- Mutation routes are stable product verbs, not raw `TileTreeAction` exposure.
- Browser mutation, resize/equalize, and global control are out of V1.
- Input injection is caller-scoped only and double-gated behind the
  `Automation Input Write` experiment; see
  [Automation Input Write Decision](../decisions/automation-input-write.md).

## Envelope

Every route returns a versioned JSON envelope:

```json
{ "v": 1, "ok": true, "result": {} }
```

```json
{
  "v": 1,
  "ok": false,
  "error": { "code": "missing_handle", "message": "Missing automation handle." }
}
```

## Routes

`GET /v1/health` is the only unauthenticated route. It reports listener
liveness only and does not prove that a terminal handle is valid.

Scoped routes require `x-workspaces-automation-handle`:

| Route | Behavior |
| --- | --- |
| `GET /v1/context` | Returns the caller's resolved context and capabilities. |
| `GET /v1/surfaces` | Returns visible terminal surfaces in the caller's window/app scope. |
| `POST /v1/tile/focus` | Focuses `left`, `right`, `up`, `down`, `next`, or `previous` relative to the caller tile. |
| `POST /v1/tile/split` | Splits `left`, `right`, `up`, or `down` from a primary tile. Each successful split creates a new terminal surface in the caller's tab. Secondary split-tile callers return `unsupported` in V1. |
| `POST /v1/tile/close` | Requests close for the caller tile through the normal close-confirmation path. |
| `POST /v1/input/write` | Experimental. Pastes `text` into the caller's own PTY; `submit: true` then presses Return as a synthetic key event (never an appended `\r`, which bracketed paste would insert literally). Body is `{"text": "...", "submit": false}`, at most 32 KiB UTF-8 of text. Requires the `input.write` capability, granted only while the Automation Input Write experiment is on. |

Mutation bodies must be projections over the supported operation, not raw tile
state. For example:

```json
{ "direction": "right" }
```

Bodies that try to supply target identifiers such as `tileID`, `surfaceID`, or
`hostSessionID` are rejected.

## Capabilities

Capabilities are attached to the live handle entry and returned in descriptors
for discovery. They do not broaden scope; the caller is still resolved from the
handle.

| Capability | Allows |
| --- | --- |
| `context.read` | `GET /v1/context` |
| `surfaces.read` | `GET /v1/surfaces` |
| `tile.focus` | `POST /v1/tile/focus` |
| `tile.split` | `POST /v1/tile/split` |
| `tile.close` | `POST /v1/tile/close` |
| `input.write` | `POST /v1/input/write` (experimental; granted per-handle only while the Automation Input Write experiment is enabled, and re-checked per request) |

Under-capable handles fail with `capability_denied`.

## Error Codes

| Code | Meaning |
| --- | --- |
| `disabled` | The experiment is off for this launch. |
| `capability_denied` | The handle does not include the required capability. |
| `missing_handle` | The scoped request omitted `x-workspaces-automation-handle`. |
| `stale_handle` | The handle is missing or no longer maps to a live terminal tile. |
| `invalid_request` | The request shape is not allowed, including caller-supplied target IDs. |
| `malformed_json` | A JSON body could not be decoded. |
| `route_not_found` | The route is not part of the API. |
| `method_not_allowed` | The path exists but the HTTP method is wrong. |
| `unsupported` | The requested V1 operation is not supported in the current context. |
| `internal_error` | Unexpected server-side failure. |

## CLI

The `workspaces` CLI wraps the socket API. Scoped commands read the same
environment that WorkSpaces injects into terminal surfaces.

```bash
workspaces automation health
workspaces automation health --json
workspaces automation context --json
workspaces surface list --json
workspaces tile focus --left
workspaces tile focus --right
workspaces tile focus --up
workspaces tile focus --down
workspaces tile focus --next
workspaces tile focus --previous
workspaces tile split --left
workspaces tile split --right
workspaces tile split --up
workspaces tile split --down
workspaces tile close
workspaces input write 'echo hi'
workspaces input write 'echo hi' --submit
```

## Implementation Map

| Concern | File |
| --- | --- |
| Wire models and envelopes | `Sources/WorkspaceManagerCore/Services/Automation/AutomationAPI.swift` |
| Socket listener and lock | `Sources/WorkspaceManagerCore/Services/Automation/AutomationListener.swift` |
| HTTP route projection | `Sources/WorkspaceManagerCore/Services/Automation/AutomationHTTPRouter.swift` |
| CLI socket client | `Sources/WorkspaceManagerCore/Services/Automation/AutomationSocketClient.swift` |
| CLI formatting | `Sources/WorkspaceManagerCore/Services/Automation/AutomationCLIFormatting.swift` |
| App-side controller | `Sources/WorkspaceManager/Views/MainWindow/AutomationController.swift` |
| Feature lifecycle and injection | `Sources/WorkspaceManager/App/AutomationIntegrationLifecycle.swift` |
| Terminal environment provider | `Sources/WorkspaceManager/Views/MainWindow/HostTerminalStateStore.swift` |
| Terminal config injection | `Sources/WorkspaceManager/Terminal/GhosttyTerminalConfig.swift` |
| CLI command router | `Sources/WorkspaceManagerCLI/main.swift` |

## Verification

After changing this API, run:

```bash
swift test --filter Automation
swift test
swift-format lint --strict --recursive Sources/ Tests/
./scripts/dev-smoke.sh --no-build
```

If docs or public examples changed, also run the docs checks listed in
[Docs Site Runbook](../README.md).

## V1 Non-Goals

V1 does not support browser mutation, opening web URLs, tab title or metadata
changes, writing into other tiles, resize/equalize, or global cross-workspace
control. Those capabilities require separate product and safety review before
they can be added. Caller-scoped input injection is the one reviewed
exception: it ships as the experimental, double-gated `input.write` capability
(see [Automation Input Write Decision](../decisions/automation-input-write.md)).
