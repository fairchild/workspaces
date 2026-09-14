# WorkSpaces Automation API Guide

The WorkSpaces Automation API lets a trusted process running inside a
WorkSpaces terminal tile ask the app shell about its current context and make a
small set of tile changes. It is local-only, same-user, and experimental.

Use this guide when you are writing a script, shell alias, or coding-agent tool
that runs from a WorkSpaces terminal. For the wire contract, see
[Automation API Reference](./development/automation-api.md). For the design
rationale and V1 boundaries, see
[Automation API V1 Decision](./decisions/automation-api-v1.md).

## Enable It

The API is disabled by default.

1. Open WorkSpaces Settings.
2. Enable Experimental Features.
3. Enable Automation API.
4. Restart WorkSpaces.
5. Open a new terminal tile.

For development launches, you can force the feature on for that process:

```bash
WORKSPACES_AUTOMATION_API=1 ./scripts/launch-dev.sh --no-build
```

Trusted operator launches can also enable operator-scope workspace verbs:

```bash
WORKSPACES_AUTOMATION_API=1 WORKSPACES_AUTOMATION_OPERATOR=1 ./scripts/launch-dev.sh --no-build --no-activate
```

Terminal processes receive automation environment only when their surface is
created. If you turn the experiment on or off, restart WorkSpaces and create a
fresh terminal tile before testing.

## Check Your Terminal

Inside a WorkSpaces terminal tile:

```bash
echo "$WORKSPACES_AUTOMATION_SOCKET"
echo "$WORKSPACES_AUTOMATION_HANDLE"
```

Both values should be present. The handle is an opaque capability. Do not copy
it into another terminal, save it in dotfiles, or treat it as a tile ID.

`workspaces automation health` checks only that a local listener is reachable.
When the running app supports health metadata, plain output also includes the
listener pid, listener start time, protocol version, and active automation
experiments; `--json` includes the same values under `server`.

```bash
workspaces automation health
workspaces automation health --json
```

Scoped commands also require `WORKSPACES_AUTOMATION_HANDLE`. They are expected
to fail outside a WorkSpaces terminal tile.

## See The Current Context

Use context when a script needs to know which terminal tile it is running in:

```bash
workspaces automation context --json
```

The result includes the current surface, window/app scope, primary host session,
and granted capabilities. It does not echo the opaque handle.

Example uses:

```bash
surface_id=$(workspaces automation context --json | jq -r '.surface.surfaceID')
cwd=$(workspaces automation context --json | jq -r '.surface.cwd')
```

## List Visible Surfaces

Use the surface list to inspect terminal surfaces in the caller's app/window
scope:

```bash
workspaces surface list --json
```

Each entry reports a stable surface ID, surface kind, title, working directory,
visibility, active state, and whether it is the caller.

## Create A Workspace (Operator Scope)

`workspace.create` drives the app's real sidebar create helper. It requires an
operator handle, not a tile handle.

The default body preserves the original behavior exactly: branch from the base
repo clone's local `HEAD`, create the workspace, select it, and attach/activate
its terminal.

```json
{ "repoID": "...", "name": "feature-a", "providerID": "local", "guestOS": null }
```

Two optional fields are available:

- `select`: boolean, default `true`. Set `false` to create the workspace without
  changing the owner's current sidebar selection or focus.
- `fromRef`: string, omitted by default. Set values such as `"origin/main"` to
  fetch before creation and branch the workspace from that fetched ref instead
  of stale local `HEAD`.

```json
{
  "repoID": "...",
  "name": "feature-a",
  "providerID": "local",
  "select": false,
  "fromRef": "origin/main"
}
```

