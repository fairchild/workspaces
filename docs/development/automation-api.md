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

In `tmux_per_session` mode the handle also travels in the tmux *session's* own
environment: `new-session -e` seeds it at creation, and a chained
`set-environment` in the same command sequence re-points a session that outlived
an earlier launch (tmux ignores `-e` when `-A` attaches). One tmux server backs
every session on the `-L workspaces` socket and a pane inherits the server's
environment, so without per-session wiring a tile would read the handle of
whichever tile happened to start the server, and its in-tile verbs would mutate
that tile instead (#1257).

This scopes which handle a pane *receives*. It does not scope which handles are
*readable*: the `-L workspaces` socket is one same-user trust domain, and any
pane on it can enumerate the other sessions and read their environment
(`tmux list-sessions`, `tmux show-environment -t <session>`), so a process in one
tile can still obtain another tile's handle and act as that tile. The property
gained is correct targeting for well-behaved callers, not secrecy between tiles.
What separates tiles from anything else is unchanged: the socket's own
permissions and the user account that owns it, exactly as for `automation.sock`
above.

Two consequences survive the fix. A shell already running in a reattached pane
keeps the environment it was spawned with — tmux cannot rewrite a live process —
so after a relaunch that pane's handle is stale until a new shell starts in the
session. And tmux older than 3.2 has no `new-session -e`, so there the launch can
only set the environment after the session is created and a newly created
session's *first* pane inherits the tmux server's environment; later panes,
reattaches, and every pane on tmux 3.2+ are unaffected. The app resolves the
installed tmux version once per launch and logs a notice when it takes that
fallback.

Allowed and denied requests are appended to `automation-audit.jsonl` next to
the socket state. The audit log stores route-level metadata and error codes,
not terminal input or output. Each event carries an `operatorHandle` boolean so
operator calls are distinguishable from tile calls (`[A1]`). The file rotates
at 5 MB (two rotated files kept, `.1`/`.2`). A completed mutation whose
response could not be written back to a disconnected caller appends a follow-up
entry with `responseUndelivered: true`; reconcile with a read verb.

Both socket ends carry deadlines: the listener closes connections that do not
deliver a full request within 10 s, bounds response writes the same way, and
answers connections over its small concurrency cap with a `busy` error. The
client sets 30 s send/receive socket timeouts, so a hung app surfaces as a
typed timeout in the CLI instead of a wedged shell.

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
- **Capture, read, and operator mutations.** The operator capability set is
  `window.read` (list windows), `window.snapshot` (composited PNG of a listed
  window), `workspace.read` (list repos and workspaces), and `surface.read`
  (bounded terminal text read-back for surfaces this same operator handle
  created through `workspace.create` this launch), plus
  `workspace.select` and `workspace.create`, reviewed exceptions that drive real
  UI gestures rather than data-layer writes
  (see [Verb contract](#verb-contract-verbs--clicks)). Operator handles still
  never carry tile mutation or `input.write`.

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
- Mutation verbs enter the same UI gesture the equivalent user action does — they
  never write the data layer directly. See [Verb contract](#verb-contract-verbs--clicks).
- App Intents are in-process, user-initiated, OS-mediated veneers; they do not
  require the Automation API or Operator Scope experiments and do not expose a
  socket or process-readable operator credential.
- Browser **read** (listing WorkSpaces-owned web surfaces) is supported; browser
  **mutation** (navigating, clicking, evaluating JS), resize/equalize, and global
  control remain out of V1.
- Input injection is caller-scoped only and double-gated behind the
  `Automation Input Write` experiment; see
  [Automation Input Write Decision](../decisions/automation-input-write.md).
- Terminal text read-back is creation-scoped to the operator handle that created
  the workspace terminal via `workspace.create` in this launch; see
  [Automation Surface Read Decision](../decisions/automation-surface-read.md).

## Verb contract: verbs = clicks

Every mutation verb enters the same UI path the equivalent user gesture does. A
verb never writes the service or SwiftData layer directly; it drives the real UI
entry point and inherits exactly what a click produces. The single place this rule
is enforced is the internal gesture-verb layer
(`AutomationGestureVerbs`): it is constructed with *only* gesture closures — the
app's real UI entry points — and holds no backend handle, so a verb structurally
cannot bypass the UI.

`workspace.select` is the exemplar: selecting a workspace via the API writes the
*same selection binding* a sidebar click writes — the binding whose setter attaches
the terminal session and requests focus — so an API-driven select produces the
identical user-visible reactions a click does. `workspace.create` follows the
same rule for creation: it enters the sidebar create helper used by the New
Workspace sheet and desktop UI smoke driver, so the created workspace arrives
selected with its terminal attached. Concretely, this is why the rule matters:

- **A snapshot taken after a verb shows what actually happened.** A data-layer
  `workspace.select` would flip selection state without attaching the terminal, so a
  follow-up `window.snapshot` would show stale UI — evidence that lies. Entering the
  binding makes the snapshot honest.
- **The next input lands in the right PTY.** Selecting workspace A attaches (and
  activates) A's terminal surface, so a subsequent write targets A. A data-layer
  select would leave the previously focused terminal live and misroute the write —
  the wrong-PTY bug the regression test `selecting workspace A then workspace B routes
  input to each workspace's own PTY` guards against.
- **Refactors that disconnect UI wiring stay visible.** A verb entering the real
  binding fails exactly when a user click would, so a broken selection path is caught
  by the verb, not hidden behind a service call that still "succeeds."

Verbs return a structured outcome so dialogs and dead-ends become data, never a
hang or a fallback:

| Outcome | Meaning | Wire |
| --- | --- | --- |
| `completed` | The gesture ran through the real UI path; the result reports what it did (e.g. `attachedTerminal`, `attachedSurfaceID`). | Success envelope, `outcome: "completed"`. |
| `confirmation_required` | The gesture would surface a modal; the payload names what the user would confirm. Surfaced as data so a verb never blocks on modal UI. `workspace.create` uses this for provider setup confirmations. | Success envelope, `outcome: "confirmation_required"`, with `confirmation`. |
| `unsupported` | The verb cannot run in the current context — most often no live window. It fails closed rather than falling back to a data-layer write. | Error envelope, code `unsupported`. |

An id that resolves to no tracked repo or workspace fails `invalid_request` (it is
not a gesture outcome — nothing was driven). App Intents and any companion app call
the same verb layer, so "Siri said done" and "the sidebar updated" are the same
event.

### App Intents veneer

The Shortcuts/Siri/Spotlight surface exposes `workspace.list`, `workspace.select`,
and `workspace.create` only as an App Intents veneer over this automation spine.
Entity queries list repos and workspaces through `automationWorkspaces`, and
mutation intents call `automationSelectWorkspace` / `automationCreateWorkspace`
on the app-side controller with an in-process operator handle. They do not read
or write SwiftData directly, do not call workspace services directly, and do not
carry their own fallback semantics. If the controller reports `unsupported`
because no live window is attached, the intent surfaces that error; if the verb
returns `confirmation_required`, the intent maps it to the native App Intents
confirmation prompt before reporting the outcome.

App Intents are user-initiated by Shortcuts/Siri/Spotlight and run in process,
so their handle is registered only in memory and never leaves the app or
exposes a socket. Minting is still gated on the Operator Scope experiment — the
same opt-in the socket-side credential requires, re-checked on every intent
call — so with the experiment off the intents fail closed with a clear
disabled error (`capability_denied`). The Automation API experiment continues
to gate only the external socket surface and the process-readable operator
credential used by CLI/dev/CI callers; App Intents do not require the
listener.

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

Error payloads may carry a `retryable` boolean documenting retry semantics:
`true` marks a transient failure the same request may clear (`terminal_active`),
`false` marks a condition that will not resolve without intervention
(`close_blocked_by_confirmation`). Codes without retry guidance omit the field —
absent means "unspecified", never "false".

## Routes

`GET /v1/health` is the only unauthenticated route. It reports listener
liveness plus server metadata (`pid`, listener `launchedAt`, `appVersion`,
`build`, active automation experiment keys, and `protocolVersion`) so callers
can distinguish coexisting app instances. It does not prove that a terminal
handle is valid.

```json
{
  "status": "ok",
  "server": {
    "pid": 7301,
    "launchedAt": "2026-07-08T08:35:44Z",
    "appVersion": "dev",
    "build": "debug",
    "experiments": ["automationAPI", "automationInputWrite", "automationOperator"],
    "protocolVersion": 1
  },
  "system": { "capabilities": [ … ] }
}
```

Scoped routes require `x-workspaces-automation-handle`:

| Route | Behavior |
| --- | --- |
| `GET /v1/context` | Returns the caller's resolved context and capabilities. |
| `GET /v1/surfaces` | Returns visible terminal surfaces in the caller's window/app scope. |
| `GET /v1/windows` | **Operator scope.** Returns the app's on-screen windows with stable identifiers (`window.read`). Keyed by the AppKit window number — the same identity `CGWindowList`/ScreenCaptureKit address. Requires an operator handle; a tile handle lacks `window.read` and fails `capability_denied`. |
| `POST /v1/window/snapshot` | **Operator scope.** Returns a composited PNG of the app window named by the body's `windowID` (a `window.read` id). The capture includes the full window — sidebar chrome *and* the GhosttyKit terminal surface — and works with the app backgrounded (no activation). Requires `window.snapshot`; own-window only, so an id the app does not own fails `invalid_request`. See [Window snapshot](#window-snapshot). |
| `GET /v1/workspaces` | **Operator scope.** Returns the app's tracked repos and workspaces with stable SwiftData model ids, names, and enough state to target: per workspace, its `status`, `isArchived`, `backend`, and whether it `isSelected`; per repo, whether it `isSelected`. Read-only — mutation verbs use these stable targets. Requires `workspace.read`; a tile handle lacks it and fails `capability_denied`. See [Workspace list](#workspace-list). |
| `POST /v1/workspace/select` | **Operator scope, mutation.** Selects the workspace named by the body's `workspaceID` (a `workspace.read` id) by driving the *same* selection gesture a sidebar click takes — the binding whose setter attaches the terminal and requests focus. Returns a structured gesture outcome (`completed`/`confirmation_required`); a live-window-less app fails `unsupported`, an unknown/non-UUID id fails `invalid_request`. Requires `workspace.select`. This is the verbs-=-clicks exemplar — see [Verb contract](#verb-contract-verbs--clicks) and [Workspace select](#workspace-select). |
| `POST /v1/workspace/create` | **Operator scope, mutation.** Creates a workspace in the repo named by `repoID` (from `workspace.read`) by driving the sidebar's real create helper. Body is `{"repoID":"…","name":"…","providerID":"local","guestOS":null,"select":true,"fromRef":"origin/main"}`; `providerID` defaults to `local`, `select` defaults to `true`, and `fromRef` is omitted by default. Returns `completed` with the created workspace and, when selected, the attached terminal, or `confirmation_required` with provider setup confirmation details. Requires `workspace.create`; tile handles fail `capability_denied`. See [Workspace create](#workspace-create). |
| `POST /v1/surface/read` | **Operator scope, content read.** Reads plain text from any live terminal surface. Body is `{"surfaceID":"…","lines":200}` where `surfaceID` is a live host-session id (e.g. the `attachedSurfaceID` from a create/select result). Requests above 500 lines are clamped; output is capped at 256 KiB UTF-8. Requires `surface.read`; tile handles fail `capability_denied`. See [Surface read](#surface-read). |
| `POST /v1/wait` | **Operator scope, typed wait.** Evaluates a condition (`surface_attached`, `workspace_selected`, `surface_text_matches`, `prompt_ready`) server-side until satisfied, a bounded timeout elapses, or current state proves it unsatisfiable. Body is `{"for":"…","predicate":{…},"timeoutMS":n}`; the outcome is the typed enum `satisfied` / `timed_out` / `not_applicable`, never a bare boolean. Topology/selection conditions require `workspace.read`; content conditions require `surface.read`. See [Wait](#wait). |
| `GET /v1/focus` | **Operator scope.** Truthful report of the app's live focus state: `{appIsActive, keyWindowID, firstResponderSurfaceID, focusPossible}`. `focusPossible: false` marks a no-activate (or CI) launch where the app cannot take focus — absent focus is then "unavailable", not a focus failure. Requires `window.read`. See [Focus](#focus). |
| `POST /v1/workspace/archive` | **Operator scope, mutation.** Archives the workspace named by the body's `workspaceID` (a `workspace.read` id) by driving the same sidebar archive action as the row menu. `{"teardownTerminals":true}` kills the workspace's tmux sessions and retires its terminal tiles first, so a live terminal cannot fail the call. Returns `completed` with the archived workspace id, post-gesture selection state, and (after teardown) a teardown report, or `confirmation_required` if the UI path ever reaches a modal. A live terminal without teardown fails typed: `terminal_active` (`retryable: true`) on the exit-timeout, `close_blocked_by_confirmation` (`retryable: false`) when the close-confirmation blocks. A live-window-less app fails `unsupported`, an unknown/non-UUID id fails `invalid_request`. Requires `workspace.archive`; tile handles fail `capability_denied`. See [Workspace archive](#workspace-archive). |
| `GET /v1/web-surfaces` | Returns the app's WorkSpaces-owned web surfaces (global, repo, or workspace scoped) with stable source id, display name, configured URL, and — only when a `WKWebView` is live — the live URL, title, and loading state. Read-only. |
| `GET /v1/web-surfaces/{id}/snapshot` | Returns a bounded PNG of the live web surface with stable source id `{id}`. Read-only pixels of an already-visible surface (`browser.read`). Fails closed when no `WKWebView` is live — never instantiates a hidden view. See [Web-surface snapshot bounds](#web-surface-snapshot-bounds). |
| `POST /v1/tile/focus` | Focuses `left`, `right`, `up`, `down`, `next`, or `previous` relative to the caller tile. |
| `POST /v1/tile/split` | Splits `left`, `right`, `up`, or `down` from a primary tile. Each successful split creates a new terminal surface in the caller's tab. Secondary split-tile callers return `unsupported` in V1. |
| `POST /v1/tile/close` | Requests close for the caller tile through the normal close-confirmation path. The result reports `outcome: "requested"` with `changed: false` — close is fire-and-forget and Ghostty may still prompt, so the API never claims the close landed. |
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
| `window.read` | `GET /v1/windows` (list the app's windows) and `GET /v1/focus` (truthful focus report); granted only to operator handles under the Automation Operator Scope experiment, never to tile handles |
| `window.snapshot` | `POST /v1/window/snapshot` (composited PNG of a listed window); granted only to operator handles, never to tile handles |
| `workspace.read` | `GET /v1/workspaces` (list the app's repos and workspaces) and `POST /v1/wait` for the `surface_attached` / `workspace_selected` conditions; granted only to operator handles under the Automation Operator Scope experiment, never to tile handles |
| `workspace.select` | `POST /v1/workspace/select` (drive the real selection gesture for a workspace); granted only to operator handles, never to tile handles |
| `workspace.create` | `POST /v1/workspace/create` (drive the real sidebar create helper for a repo); granted only to operator handles, never to tile handles — distinct from `workspace.read` and `workspace.select` so the read/write split stays legible |
| `surface.read` | `POST /v1/surface/read` (bounded plain-text terminal read-back for any live terminal surface) and `POST /v1/wait` for the `surface_text_matches` / `prompt_ready` conditions; granted only to operator handles, never to tile handles |
| `workspace.archive` | `POST /v1/workspace/archive` (drive the real sidebar archive action for a workspace); granted only to operator handles, never to tile handles |
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

## Window snapshot

`POST /v1/window/snapshot` (operator scope, `window.snapshot`) returns a
composited PNG of one of the app's windows. The body names the target by the
`windowID` a caller obtained from `GET /v1/windows`:

```json
{ "windowID": "42" }
```

The success envelope carries the same base64-PNG shape as the web-surface
snapshot, keyed by `windowID`:

```json
{ "windowID": "42", "encoding": "png", "width": 2800, "height": 1800,
  "byteCount": 481203, "data": "<base64 png>" }
```

`byteCount` is the raw (pre-base64) PNG size; `width`/`height` are its true pixel
dimensions (Retina-scaled, never down-sampled). Decode with
`jq -r .result.data | base64 -d > window.png`.

Mechanism and properties (chosen by spike
[#915](https://github.com/fairchild/workspaces/issues/915), recorded in the
[operator-scope ADR](../decisions/automation-operator-scope.md)):

- **`CGWindowListCreateImage` scoped to the app's own window number.** TCC-free
  for own windows (no Screen Recording grant, no prompt) and full composited
  fidelity — sidebar chrome *and* the GhosttyKit `IOSurfaceLayer` terminal
  surface in one call. Deprecated in macOS 14 but functional; ScreenCaptureKit is
  the migration target behind the stable `WindowSnapshotService` interface.
- **Backgrounded, no focus steal.** WindowServer retains each window's IOSurface
  regardless of z-order, so a non-frontmost or occluded window still yields its
  real last-composited content. The route never activates the app or reorders the
  window.
- **Own-window only.** The `windowID` must belong to a window the app owns (the
  set `window.read` lists); any other id fails `invalid_request`. This is the
  security boundary — an operator cannot capture a stranger's window.
- **Bound.** A PNG over 64 MiB is rejected (`unsupported`), never truncated.
  There is no width bound: the capture is the window at its true composited
  resolution, since full-fidelity evidence is the point of this lane.

Failure mapping: an id naming no app-owned window → `invalid_request`; a window
that is not compositing (minimized, off the active Space, or locked screen) →
`unsupported`; an over-cap PNG → `unsupported`; an internal capture/encode error
→ `internal_error`. Locked-screen full-window capture is not achievable in-process
(every composited path fails when the session is locked); that evidence keeps the
local VM fallback lane.

## Workspace list

`GET /v1/workspaces` (operator scope, `workspace.read`) returns the app's tracked
repos and workspaces so mutation verbs have stable targets. It is read-only: no
mutation rides this route.

```json
{
  "repos": [
    { "repoID": "…", "name": "workspaces", "path": "/Users/me/code/workspaces", "isSelected": true }
  ],
  "workspaces": [
    { "workspaceID": "…", "repoID": "…", "name": "feature-a",
      "path": "/Users/me/.workspaces/workspaces/feature-a", "branch": "feature-a",
      "status": "active", "isArchived": false, "backend": "local", "isSelected": true }
  ],
  "system": {
    "capabilities": [
      "window.read", "window.snapshot", "workspace.read",
      "workspace.select", "workspace.create", "surface.read", "workspace.archive"
    ]
  }
}
```

- **Stable identity.** `repoID` and `workspaceID` are the SwiftData model ids —
  stable across launches, the identity later verbs target. `workspaces[].repoID`
  ties a workspace back to its source repo.
- **Enough state to target.** Each workspace carries `status` (raw
  `WorkspaceStatus`: `provisioning`/`active`/`stopped`/`archived`), `isArchived`,
  `backend` (the backend identifier, e.g. `local`/`lume`), and `isSelected`
  (whether it is the workspace currently selected in the app). Each repo carries
  `isSelected` (whether it is the repo selected for its landing view).
- **Live app state.** The listing reflects what the *running app* currently has,
  read from the live SwiftData models and selection state — distinct from the
  CLI's own local-state store (`workspaces ws list`).

## Workspace create

`POST /v1/workspace/create` (operator scope, `workspace.create`) creates a
workspace by driving the sidebar create helper used by the New Workspace sheet
and desktop UI smoke driver. The body names a repo from `workspace.read`; `name`
is the workspace name; `providerID` defaults to `local`; `guestOS` is optional
and used by providers that support guest OS variants; `select` is optional and
defaults to `true`; `fromRef` is optional and, when present, is fetched before
the workspace branch is created:

```json
{
  "repoID": "…",
  "name": "feature-a",
  "providerID": "local",
  "guestOS": null,
  "select": false,
  "fromRef": "origin/main"
}
```

Omitting `select` and `fromRef` preserves the previous behavior exactly:
creation branches from the source repo's local `HEAD`, selects the created
workspace, and attaches/activates its terminal through the normal selection
binding.

The success envelope reports the structured gesture outcome and, when the
workspace is selected on completion, the selected and attached workspace
terminal:

```json
{
  "repoID": "…",
  "workspaceID": "…",
  "workspaceName": "feature-a",
  "workspacePath": "/Users/me/.workspaces/workspaces/feature-a",
  "outcome": "completed",
  "changed": true,
  "selectedWorkspaceID": "…",
  "attachedTerminal": true,
  "attachedSurfaceID": "…",
  "system": { "capabilities": [ … ] }
}
```

If the UI path reaches provider setup or another modal surface, the verb returns
success with `outcome: "confirmation_required"` and a payload naming what the
user must confirm:

```json
{
  "repoID": "…",
  "workspaceName": "feature-a",
  "outcome": "confirmation_required",
  "changed": false,
  "confirmation": {
    "action": "workspace.create",
    "title": "Set Up Lume",
    "message": "Create macOS workspace 'feature-a' requires Lume setup confirmation.",
    "providerID": "lume",
    "providerDisplayName": "Lume",
    "primaryButtonTitle": "Set Up Lume"
  },
  "message": "Create macOS workspace 'feature-a' requires Lume setup confirmation.",
  "system": { "capabilities": [ … ] }
}
```

- **Same path as the UI.** The verb enters the sidebar create helper, not
  `WorkspaceService` or SwiftData directly. On completion, the helper selects the
  created workspace through the same binding the UI uses, which attaches and
  activates the workspace terminal. If `select` is `false`, the helper skips only
  that final selection write so the owner's current sidebar selection and focus
  stay untouched.
- **Ref freshness.** If `fromRef` is present, WorkSpaces validates it as a
  plausible git ref name, fetches before creating the worktree, and creates the
  workspace branch from that fetched ref. Empty, whitespace-padded, option-like,
  or shell-metacharacter-shaped values fail `invalid_request`. Omitted `fromRef`
  keeps the previous local-`HEAD` behavior.
- **Wrong-PTY guard.** `attachedSurfaceID` is the active terminal session after
  create when `select` is true. A following caller-scoped input write targets
  that PTY, not the repo terminal or a previously selected workspace. With
  `select: false`, the response reflects the pre-existing selection/active
  surface instead of claiming the new workspace owns focus.
- **No start command.** `workspace.create` does not accept `startCommand`; that
  option is intentionally blocked pending the libghostty issue tracked by #889.
- **Structured outcome.** `outcome` is `completed` or `confirmation_required`.
  A live-window-less app fails `unsupported` (never a data-layer fallback), an
  unknown/non-UUID `repoID` fails `invalid_request`, and unknown providers fail
  `invalid_request`.
- **Operator mutation.** Requires `workspace.create`, distinct from
  `workspace.read` and `workspace.select`. A tile handle lacks it and fails
  `capability_denied`.

## Surface read

`POST /v1/surface/read` (operator scope, `surface.read`) returns bounded plain
text from any live terminal surface:

```json
{ "surfaceID": "…", "lines": 200 }
```

The success envelope carries the text plus the effective bounds:

```json
{
  "surfaceID": "…",
  "requestedLines": 10000,
  "lines": 500,
  "returnedLines": 200,
  "byteCount": 8192,
  "text": "plain terminal text\n",
  "system": { "capabilities": [ … ] }
}
```

- **Operator-scoped authority.** Any live terminal surface is readable by an
  operator handle. The grant rests on the read being read-only, operator scope
  being opt-in per launch, and every call landing in the audit log with the
  surface id it touched (`surfaceRead.surfaceID`) — never the text. Tile
  handles never carry `surface.read` and fail `capability_denied`; the
  creation-attribution registry serves audit lineage, not access control.
- **Ghostty text API.** The app reads GhosttyKit's plain terminal text through
  `ghostty_surface_read_text` over the whole screen/scrollback selection. No OCR
  or screenshot path is used.
- **Bounds.** `lines` must be greater than zero. Values over 500 are clamped to
  500, not rejected. The returned UTF-8 payload is capped at 256 KiB; if the line
  suffix still exceeds that, older lines are dropped first, and a single over-cap
  line is UTF-8-safely truncated from the front.
- **Content-free audit.** `automation-audit.jsonl` records the route, surface id,
  requested line count, returned line count, allow/deny outcome, and error code.
  It never records the terminal text.

## Workspace select

`POST /v1/workspace/select` (operator scope, `workspace.select`) selects a workspace
by driving the real selection gesture — the verbs-=-clicks exemplar (see
[Verb contract](#verb-contract-verbs--clicks)). The body names the target by a
`workspaceID` obtained from `workspace.read`:

```json
{ "workspaceID": "…" }
```

The success envelope reports the structured gesture outcome and what the selection
did:

```json
{ "workspaceID": "…", "outcome": "completed", "changed": true,
  "selectedWorkspaceID": "…", "attachedTerminal": true,
  "attachedSurfaceID": "…", "system": { "capabilities": [ … ] } }
```

- **Same path as a click.** The verb writes the selection binding whose setter runs
  the workspace-selection handler — terminal attach + focus request. So the sidebar
  highlights the workspace, its terminal attaches, and focus is requested, identical
  to a sidebar click. `attachedSurfaceID` is the session a following input would land
  in; `attachedTerminal` is `false` for an archived workspace (selection navigates to
  its repo overview instead of attaching a terminal, so it completes without one).
- **Structured outcome.** `outcome` is `completed` or `confirmation_required`;
  `workspace.select` only ever `completed`s today. A live-window-less app fails
  `unsupported` (never a data-layer fallback), and an unknown or non-UUID
  `workspaceID` fails `invalid_request`.
- **Operator mutation.** Requires `workspace.select`, distinct from the read-only
  `workspace.read`. A tile handle lacks it and fails `capability_denied`. The call is operator-tagged in
  `automation-audit.jsonl` like every operator route.

## Workspace archive

`POST /v1/workspace/archive` (operator scope, `workspace.archive`) archives a
workspace by driving the same sidebar archive action exposed from the workspace
row menu. The body names the target by a `workspaceID` obtained from
`workspace.read`, with an optional teardown opt-in:

```json
{ "workspaceID": "…", "teardownTerminals": false }
```

`teardownTerminals` defaults to false, preserving the original semantics: the
archive path retires the workspace's terminal sessions gracefully and a live
terminal fails the call with a typed error (below). With `true`, the app force-
tears the workspace's terminals down first — its tmux sessions are killed (in
tmux mode the client counts as a live process, so a plain close would raise the
headlessly-unanswerable Ghostty close confirmation; killing the session first is
what frees the close), the surfaces close, and the tile-tree rows retire —
before the archive gesture runs. This is the operator loop-closure verb: a loop
that opened a workspace can deterministically close it.

The success envelope reports the structured gesture outcome, the selection
state left behind by the real archive gesture, and — when teardown ran — a
report of what died:

```json
{
  "workspaceID": "…",
  "outcome": "completed",
  "changed": true,
  "archivedWorkspaceID": "…",
  "selectedWorkspaceID": "…",
  "teardown": {
    "retiredSurfaceIDs": [ "…" ],
    "killedTmuxSessions": [ "wm-…" ]
  },
  "system": { "capabilities": [ … ] }
}
```

After completion, `GET /v1/workspaces` reports the same workspace with
`isArchived: true` and status `archived`; the row leaves the active workspace
list exactly as it does after using the sidebar. If the archived workspace was
selected, the API does not invent a separate fallback — `selectedWorkspaceID`
is whatever the sidebar gesture left selected.

- **Same path as the UI.** The verb enters `SidebarWorkspaceController.archive`
  through the window-bound gesture layer, not `WorkspaceService` or SwiftData
  directly.
- **Structured outcome.** `outcome` is `completed` or
  `confirmation_required`. The archive action has no confirmation dialog today,
  but if the UI path gains one the route returns the same structured
  confirmation payload shape as `workspace.create`.
- **Failure mapping.** A live-window-less app fails `unsupported` (never a
  data-layer fallback), and an unknown or non-UUID `workspaceID` fails
  `invalid_request`. A live terminal without teardown fails typed instead of
  generic: the exit-timeout is `terminal_active` with `retryable: true` (the
  terminal may finish exiting; or re-issue with `teardownTerminals`), and a
  close blocked by the runtime's confirmation is `close_blocked_by_confirmation`
  with `retryable: false` — a blind retry would spin on a dialog no headless
  caller can answer. A teardown request that still cannot end a live process
  (e.g. the tmux kill failed) returns the same `close_blocked_by_confirmation`
  rather than retiring a terminal out from under the prompt.
- **Operator mutation.** Requires `workspace.archive`, distinct from
  `workspace.read`, `workspace.select`, and `workspace.create`. A tile handle
  lacks it and fails `capability_denied`. The call is operator-tagged in
  `automation-audit.jsonl` like every operator route, and a completed teardown
  additionally appends its own audit entry (path
  `/v1/workspace/archive#teardown`) carrying retired-surface and killed-session
  counts — counts only, never session names.

## Wait

`POST /v1/wait` (operator scope) lets a caller state a condition once and have
the app evaluate it against its own live state, answering with a typed outcome
instead of leaving the caller to sleep and re-check. Request:

```json
{
  "for": "surface_text_matches",
  "predicate": { "surfaceID": "…", "pattern": "BUILD (PASSED|FAILED)" },
  "timeoutMS": 10000
}
```

Response (success envelope):

```json
{
  "for": "surface_text_matches",
  "outcome": "satisfied",
  "waitedMS": 412,
  "requestedTimeoutMS": 10000,
  "effectiveTimeoutMS": 10000,
  "observed": { "surfaceLive": true, "textMatched": true, "windowAttached": true },
  "system": { "capabilities": [ … ] }
}
```

Condition vocabulary (predicate fields that do not apply to a condition are
rejected `invalid_request`, never silently ignored):

| `for` | Predicate | Satisfied when | Capability |
| --- | --- | --- | --- |
| `surface_attached` | optional `surfaceID` | The named surface is live in the tile tree; without a predicate, the active session resolves to an attached terminal (the same rule the ui-state topology uses). | `workspace.read` |
| `workspace_selected` | optional `workspaceID` | The named workspace is the current selection; without a predicate, any workspace is selected. Naming an archived workspace returns `not_applicable` immediately — selection of an archived workspace navigates to its repo overview and can never satisfy the wait. | `workspace.read` |
| `surface_text_matches` | `surfaceID` + regex `pattern` (≤ 1 KiB, must compile) | The bounded terminal text matches the pattern. The tick reads the last 500 lines capped at 32 KiB — an eighth of what `surface.read` returns, because this read repeats every tick and match cost scales with input length. | `surface.read` |
| `prompt_ready` | `surfaceID` | The surface's shell has reported a readiness signal (title or pwd — the same signals `first_prompt_ready` diagnostics count). Ready-once: the surface latches the first signal, so a TUI clearing the window title on exit cannot un-ready it. | `surface.read` |

Outcomes are the typed enum `satisfied` / `timed_out` / `not_applicable` —
never a bare boolean — and every outcome carries `observed`, the final
evaluation tick's reading, so a timeout is diagnosable from the response alone
(`observed` is sparse: an absent field means "not part of this condition",
never "zero"). `observed` never carries terminal text.

**Bounded by design.** A missing `timeoutMS` waits 5 s; every request is
clamped to the 20 s ceiling (`waitMaxTimeoutMS`), reported via
`requestedTimeoutMS` vs `effectiveTimeoutMS`. The ceiling interacts with the
listener's socket deadlines (#1241) deliberately: the read deadline is
cancelled once the request parses and the write deadline arms only after the
route returns, so the wait executes in the gap between them — the ceiling is
what bounds that gap, and it sits below `AutomationSocketClient`'s default
30 s receive deadline so a defaulted client never times out while the server
is still legitimately waiting. Longer waits are the caller's re-arm loop:
repeat the request on `timed_out` until your own budget expires; each round is
bounded and frees its listener connection slot between rounds. A pending wait
holds one of the listener's 8 connection slots for at most the ceiling.

**Cost of a tick.** Topology and selection conditions poll every 100 ms — a tick
is a couple of lookups. Content conditions poll every 250 ms, because a tick is
a terminal read plus a regex run. The regex is compiled once when the plan
resolves (the same compile that validates it) and runs on a detached task, not
the MainActor: the 1 KiB pattern cap bounds how much pattern the app parses, not
what a match costs — backtracking cost is a function of the *input*, and a
six-byte `(a+)+$` is already super-polynomial in it. What bounds the cost is the
32 KiB input cap plus an abort at the wait's own deadline. A pathological pattern
therefore spends its own wait's budget, reports `timed_out` with `textMatched`
absent (the match was abandoned, not decided), and leaves the UI responsive
throughout.

**Composition with the events endpoint (#1227).** A wait is the
single-condition, poll-based case of the planned events stream: the condition
vocabulary above doubles as the event vocabulary, and `observed` uses the same
field names the ui-state snapshot (#1259) reports (`attached`, selection
state), so the stream can emit the same observations a wait polls for without
a parallel representation.

## Focus

`GET /v1/focus` (operator scope, `window.read`) reports the app's live focus
state truthfully:

```json
{
  "appIsActive": false,
  "keyWindowID": "42",
  "firstResponderSurfaceID": "…",
  "focusPossible": false,
  "system": { "capabilities": [ … ] }
}
```

- `appIsActive` is `NSApp.isActive`; `keyWindowID` is the key window's AppKit
  window number (the identity `window.read` lists), absent when no window is
  key; `firstResponderSurfaceID` is the terminal surface owning the key
  window's first responder, absent when focus rests outside any terminal
  surface.
- **`focusPossible` is the unavailable-is-not-zero marker.** Under
  `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1` (shared desktop) or CI, the activation
  policy bars the app from taking focus, so `focusPossible` is `false` and the
  other fields can only be non-empty if the user focused the app themselves.
  Callers must branch on `focusPossible` before asserting on focus: a null
  `firstResponderSurfaceID` with `focusPossible: false` means "focus is
  structurally unobservable under this launch policy", not "focus failed" —
  the misreading that produced #1218's `surface_focused=0`.

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
| `busy` | The listener is at its concurrent-connection cap; retry shortly. |
| `internal_error` | Unexpected server-side failure. |
| `terminal_active` | A lifecycle verb refused because a live terminal did not exit before the timeout. Carries `retryable: true`. |
| `close_blocked_by_confirmation` | A terminal close was blocked by the runtime's close confirmation (live process). Carries `retryable: false`. |

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

`workspaces window list`, `workspaces window snapshot`, and `workspaces workspace
list` are the operator-scope commands. Unlike the tile-scoped commands, they read
the per-launch operator credential file (minted next to the socket by an opt-in
launch) rather than the injected terminal environment, so they work from any
same-user shell outside a WorkSpaces tile. Absent the credential they fail closed
with guidance.

```bash
workspaces window list
workspaces window list --json
workspaces window snapshot --out shot.png            # main window, or first if none is main
workspaces window snapshot --out shot.png --window 42 # a specific window.read id
workspaces workspace list                            # repos + workspaces, human-readable
workspaces workspace list --json                     # same, as the raw result envelope
workspaces workspace select <id>                     # drive the real selection gesture for <id>
workspaces workspace select <id> --json              # same, as the raw result envelope
workspaces workspace create <repo-id> feature-a      # create local workspace through the UI path
workspaces workspace create <repo-id> feature-a --json
workspaces workspace create <repo-id> feature-a --provider lume --guest-os macos
workspaces workspace archive <id>                   # archive through the sidebar action path
workspaces workspace archive <id> --teardown        # kill tmux + retire terminals first
workspaces workspace archive <id> --json
workspaces wait --for workspace_selected --workspace-id <id> --timeout-ms 10000 --json
workspaces wait --for surface_text_matches --surface-id <id> --pattern 'PASS|FAIL'
workspaces wait --for prompt_ready --surface-id <id>
workspaces focus --json                              # truthful focus report incl. focusPossible
```

`workspace list` reads the running app's repos and workspaces (`workspace.read`),
marking the currently-selected repo and workspace with a leading `*`. It is
distinct from `workspaces ws list`, which lists the CLI's own local-state
workspaces rather than what the app currently has.

`window snapshot` writes the PNG to `--out` and, with no `--window`, targets the
main window (falling back to the first listed) so the common "snapshot the app"
case needs no id lookup. It works with the app backgrounded — no activation, no
focus steal.

`workspace select <id>` drives the running app's real selection gesture for the
workspace with stable `<id>` (from `workspace list`): the app highlights it,
attaches its terminal, and requests focus, exactly as a sidebar click would. It
prints whether a terminal attached; `--json` emits the raw result envelope. Absent a
live window it fails `unsupported` — it never falls back to a data-layer write.

`workspace create <repo-id> <name>` drives the sidebar's real create helper for
the repo with stable `<repo-id>` (from `workspace list`). It defaults to the local
provider; `--provider` and `--guest-os` mirror the New Workspace sheet's provider
choice. On success, the app creates the workspace, selects it, and attaches its
terminal. If provider setup needs user confirmation, the command prints the
confirmation message; `--json` includes the structured confirmation payload.
Absent a live window it fails `unsupported` — it never falls back to a data-layer
write.

`wait` is the server-side typed wait: its exit code follows the outcome so
`set -e` scripts branch without parsing JSON — 0 `satisfied`, 2 `timed_out`,
3 `not_applicable`. `focus` prints the truthful focus report; never assert on
its other fields without branching on `focusPossible` first.

## Implementation Map

| Concern | File |
| --- | --- |
| Wire models and envelopes | `Sources/WorkspaceManagerCore/Services/Automation/AutomationAPI.swift` |
| Wait vocabulary, plan validation, engine | `Sources/WorkspaceManagerCore/Services/Automation/AutomationWait.swift` |
| Focus wire models | `Sources/WorkspaceManagerCore/Services/Automation/AutomationFocus.swift` |
| Focus enumeration (AppKit → state) | `Sources/WorkspaceManager/Views/MainWindow/AutomationFocusEnumerator.swift` |
| Gesture-verb layer (verbs = clicks) | `Sources/WorkspaceManagerCore/Services/Automation/AutomationGestureVerbs.swift` |
| Socket listener and lock | `Sources/WorkspaceManagerCore/Services/Automation/AutomationListener.swift` |
| HTTP route projection | `Sources/WorkspaceManagerCore/Services/Automation/AutomationHTTPRouter.swift` |
| Web-surface snapshot encoding (pure) | `Sources/WorkspaceManagerCore/Services/Automation/WebSurfaceSnapshotEncoder.swift` |
| Window snapshot encoding (pure) | `Sources/WorkspaceManagerCore/Services/Automation/WindowSnapshotEncoder.swift` |
| Operator credential store + provisioner | `Sources/WorkspaceManagerCore/Services/Automation/AutomationOperatorCredentialStore.swift` |
| Window enumeration (AppKit → descriptors) | `Sources/WorkspaceManager/Views/MainWindow/AutomationWindowEnumerator.swift` |
| Workspace inventory (SwiftData → descriptors) | `Sources/WorkspaceManager/Views/MainWindow/AutomationWorkspaceEnumerator.swift` |
| Window snapshot capture (`CGWindowList`, MainActor) | `Sources/WorkspaceManager/Views/MainWindow/WindowSnapshotService.swift` |
| Sidebar create gesture bridge | `Sources/WorkspaceManager/Views/MainWindow/AutomationWorkspaceCreateGestureBridge.swift` |
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

For a change touching a mutation verb, also verify it against the real app. The
API-driven smoke lanes go through the socket and assert the terminal attach
milestones that prove the verb entered the real UI path:

```bash
./scripts/api-select-smoke.sh --no-build   # asserts terminal_session_attached after the CLI select
./scripts/api-create-smoke.sh --no-build   # asserts create, selection, and new workspace attach
./scripts/api-desktop-ui-smoke.sh --no-build
uv run --script scripts/desktop-ui-smoke-parity.py --runs 3 --no-build
```

If docs or public examples changed, also run the docs checks listed in
[Docs Site Runbook](../README.md).

## V1 Non-Goals

V1 does not support browser mutation (navigating, clicking, filling, or
evaluating JavaScript in a web surface), opening web URLs, tab title or metadata
changes, writing into other tiles, resize/equalize, or *arbitrary* global
cross-workspace mutation. Those capabilities require separate product and safety
review before they can be added. Read-only global reads are the reviewed
operator-scope exceptions — window capture (`window.read` listing and
`window.snapshot` composited snapshots) and the repo/workspace inventory
(`workspace.read`) — gated behind the opt-in operator scope above, never granted to
tile handles. Operator mutations are limited to reviewed gesture verbs such as
`workspace.select` and `workspace.create`, which drive real UI paths under the
verbs-=-clicks contract, never data-layer writes. Reviewed exceptions widen the
read/write surface deliberately: caller-scoped input injection ships as the experimental,
double-gated `input.write` capability (see
[Automation Input Write Decision](../decisions/automation-input-write.md)), and
read-only web-surface reads ship as `browser.read` — both listing
(`GET /v1/web-surfaces`) and bounded snapshots
(`GET /v1/web-surfaces/{id}/snapshot`), granted to default handles under the
Automation API experiment. Browser *mutation* (navigating, clicking, filling, or
evaluating JavaScript in a web surface) remains out of scope pending the
JavaScript-evaluation trust-boundary review.
