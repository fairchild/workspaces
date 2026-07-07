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
not terminal input or output. Each event carries an `operatorHandle` boolean so
operator calls are distinguishable from tile calls (`[A1]`).

### Operator scope (`[A1]`)

A second handle class for trusted callers *outside* any tile — dev sessions,
`evidence.sh`, CI — enabling capture-only global reads without living inside a
WorkSpaces terminal tile. See
[Automation Operator Scope Decision](../decisions/automation-operator-scope.md).

- **Opt-in launch.** Operator scope exists only when the launch enables it:
  the `Automation Operator Scope` experiment, or `WORKSPACES_AUTOMATION_OPERATOR=1`.
  It rides on the automation listener, so the Automation API experiment must
  also be on. Normal launches mint no operator credential and fail closed.
- **Minted credential.** An opt-in launch registers a per-launch operator
  handle in the live handle registry and writes it to a user-private file,
  `automation-operator.json`, next to `automation.sock`. The file is owner-only
  (0600) JSON: `{ "v", "socketPath", "handle", "capabilities" }`. Any same-user
  process reads it to call operator-scoped routes.
- **Dies with the launch.** The handle is in-memory; it is gone once the app
  exits, and the credential file is removed on a clean exit. A credential left
  behind by a crashed launch fails closed — its handle no longer resolves
  against the fresh registry (`stale_handle`).
