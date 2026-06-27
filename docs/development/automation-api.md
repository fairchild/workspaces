# WorkSpaces Automation API V1

The Automation API is a local app-shell control plane for trusted processes
running inside WorkSpaces terminal tiles. V1 is intentionally narrow: a caller
can discover its live shell context, list in-scope surfaces, and request core
tile mutations relative to its own tile.

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
| `POST /v1/tile/split` | Splits `left`, `right`, `up`, or `down` from a primary tile. Existing splits are focused or relaid out without claiming a new surface. Secondary split-tile callers return `unsupported` in V1. |
| `POST /v1/tile/close` | Requests close for the caller tile through the normal close-confirmation path. |

Mutation bodies must be projections over the supported operation, not raw tile
state. For example:

```json
{ "direction": "right" }
```

Bodies that try to supply target identifiers such as `tileID`, `surfaceID`, or
`hostSessionID` are rejected.

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
```

## V1 Non-Goals

V1 does not support browser mutation, opening web URLs, tab title or metadata
changes, input injection, resize/equalize, or global cross-workspace control.
Those capabilities require separate product and safety review before they can
be added.
