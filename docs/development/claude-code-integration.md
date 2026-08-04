# Claude Code Integration

The Mac app embeds libghostty terminals where users run interactive coding agents,
primarily Claude Code. The integration gives the host enough live signal to drive
native UI: sidebar status, live status fields, macOS notifications, tab titles
from terminal state, and transcript viewing.

This document describes the shipped architecture. Deferred programmatic/headless
Claude work is tracked separately in `backlog/done/headless-claude-programmatic-runner.md`.

## Agent Update Intake

`AgentUpdateIntake` owns the host-side vocabulary for Agent update intake and
maps transports to named purposes. Legacy channel numbers are retained here only
to line up older specs and PRs; app code should prefer purpose names.

The command hook forwarder, status-line forwarder, and terminal attention
fallback feed `AgentSessionRegistry`. The command-status producer feeds
`LastCommandStatusRegistry`. The transcript reader is for the conversation log UI;
it is not a state recovery path.

| Legacy | Purpose | Registry input |
|---|---|---|
| 1 | Command hook forwarder | AgentSessionRegistry |
| 2 | Status-line forwarder | AgentSessionRegistry |
| 3 | Command-status producer | LastCommandStatusRegistry |
| 4 | libghostty OSC/BEL fallback | AgentSessionRegistry |
| 5 | Transcript JSONL reader | No |

```text
                 +------------------------------------+
                 | AgentSessionRegistry (@MainActor) |
                 | hostSessionID keyed state machine |
                 | one apply(events:) write surface  |
                 | 750ms OSC dedup                   |
                 +-----------+------------+-----------+
                             |            |
           +-----------------+            +----------------+
           |                                               |
           v                                               v
    Hook/status listener                              OSC router
    /event, /statusline,                              libghostty actions
    /command-markers
           |
           v
    SwiftUI observers
    SidebarRows, AgentsSettingsView, AgentNotificationPoster

    TranscriptReader -> ConversationLogView only
```

## Core Contract

- `Sources/WorkspaceManagerCore/Models/AgentSession.swift` defines `AgentKind`,
  `AgentRunState`, `AwaitingReason`, `AgentErrorCategory`, and
  `AgentSessionStatus`.
- `Sources/WorkspaceManagerCore/Models/ClaudeHookEvent.swift` decodes Claude Code
  hook JSON. Unknown hook events decode to `.unknown`.
- `Sources/WorkspaceManagerCore/Models/AgentEvent.swift` is the normalized event
  shape consumed by the registry.
- `Sources/WorkspaceManagerCore/Services/AgentUpdateIntake.swift` owns purpose
  names, HTTP route mapping, and the intake helpers used by callers.
- `Sources/WorkspaceManagerCore/Services/AgentEventTranslators.swift` remains
  the concrete Claude hook translator and OSC mapper. There is no adapter protocol
  until a second rich hook-speaking agent exists.
- `AgentHookListener` exposes `/event` for the command hook forwarder,
  `/statusline` for the status-line forwarder, `/command-markers` for the
  command-status producer, and `/healthz`.

The registry write surface is deliberately small:

```swift
registry.apply(events: [event], for: hostSessionID, origin: .hook)
```

Status-line fields and batched inputs use the same method. Callers do not update
individual registry fields directly.

## Host Session Routing

Routing is explicit. `TerminalSessionLaunchContext` owns the launch-context
policy for every `HostTerminalSession`: command mode, working directory,
host-session identity, and whether hook environment is safe to expose.

Directory-backed Terminal Sessions receive:

- `WORKSPACES_HOOKS_SOCKET`
- `WORKSPACES_HOST_SESSION_ID`
- `WORKSPACES_COMMAND_STATUS_ZSH` when the bundled zsh producer is available

This includes local repository/workspace sessions, Ghostty split sessions, and
tmux-per-session launches because the Agent runs in the same host namespace as
the app's Unix socket.

Custom-command Terminal Sessions, such as provider SSH commands, intentionally
do not receive the hook environment. WorkSpaces cannot assume the custom command's
child shell can reach the local Unix socket, and leaking a local socket path into
a remote session would be misleading. These sessions can still communicate with
app chrome through terminal signals that libghostty observes, including OSC
desktop notifications and BEL, because the surface resolver maps the
`GhosttySurfaceView` back to its `HostTerminalSession`.

The bundled shell forwarders include
`X-WorkSpaces-Host-Session-ID: <uuid>` on every POST. The listener accepts the
request immediately with `200 OK`, then drops the payload if the header is
missing, malformed, or no longer registered.

