# Automation Surface Read Decision

## Status

Accepted as a creation-scoped operator capability.

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