`fromRef` must be a plausible git ref name; empty, whitespace-padded,
option-like, or shell-metacharacter-shaped values fail `invalid_request`. The
route does not support `startCommand`; that option is intentionally blocked
pending #889, which tracks restored surfaces coming up unconfigured. #889 was
filed as a libghostty defect; that attribution has not held up and the loss
point is unknown (#1520).

## Focus A Neighboring Tile

Focus commands are relative to the caller tile:

```bash
workspaces tile focus --left
workspaces tile focus --right
workspaces tile focus --up
workspaces tile focus --down
workspaces tile focus --next
workspaces tile focus --previous
```

If there is no neighbor in that direction, the request succeeds without changing
focus and reports `reason: "no_neighbor"` at the API level.

## Split The Current Tile

Split commands are also relative to the caller tile:

```bash
workspaces tile split --right
workspaces tile split --down
workspaces tile split --left
workspaces tile split --up
```

V1 supports splitting from a primary terminal tile. Each successful split creates
a new terminal surface in the caller's tab and focuses it after the app's normal
split-focus delay. Calling split from a secondary split tile returns
`unsupported` in V1.

## Close The Current Tile

Close routes through the same close-confirmation path as the app:

```bash
workspaces tile close
```

The request is scoped to the caller. There is no V1 command for closing an
arbitrary tile by ID. The response reports `outcome: "requested"` with
`changed: false`: close is fire-and-forget and the app may still prompt, so
the API reports the request without claiming the tile closed.

## Write Into The Current Tile (Experimental)

Input write is double-gated: enable both the Automation API experiment and the
separate Automation Input Write experiment, then restart WorkSpaces and open a
fresh terminal tile. For development launches:

```bash
WORKSPACES_AUTOMATION_API=1 WORKSPACES_AUTOMATION_INPUT_WRITE=1 ./scripts/launch-dev.sh --no-build
```

The command writes text into the caller's own PTY — the tile the script is
running in. There is no way to write into another tile.

```bash
workspaces input write 'echo hello-from-automation'            # type without executing
workspaces input write 'echo hello-from-automation' --submit   # type and press Enter
```

The text is delivered as a paste; `--submit` then presses Return as a
synthetic key event (a `\r` inside the paste would be bracketed-paste-wrapped
and inserted literally instead of executing). Text is limited to 32 KiB UTF-8
per request. Requests from handles created while
the experiment was off, or after it is turned off, fail with
`capability_denied` — restart WorkSpaces and open a fresh tile after toggling
it. The audit log records the route and outcome, never the written text.

## Read Terminal Text (Operator Scope)

`surface/read` is operator-scoped, not tile-scoped. An operator handle reads
bounded plain text from any terminal surface held by the Automation API's tile
tree store, which belongs to the WorkSpaces window that configured the
Automation API most recently. The read is not limited to the terminals the
handle created through `workspace.create`: terminals a person opened are
readable too, so the operator credential carries read access to their
scrollback.

The route body names a live surface ID, such as the `attachedSurfaceID` returned
by `workspace.create` or `workspace.select`:

```json
{ "surfaceID": "…", "lines": 200 }
```

Rules:

- A surface is readable while the tile tree store holds it, including after its
  window has closed: window teardown does not clear the store.
- A surface the store does not hold, such as one in a window that configured the
  Automation API earlier, answers `stale_handle`, as does a surface not yet ready
  to read. With no store configured yet, the request fails `unsupported`.
- Tile handles fail `capability_denied`.
- Creation attribution is recorded at `workspace.create` and not consulted on
  read.
- Returned text is plain terminal text, with no ANSI styling.
- `lines` is clamped to 500; the payload is capped at 256 KiB UTF-8.
- The audit log records each call with the operator flag, the surface ID it
  read, requested lines, returned lines, and allow/deny outcome, never the
  terminal text.

## Operator Workspace Commands

Operator commands use the per-launch operator credential minted by an app
started with Automation Operator Scope enabled. They work from any same-user
shell, not just inside a WorkSpaces terminal tile:

```bash
WORKSPACES_AUTOMATION_API=1 WORKSPACES_AUTOMATION_OPERATOR=1 ./scripts/launch-dev.sh --no-build
workspaces workspace list
workspaces workspace create <repo-id> feature-a
workspaces workspace select <workspace-id>
workspaces workspace archive <workspace-id>
workspaces workspace archive <workspace-id> --teardown
```

`workspace archive` drives the same sidebar archive action as the row menu. On
success, the workspace leaves the active list and `workspace list --json`
reports it with `isArchived: true`. A live terminal fails the plain call with a
typed error — `terminal_active (retryable)` on the exit-timeout, or
`close_blocked_by_confirmation (not retryable)` when a running process would
raise the close confirmation. `--teardown` closes the loop instead: the app
kills the workspace's tmux sessions, retires its terminal tiles, then archives
in one call.

## Shell Alias Ideas

These examples are intentionally small. They stay inside the V1 scope and do
not inject input into terminals.

```bash
alias ws-right='workspaces tile focus --right'
alias ws-left='workspaces tile focus --left'
alias ws-split='workspaces tile split --right'
alias ws-context='workspaces automation context --json'
```

A script can use the current directory from WorkSpaces context:

```bash
#!/usr/bin/env bash
set -euo pipefail

context=$(workspaces automation context --json)
title=$(jq -r '.surface.title' <<<"$context")
cwd=$(jq -r '.surface.cwd // ""' <<<"$context")

printf 'WorkSpaces surface: %s\n' "$title"
printf 'Working directory: %s\n' "$cwd"
```

## Troubleshooting

`WORKSPACES_AUTOMATION_HANDLE is missing`

Run the command from a WorkSpaces terminal tile created after the experiment was
enabled. Repo overviews, web sources, ordinary Terminal.app windows, and remote
custom-command sessions do not provide the scoped handle.

`Could not connect to WorkSpaces Automation API`

The app is not running, the experiment is disabled, or the terminal inherited an
old socket path. Restart WorkSpaces and create a new terminal tile.

`automation request failed: stale_handle`

The terminal tile that owned the handle was closed or replaced. Run the command
from a live WorkSpaces terminal tile. From `surface/read`, it can also mean the
Automation API's tile tree store does not hold the requested surface, or the
surface is not yet ready to read.

`automation request failed: unsupported`

The request is outside V1. Common examples are splitting from a secondary split
tile or asking for capabilities such as browser mutation, resize/equalize, or
global cross-workspace control.

## V1 Boundaries

V1 is intentionally narrow:

- read current context
- list in-scope terminal surfaces
- focus a neighboring tile
- split from a primary tile
- close the caller tile through normal app behavior
- operator workspace list/create/select/archive verbs when Automation Operator
  Scope is enabled
- write into the caller's own PTY (experimental, double-gated — see
  [Automation Input Write Decision](./decisions/automation-input-write.md))
- read bounded plain text from any terminal surface the Automation API's tile
  tree store holds (operator scope)

V1 does not support browser mutation, opening URLs, tab metadata changes,
writing into other tiles, resize/equalize, or global control across
workspaces.