- **Capture-only.** The initial operator capability set is `window.read`
  (list windows). `window.snapshot` arrives with the follow-on slice. Operator
  handles never carry tile mutation or `input.write`.

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
- Browser **read** (listing WorkSpaces-owned web surfaces) is supported; browser
  **mutation** (navigating, clicking, evaluating JS), resize/equalize, and global
  control remain out of V1.
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
| `GET /v1/windows` | **Operator scope.** Returns the app's on-screen windows with stable identifiers (`window.read`). Keyed by the AppKit window number — the same identity `CGWindowList`/ScreenCaptureKit address. Requires an operator handle; a tile handle lacks `window.read` and fails `capability_denied`. |
| `GET /v1/web-surfaces` | Returns the app's WorkSpaces-owned web surfaces (global, repo, or workspace scoped) with stable source id, display name, configured URL, and — only when a `WKWebView` is live — the live URL, title, and loading state. Read-only. |
| `GET /v1/web-surfaces/{id}/snapshot` | Returns a bounded PNG of the live web surface with stable source id `{id}`. Read-only pixels of an already-visible surface (`browser.read`). Fails closed when no `WKWebView` is live — never instantiates a hidden view. See [Web-surface snapshot bounds](#web-surface-snapshot-bounds). |
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
| `browser.read` | `GET /v1/web-surfaces` (read-only listing) and `GET /v1/web-surfaces/{id}/snapshot` (bounded PNG of a live surface); granted to default handles under the Automation API experiment |
| `window.read` | `GET /v1/windows` (list the app's windows); granted only to operator handles under the Automation Operator Scope experiment, never to tile handles |
| `tile.focus` | `POST /v1/tile/focus` |
| `tile.split` | `POST /v1/tile/split` |
| `tile.close` | `POST /v1/tile/close` |
| `input.write` | `POST /v1/input/write` (experimental; granted per-handle only while the Automation Input Write experiment is enabled, and re-checked per request) |

Under-capable handles fail with `capability_denied`.

## Web-surface snapshot bounds

`GET /v1/web-surfaces/{id}/snapshot` returns the standard success envelope with a
base64 PNG, not raw image bytes:

```json
{ "sourceID": "…", "encoding": "png", "width": 640, "height": 480,
  "byteCount": 12497, "data": "<base64 png>" }
```

`byteCount` is the raw (pre-base64) PNG size; `width`/`height` are its pixel
dimensions. Decode with `jq -r .result.data | base64 -d > snapshot.png`.

The snapshot is bounded three ways so a caller cannot pull an unbounded image or
wedge the server:

| Bound | Value | Behavior |
| --- | --- | --- |
| Max width | 1600 px (`WKSnapshotConfiguration.snapshotWidth`) | Output is scaled to at most this width. Capture uses the live view's visible bounds (viewport), never the full scroll height, so a long page is not captured in full. Backing-store scale (Retina) may 2× the pixel width. |
| Max raw bytes | 8 MiB | A PNG over the cap is rejected (`unsupported`), never truncated. |
| Timeout | 5 s | `takeSnapshot` is raced against a deadline; a capture that does not complete returns `unsupported` rather than blocking the automation server. |

Failure mapping (reusing the stable error codes): an id matching no web source →
`invalid_request`; a source with no live `WKWebView` → `unsupported`; a capture
timeout or over-cap PNG → `unsupported` (distinct messages); an internal capture
error → `internal_error`. Snapshotting a source whose view is not instantiated
never creates one — the request fails closed.

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

`workspaces window list` is the operator-scope command. Unlike the tile-scoped
commands, it reads the per-launch operator credential file (minted next to the
socket by an opt-in launch) rather than the injected terminal environment, so it
works from any same-user shell outside a WorkSpaces tile. Absent the credential
it fails closed with guidance.

```bash
workspaces window list
workspaces window list --json
```

## Implementation Map

| Concern | File |
| --- | --- |
| Wire models and envelopes | `Sources/WorkspaceManagerCore/Services/Automation/AutomationAPI.swift` |
| Socket listener and lock | `Sources/WorkspaceManagerCore/Services/Automation/AutomationListener.swift` |
| HTTP route projection | `Sources/WorkspaceManagerCore/Services/Automation/AutomationHTTPRouter.swift` |
| Web-surface snapshot encoding (pure) | `Sources/WorkspaceManagerCore/Services/Automation/WebSurfaceSnapshotEncoder.swift` |
| Operator credential store + provisioner | `Sources/WorkspaceManagerCore/Services/Automation/AutomationOperatorCredentialStore.swift` |
| Window enumeration (AppKit → descriptors) | `Sources/WorkspaceManager/Views/MainWindow/AutomationWindowEnumerator.swift` |
| Web-surface snapshot capture (MainActor) | `Sources/WorkspaceManager/Web/WebSurfaceSnapshotCapture.swift` |
| CLI socket client | `Sources/WorkspaceManagerCore/Services/Automation/AutomationSocketClient.swift` |
| CLI formatting | `Sources/WorkspaceManagerCore/Services/Automation/AutomationCLIFormatting.swift` |
| App-side controller | `Sources/WorkspaceManager/Views/MainWindow/AutomationController.swift` |
| Feature lifecycle and injection | `Sources/WorkspaceManager/App/AutomationIntegrationLifecycle.swift` |
| Terminal environment provider | `Sources/WorkspaceManager/Views/MainWindow/TileTreeStore.swift` |
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

V1 does not support browser mutation (navigating, clicking, filling, or
evaluating JavaScript in a web surface), opening web URLs, tab title or metadata
changes, writing into other tiles, resize/equalize, or global cross-workspace
*mutation*. Those capabilities require separate product and safety review before
they can be added. Read-only global window listing is the one reviewed
exception, and it is gated behind the opt-in operator scope above
(`window.read`), not granted to tile handles. Two reviewed exceptions widen the read/write surface
deliberately: caller-scoped input injection ships as the experimental,
double-gated `input.write` capability (see
[Automation Input Write Decision](../decisions/automation-input-write.md)), and
read-only web-surface reads ship as `browser.read` — both listing
(`GET /v1/web-surfaces`) and bounded snapshots
(`GET /v1/web-surfaces/{id}/snapshot`), granted to default handles under the
Automation API experiment. Browser *mutation* (navigating, clicking, filling, or
evaluating JavaScript in a web surface) remains out of scope pending the
JavaScript-evaluation trust-boundary review.