This replaces cwd/agent-session inference. `SessionStart` still records
`agentSessionID` in the registry state, but it is not a routing key. Duplicate
tabs and split panes on the same repository remain distinct because their host
session IDs are distinct from terminal spawn time.

## Sending Agent Status to the Needs You Dropdown

The top-right "Needs You" bubble and dropdown are driven by
`AgentSessionRegistry` via `WorkspaceStatusAggregator.attentionItems`. A terminal
tab appears in the dropdown when its registered host session reaches
`AgentRunState.awaitingInput` or `AgentRunState.errored`.

For Claude Code, use the installed hook and status-line forwarders. For another
agent running inside a WorkSpaces terminal, post Claude-compatible hook JSON to
the exported Unix socket and include the exported host-session header. Do not
invent a host session ID; unregistered IDs are dropped.

```bash
cat <<JSON | /usr/bin/curl \
  --silent \
  --show-error \
  --max-time 1 \
  --unix-socket "$WORKSPACES_HOOKS_SOCKET" \
  -H 'Content-Type: application/json' \
  -H "X-WorkSpaces-Host-Session-ID: $WORKSPACES_HOST_SESSION_ID" \
  --data-binary @- \
  'http://localhost/event'
{
  "hook_event_name": "Notification",
  "session_id": "custom-agent-$WORKSPACES_HOST_SESSION_ID",
  "cwd": "$PWD",
  "notification_type": "permission_prompt",
  "title": "Permission requested",
  "message": "Approve the command to continue"
}
JSON
```

Useful `hook_event_name` values:

| Desired UI state | Event payload |
|---|---|
| Permission row in the dropdown | `Notification` with `notification_type: "permission_prompt"` or `PermissionRequest` |
| Prompt/input row in the dropdown | `Notification` with `notification_type: "idle_prompt"` |
| Generic attention row | `Notification` with any other non-empty `notification_type` |
| Error row | `StopFailure` or `PostToolUseFailure` with an `error` string |
| Clear attention after success | `Stop` |
| Active/running status dot | `UserPromptSubmit`, then `PreToolUse` / `PostToolUse` events |

Status-line posts enrich the selected tab with model, context, rate-limit, and
cost fields, but they do not create or clear a Needs You row because they never
change `AgentRunState`:

```bash
cat <<JSON | /usr/bin/curl \
  --silent \
  --show-error \
  --max-time 1 \
  --unix-socket "$WORKSPACES_HOOKS_SOCKET" \
  -H 'Content-Type: application/json' \
  -H "X-WorkSpaces-Host-Session-ID: $WORKSPACES_HOST_SESSION_ID" \
  --data-binary @- \
  'http://localhost/statusline'
{
  "session_id": "custom-agent-$WORKSPACES_HOST_SESSION_ID",
  "cwd": "$PWD",
  "model": { "display_name": "Custom Agent" },
  "context_window": { "used_percentage": 42 },
  "cost": { "total_cost_usd": 0.13 }
}
JSON
```

## Command Hook Forwarder

Script: `Sources/WorkspaceManager/Resources/HookForwarders/event-forwarder.sh`.

Claude Code runs it as a `type: "command"` hook. The script reads hook JSON from
stdin and posts it unchanged to the stable Unix socket:

```text
POST /event
Content-Type: application/json
X-WorkSpaces-Host-Session-ID: <uuid>
```

The listener routes `/event` through `AgentUpdateIntake`, which decodes with the
concrete Claude hook translator and applies the resulting `AgentEvent` to the
registry with origin `.hook`.

The app extracts `event-forwarder.sh` to a stable, space-free directory —
`~/.local/share/workspaces/hook-forwarders/` (honoring `XDG_DATA_HOME`) — and
writes a tilde-relative, unquoted command into `settings.json`. The path is
identical on every machine, so the committed dotclaude config matches the runtime
config and `~/.claude` stops going dirty. See § "Settings Installer" for why the
command shape matters and `docs/decisions/hook-forwarder-command-shape.md` for the
rule.

The old `type: "http"` plus `http+unix://...` transport is not used. Real Claude
Code does not speak that URL scheme. The installer still scrubs only the old
WorkSpaces-owned `http+unix://.../hooks-<pid>.sock/event` handlers so opted-in
users self-heal without deleting user-owned Unix-socket hooks. It also replaces
any prior machine-specific event-forwarder command (an `Application Support` path
or a `.build` bundle path, quoted or unquoted, ending in
`HookForwarders/event-forwarder.sh`) with the generic tilde command.

## Status-Line Forwarder

Script: `Sources/WorkspaceManager/Resources/HookForwarders/statusline.sh`,
extracted to the same `~/.local/share/workspaces/hook-forwarders/` directory as
the command hook forwarder and written to `statusLine.command` as the same
tilde-relative, unquoted shape. The installer overwrites any prior status-line
command, so a stale bundle or `.build` path converges to the generic command on
next launch.

