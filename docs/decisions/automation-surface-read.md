# Automation Surface Read Decision

## Status

Accepted; widened to any live surface in the attached window by #1265
(09c84ac8). The amendment below records the widening and its stated reason; the
decision as first accepted is kept under it.

## Context

Automation already exposes structure (`context.read`, `surfaces.read`,
`workspace.read`) and pixels (`window.snapshot`, web-surface snapshots), but not
terminal text. Reading terminal content is a larger grant than capturing the app's
own window: it can expose the human owner's private terminal scrollback. The
route therefore needs its own authority boundary instead of silently inheriting
operator scope.

GhosttyKit at the pinned commit exposes a real plain-text extraction API:
`ghostty_surface_read_text(surface, ghostty_selection_s, ghostty_text_s*)`, with
`ghostty_surface_free_text` for ownership cleanup. The app's bridge uses that API
over the whole screen/scrollback selection; no OCR or screenshot workaround is
involved.

## Decision

`POST /v1/surface/read` is guarded by `surface.read`, granted only to operator
handles. An operator handle reads bounded plain text from any live terminal
surface in the window currently attached to the Automation API
(`AutomationController.automationReadSurface`).

- Tile handles fail `capability_denied`.
- A surface that is closed, not ready to read, or in another window answers
  `stale_handle`. With no window attached, the request fails `unsupported`.
- `AutomationHandleRegistry` records `operatorHandle -> created hostSessionID`
  attribution when `workspace.create` completes with an attached terminal; the
  read does not consult it.
- The route returns plain text only, clamped to 500 requested lines and 256 KiB
  UTF-8. Over-cap line requests are clamped, not rejected.
- Audit records the route, the operator flag, the surface id, requested/returned
  line counts, and allow/deny result. It never records the terminal text.

## Amendment (2026-09-14)

PR #1265 (09c84ac8, typed wait and focus primitives) removed the creation check
from `automationReadSurface`; this record was not updated with it. The commit
message states the change and its reason: "surface.read relaxes past
created-this-launch for operator handles (read-only, opt-in, audited); tile
handles stay denied." The PR body gives the same three grounds: operator handles
"now read any live terminal surface (read-only, opt-in per launch, audited per
call)". The issue it closed, #1225, asked for it in the same terms: "Relax
`surface.read` past created-this-launch for operator handles (read-only, already
opt-in + audited)."

The same PR body says "the created-this-launch registry remains for audit
lineage only". At beb38b24 the registry's lookup,
`AutomationHandleRegistry.operatorHandle(_:createdHostSessionID:)`, has no
production caller; per-surface lineage comes from the audit event's surface id.

The rule #1265 adopted is the Blanket Operator Read alternative below, bounded
to the attached window. The concern that alternative's rejection names still
describes the grant: an operator credential reads the scrollback of terminals a
person opened. The separate authority boundary the Context asks for is now the
`surface.read` capability itself, which every operator handle carries.

### Decision as first accepted

Status: Accepted as a creation-scoped operator capability.

Add `POST /v1/surface/read` guarded by `surface.read`, granted only to operator
handles. A request may read only a terminal surface whose `attachedSurfaceID`
came from a completed `workspace.create` call made by the same operator handle in
the same app launch.

- `AutomationHandleRegistry` records `operatorHandle -> created hostSessionID`
  attribution when `workspace.create` completes with an attached terminal.
- Reads from another operator handle, a tile handle, or an unattributed surface
  fail `capability_denied`.
- The route returns plain text only, clamped to 500 requested lines and 256 KiB
  UTF-8. Over-cap line requests are clamped, not rejected.
- Audit records the route, surface id, requested/returned line counts, and
  allow/deny result. It never records the terminal text.

## Rejected Alternatives

### Blanket Operator Read

Adopted in #1265 (09c84ac8), bounded to the window attached to the Automation
API, on the grounds that the read is "read-only, opt-in, audited"; see the
amendment above. The rejection as first written:

Rejected. Operator scope is useful for same-user evidence and app orchestration,
but terminal text read-back is qualitatively different from listing windows or
capturing app-owned pixels. It would let automation read arbitrary human-owned
terminal tiles, which is too broad for this route.

### Experiment-Gated All-Surface Read

Rejected for this pass because narrow creation attribution was straightforward:
`workspace.create` already reports the attached terminal surface, and the handle
registry already owns per-launch operator bookkeeping.

### OCR Or Pixel Parsing

Rejected. GhosttyKit exposes a real text API at the pinned commit. If that API
disappears in a future pin, this route should fail closed or be redesigned, not
fall back to OCR.
