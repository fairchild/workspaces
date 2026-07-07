# Automation Operator Scope and Two-Arc Strategy

## Status

Accepted 2026-07-07. Execution tracked as milestones
[#16 `[A1]`](https://github.com/fairchild/workspaces/milestone/16) (evidence
capture) and [#17 `[A2]`](https://github.com/fairchild/workspaces/milestone/17)
(workspace orchestration).

## Context

Two pressures converged on the Automation API:

1. **Evidence capture is unreliable.** Agent sessions repeatedly fail to
   produce screenshot evidence for PRs: live `screencapture` fails on locked
   screens and lacks Screen Recording TCC in capturing shells, shared-desktop
   rules forbid activation-driving automation while the owner works, and the
   sanctioned fallbacks have fidelity ceilings (ImageRenderer cannot capture
   full-window composition or GhosttyKit Metal surfaces; qlmanage-rendered
   logs show no UI).
2. **Agent orchestration is a strategic direction.** An agent should be able
   to drive the app itself — create workspaces, select them, type into their
   terminals — with a CLI, App Intents, and eventually a companion app as
   entry surfaces.

[Automation API V1](./automation-api-v1.md) serves neither directly: every
handle is tile-scoped, so a caller must live inside a WorkSpaces terminal tile
to hold any authority, and V1's non-goals park global control pending safety
review. Evidence capture is the first concrete customer forcing that review.

A survey of macOS scriptability mechanisms (App Intents, AppleScript/SDEF,
URL schemes, embedded HTTP, Darwin notifications, user-script hooks,
companion CLI) confirmed none improves on the existing Unix-socket control
plane for agent callers: the socket is same-user-only by filesystem
permissions, carries a capability model and audit log, and already has a CLI.

## Decision

### One spine, veneers on top

The Automation API remains the single control plane. The `workspaces` CLI,
App Intents, and any companion app are transports over the same internal verb
layer — never parallel automation mechanisms with their own trust surfaces.
Surface order: CLI first, App Intents second, companion SwiftUI app last.

### Two arcs

- **Arc 1 — evidence (`[A1]`).** Capture only. One command from any agent
  session launches the app in a fixture state, snapshots a window, and
  uploads — locked-screen-safe, zero focus stealing. App state staging stays
  launch-time fixture mode; upload stays `scripts/evidence.sh`.
- **Arc 2 — orchestration (`[A2]`).** Workspace verbs
  (`workspace.list/create/select`) over a gesture-verb layer, then the App
  Intents veneer, then an API-driven smoke lane. Queued behind Arc 1, which
  proves the trust model.

### Operator scope

A second handle class for trusted callers outside any tile (dev sessions,
`evidence.sh`, CI):

- **Opt-in launch.** Operator scope exists only when the launch enables it
  (environment variable or Experimental setting). Normal launches mint no
  operator credential and fail closed.
- **Minted credential.** The app writes a per-launch operator handle to a
  user-private file next to `automation.sock`; any same-user process reads
  it. The handle registers in the live handle registry like tile handles,
  resolves with operator capabilities, and dies with the launch.
- **Audit-tagged.** Operator calls are distinguishable in
  `automation-audit.jsonl`.
- **Capture-only at first.** The initial operator capability set is
  `window.read` (list windows) and `window.snapshot` (PNG of a composited
  window). Mutation capabilities arrive only with Arc 2's verbs.

### Verb contract: verbs = clicks

Every mutation verb enters the same UI path the equivalent user gesture does.
`tile.close` set the precedent (it routes through the normal
close-confirmation flow); the desktop-ui-smoke driver already drives the
sidebar's real entry points (the create-workspace helper and the
selected-workspace binding whose setter attaches the terminal and requests
focus). Arc 2 promotes those entry points into an internal verb layer rather
than adding service-layer RPC.

Rationale, concretely:

- A snapshot taken after a verb must show what actually happened. A
  data-layer `workspace.select` bypasses the selection binding, so the
  sidebar highlight and terminal attach never occur and the screenshot shows
  stale UI — evidence that lies.
- `input.write` must never land in the wrong PTY. A data-layer
  `workspace.create`/`select` leaves the previously focused terminal live,
  misrouting the next write.
- Refactors that disconnect UI wiring stay visible: verbs entering the real
  binding path fail exactly when a user click would.

Dialogs surface as structured `confirmation_required` responses; verbs never
hang on modal UI. Verbs that cannot run without a live window return
`unsupported` rather than falling back to data-layer writes.

### Smoke-lane policy

`desktop-ui-smoke` stays UI-driven. An API-driven lane may run alongside it
and can replace it only after demonstrating the identical JSONL milestone
sequence (`workspace_created`, `sidebar_updated`, `terminal_session_attached`,
`surface_focused`). The residual blind spot after such a migration —
NSEvent-level hit-testing — is accepted knowingly, not silently.

### Facts before mechanism

Arc 1's snapshot mechanism (ScreenCaptureKit vs `CGWindowList` vs layer
readback) is chosen by a research spike, not assumed. The spike must answer
with citations or working probe code: (a) whether capturing your own app's
windows requires Screen Recording TCC, and (b) whether the GhosttyKit
CAMetalLayer surface can be read back (framebufferOnly, IOSurface, drawable
capture). The `WindowSnapshotService` interface stays stable regardless of
which mechanism wins.

## Consequences

- The V1 non-goal "global cross-workspace control" is partially superseded:
  read-only global capture arrives with `[A1]`; mutation verbs arrive with
  `[A2]` under the verbs-=-clicks contract. Each widening remains a reviewed,
  capability-gated exception, consistent with how `input.write` and
  `browser.read` landed.
- The evidence-loop Phase 2 items parked at P2 (capture handshake, VM lanes)
  are partially promoted: in-app self-capture becomes the primary path; the
  VM/tart-ui lane remains the full-fidelity fallback if the spike returns bad
  news on TCC or Metal readback.
- Verbs cost more to build than service-layer routes and inherit UI
  nondeterminism when the app is backgrounded (the smoke already treats
  `surface_focused` as best-effort). That cost is accepted; headless
  determinism for state staging comes from fixture mode, not from weakening
  verb semantics.
- App Intents and companion-app work cannot introduce verb semantics of their
  own; they call the same verb layer, so Siri saying "done" and the sidebar
  updating are the same event.