Claude Code runs it as `statusLine.command`, and the same script serves two
worlds selected by whether a live host socket is present:

- **Inside the WorkSpaces app** (`WORKSPACES_HOOKS_SOCKET` names a live socket):
  post status JSON to `/statusline` and print a single space so Claude's own
  status row stays visually empty — the host owns the footer. `StatusLinePayload`
  tolerates snake_case/camelCase keys and common ISO date variants; the listener
  maps the payload to `.statusFields(...)` through the same registry write
  surface.
- **Everywhere else** (plain terminal, another app — no host to render the
  footer): the script renders a normal status line itself. It delegates to the
  command named by `WORKSPACES_STATUSLINE_FALLBACK` (fed the same JSON on stdin),
  and if that is unset or unusable, prints a built-in pure-bash
  `model · branch · dir` line. This is why installing the forwarder no longer
  blanks the status line outside the app; a user who kept their own renderer
  points `WORKSPACES_STATUSLINE_FALLBACK` at it.

Status-line ticks never change `AgentRunState`; they only update display fields
such as model, cost, context used, and five-hour limit state.

Status-line ticks never change `AgentRunState`; they only update display fields
such as model, cost, context used, and five-hour limit state.

## Command-Status Producer

Script: `Sources/WorkspaceManager/Resources/HookForwarders/command-status.zsh`.

Local zsh sessions can opt in by sourcing the bundled path exported in the
terminal environment:

```zsh
source "$WORKSPACES_COMMAND_STATUS_ZSH"
```

The sourceable hook uses `preexec` to POST `OSC 133 ; B` to
`/command-markers`, then uses `precmd` to POST `OSC 133 ; D ; <exit>` after the
command returns. Payloads are raw OSC bytes with
`X-WorkSpaces-Host-Session-ID: <uuid>`, so the listener can parse them with
`CommandMarkerParser` and update `LastCommandStatusRegistry` for the matching
host terminal only.

The app does not mutate shell profiles automatically. Missing socket/session
environment, missing `curl`, stopped host listeners, and malformed payloads
drop quietly with diagnostics.

## Terminal Attention Fallback

`GhosttyRuntimeActionBridge` recognizes:

- `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`
- `GHOSTTY_ACTION_RING_BELL`

`AgentOSCRouter` resolves the `GhosttySurfaceView` back to its host session and
uses `AgentUpdateIntake` to create an `AgentEvent`. Claude Code OSC bodies get
small permission/idle heuristics; other agent kinds map to a generic custom
awaiting-input event.

Dedup is in the registry. If an OSC event arrives within 750ms of a hook event
that produced the same effective run state, the OSC event is suppressed. If hook
events stop for 60 seconds, `hookActive` clears and OSC can take over.

Notification channel selection is concrete installer behavior: `~/.claude.json`
is patched to `preferredNotifChannel: "iterm2"` because OSC 9 is the reliable
path libghostty surfaces today.

## Transcript JSONL Reader

`Sources/WorkspaceManagerCore/Services/TranscriptReader.swift` reads Claude Code
transcripts for `ConversationLogView`.

Supported consumption shapes:

- `tail()` for bounded replay into the conversation log.
- `live()` for following an active transcript.

Known transcript record types get richer rendering. Unknown records decode to an
opaque JSON case and render collapsed. Transcript data is not used to reconstruct
registry state on app launch. If crash recovery becomes necessary, prefer a
host-owned durable `AgentEvent` log; see `backlog/done/agent-event-log-recovery.md`.

## Settings Installer

`ClaudeSettingsInstaller` is a concrete patcher, not a contributor framework. It
owns the complete WorkSpaces patch:

- command hooks using `event-forwarder.sh`
- `statusLine` using `statusline.sh`
- `preferredNotifChannel: "iterm2"`
- migration scrub for old WorkSpaces `http+unix://...hooks-<pid>.sock/event`
- migration removal for old WorkSpaces `title-emit.sh` hooks
- migration replacement of machine-specific event-forwarder/status-line paths with
  the generic tilde command

Both commands the app writes to `~/.claude/settings.json` are **machine-agnostic**:
the extracted script lives in a stable, space-free dir
(`~/.local/share/workspaces/hook-forwarders/`) and the command is emitted as a
tilde-relative, **unquoted** path
(`~/.local/share/workspaces/hook-forwarders/event-forwarder.sh`). Tilde expansion
is not subject to field splitting, so the path expands cleanly even if the home
directory contains a space — which removes the quoting that an absolute
`Application Support` path needed. `shellEscapedCommand` keeps a clean tilde path
verbatim (it is in the safe-scalar set) and still quotes anything carrying a space
or other unsafe scalar. Because the committed and runtime forms are byte-identical
on every machine, `~/.claude` no longer goes dirty from per-launch rewrites and the
dotclaude auto-deploy stops silently skipping. The rule is captured in
`docs/decisions/hook-forwarder-command-shape.md`.

