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

`workspaces automation health` checks only that a local listener is reachable:

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
arbitrary tile by ID.

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
from a live WorkSpaces terminal tile.

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
- write into the caller's own PTY (experimental, double-gated — see
  [Automation Input Write Decision](./decisions/automation-input-write.md))

V1 does not support browser mutation, opening URLs, tab metadata changes,
writing into other tiles, resize/equalize, or global control across
workspaces.