The public UI-facing protocol remains:

- `renderPreview()`
- `install()`
- `isInstalled()`
- `userSettingsURL()`
- `mostRecentBackupPath()`
- `userSettingsModificationDate()`

`install()` compares the merged JSON semantically with the file on disk. If
nothing changes, it skips both the write and backup creation, preserving the
user's formatting. When it does write, backups go under
`~/Library/Application Support/com.cloudcompute.workspaces/ClaudeSettingsBackups`
and rotation keeps at most five `*.workspaces-backup-*` files per settings file.

`ClaudeIntegrationLifecycle.start(registry:)` publishes the installer, starts the
stable socket listener, and repairs settings only when the user has opted in and
`isInstalled()` is false.

## Socket Ownership

The listener uses a stable socket:

```text
~/Library/Application Support/<bundle-id>/hooks.sock
```

A sibling `hooks.lock` file is held with a non-blocking exclusive lock while the
listener owns the socket. If another WorkSpaces instance owns the lock, the new
listener starts dormant and logs that ownership decision. A dormant listener does
not remove the owner socket on shutdown.

This avoids pid-scoped socket churn, per-launch settings rewrites, and stale
paths synced through `~/.claude/`. The forwarder **commands** the installer writes
get the same machine-agnostic treatment — a stable, space-free extraction dir plus
a tilde-relative unquoted path — so the same drift sources cannot reappear through
`statusLine.command` or the hook command strings. See § "Settings Installer".

## Production Wiring

`WorkspaceManagerApp` starts `ClaudeIntegrationLifecycle` outside CI. The main
window attaches its `TileTreeStore` to the app-scoped
`AgentSessionRegistry`. The store mirrors both primary tabs and split sessions
into the registry and wires `AgentOSCRouter` with a surface-to-session resolver.

`SurfaceStore` injects the socket path and host session ID into every directory-backed
persistent Ghostty surface it creates.

## Operational Notes

- `PTYForegroundProbe` is still a stub returning `.claudeCode`. opencode/aider
  support is OSC-only until libghostty exposes enough process identity to detect
  the foreground agent.
- Malformed Claude settings are overwritten with a backup. The installer treats a
  parse failure as an empty object so the user gets a working file plus recovery
  bytes.
- The Settings toggle still does not auto-uninstall on flip-off. The UI provides
  manual backup restore guidance.
- Concurrent dev and installed apps can still compete for the `workspaces://`
  URL handler. The hook socket no longer has that ambiguity because it is
  lock-owned.

## Verification Runbook

After non-trivial changes:

1. `./scripts/build-ghosttykit.sh`
2. `swift build`
3. `swift test`
4. `swift-format lint --strict --recursive Sources/ Tests/`
5. `./scripts/claude-integration-smoke.sh --non-interactive --no-build --trust-mise --output-dir output/claude-integration-smoke/<timestamp>`
6. For a real routed signal against a visible embedded terminal:
   `./scripts/claude-integration-smoke.sh --use-existing --deterministic-signal --host-session-id <uuid> --pr <number>`

Targeted integration suites:

- `AgentSessionRegistryTests`
- `AgentHookListenerTests`
- `ClaudeSettingsInstallerTests`
- `ClaudeSettingsInstallerBackupRotationTests`
- `ClaudeSettingsInstallingProtocolTests`
- `OSCDedupIntegrationTests`
- `GhosttyRuntimeActionBridgeTests`
- `TranscriptReaderTests`
- `StatusLinePayloadTests`

Perf suites remain opt-in with `WORKSPACES_PERF_RUN=1`.

## Deferred Ideas

- Programmatic/headless Claude execution:
  `backlog/done/headless-claude-programmatic-runner.md`
- Host-owned durable event-log recovery:
  `backlog/done/agent-event-log-recovery.md`

## Historical PR Sequence

1. **#443**: contract layer, hook listener, registry, settings UI.
2. **#451**: OSC fallback and settings backup rotation.
3. **#452**: status-line forwarder and live status UI.
4. **#453**: removed from shipped architecture; headless runner was deferred.
5. **#454**: transcript reader kept for conversation viewing; cold-start
   registry recovery was deferred.
6. **#466**: command-hook forwarder replacing broken `http+unix://` hook URLs.
