# Claude Code Integration

The Mac app embeds libghostty terminals where users run interactive coding agents,
primarily Claude Code. The integration gives the host enough live signal to drive
native UI: sidebar status, live status fields, macOS notifications, tab titles
from terminal state, and transcript viewing.

This document describes the shipped architecture. Deferred programmatic/headless
Claude work is tracked separately in `backlog/headless-claude-programmatic-runner.md`.

## Shipped Channels

Only the first three channels feed `AgentSessionRegistry`. Channel 4 is a
transcript reader for the conversation log UI; it is not a state recovery path.

| Channel | Role | Registry input |
|---|---|---|
| 1. Command hook forwarder | Primary event stream: tool start/end, awaiting input, complete, errored | Yes |
| 2. Status-line forwarder | Model, cost, context fill, rate-limit headroom | Yes |
| 3. libghostty OSC/BEL | Fallback attention signal for unhooked or degraded sessions | Yes |
| 4. Transcript JSONL | Conversation replay/audit view | No |

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
    /event, /statusline                               libghostty actions
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
- `Sources/WorkspaceManagerCore/Services/AgentEventTranslators.swift` contains
  the concrete Claude hook translator and OSC mapper. There is no adapter
  protocol until a second rich hook-speaking agent exists.
- `AgentHookListener` exposes `/event`, `/statusline`, and `/healthz`.

The registry write surface is deliberately small:

```swift
registry.apply(events: [event], for: hostSessionID, origin: .hook)
```

Status-line fields and batched inputs use the same method. Callers do not update
individual registry fields directly.

## Host Session Routing

Routing is explicit. Every persistent host terminal created from a
`HostTerminalSession` receives:

- `WORKSPACES_HOOKS_SOCKET`
- `WORKSPACES_HOST_SESSION_ID`

The bundled shell forwarders include
`X-WorkSpaces-Host-Session-ID: <uuid>` on every POST. The listener accepts the
request immediately with `200 OK`, then drops the payload if the header is
missing, malformed, or no longer registered.

This replaces cwd/agent-session inference. `SessionStart` still records
`agentSessionID` in the registry state, but it is not a routing key. Duplicate
tabs and split panes on the same repository remain distinct because their host
session IDs are distinct from terminal spawn time.

## Channel 1: Command Hook Forwarder

Script: `Sources/WorkspaceManager/Resources/HookForwarders/event-forwarder.sh`.

Claude Code runs it as a `type: "command"` hook. The script reads hook JSON from
stdin and posts it unchanged to the stable Unix socket:

```text
POST /event
Content-Type: application/json
X-WorkSpaces-Host-Session-ID: <uuid>
```

The listener decodes with `ClaudeHookTranslator.decodeAgentEvent(from:)` and
applies the resulting `AgentEvent` to the registry with origin `.hook`.

The old `type: "http"` plus `http+unix://...` transport is not used. Real Claude
Code does not speak that URL scheme. The installer still scrubs only the old
WorkSpaces-owned `http+unix://.../hooks-<pid>.sock/event` handlers so opted-in
users self-heal without deleting user-owned Unix-socket hooks.

## Channel 2: Status-Line Forwarder

Script: `Sources/WorkspaceManager/Resources/HookForwarders/statusline.sh`.

Claude Code runs it as `statusLine.command`. The script posts status JSON to
`/statusline` and prints a single space so Claude's own status row stays visually
empty. `StatusLinePayload` tolerates snake_case/camelCase keys and common ISO
date variants. The listener maps the payload to `.statusFields(...)` and applies
it through the same registry write surface.

Status-line ticks never change `AgentRunState`; they only update display fields
such as model, cost, context used, and five-hour limit state.

## Channel 3: libghostty OSC/BEL

`GhosttyRuntimeActionBridge` recognizes:

- `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`
- `GHOSTTY_ACTION_RING_BELL`

`AgentOSCRouter` resolves the `GhosttySurfaceView` back to its host session and
uses `AgentOSCEventMapper` to create an `AgentEvent`. Claude Code OSC bodies get
small permission/idle heuristics; other agent kinds map to a generic custom
awaiting-input event.

Dedup is in the registry. If an OSC event arrives within 750ms of a hook event
that produced the same effective run state, the OSC event is suppressed. If hook
events stop for 60 seconds, `hookActive` clears and OSC can take over.

Notification channel selection is concrete installer behavior: `~/.claude.json`
is patched to `preferredNotifChannel: "iterm2"` because OSC 9 is the reliable
path libghostty surfaces today.

## Channel 4: Transcript JSONL

`Sources/WorkspaceManagerCore/Services/TranscriptReader.swift` reads Claude Code
transcripts for `ConversationLogView`.

Supported consumption shapes:

- `tail()` for bounded replay into the conversation log.
- `live()` for following an active transcript.

Known transcript record types get richer rendering. Unknown records decode to an
opaque JSON case and render collapsed. Transcript data is not used to reconstruct
registry state on app launch. If crash recovery becomes necessary, prefer a
host-owned durable `AgentEvent` log; see `backlog/agent-event-log-recovery.md`.

## Settings Installer

`ClaudeSettingsInstaller` is a concrete patcher, not a contributor framework. It
owns the complete WorkSpaces patch:

- command hooks using `event-forwarder.sh`
- `statusLine` using `statusline.sh`
- `preferredNotifChannel: "iterm2"`
- migration scrub for old WorkSpaces `http+unix://...hooks-<pid>.sock/event`
- migration removal for old WorkSpaces `title-emit.sh` hooks

The public UI-facing protocol remains:

- `renderPreview()`
- `install()`
- `isInstalled()`
- `userSettingsURL()`
- `mostRecentBackupPath()`
- `userSettingsModificationDate()`

`install()` compares the merged JSON bytes with the file on disk. If nothing
changes, it skips both the write and backup creation. When it does write, it
keeps at most five `*.workspaces-backup-*` files per settings file.

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
paths synced through `~/.claude/`.

## Production Wiring

`WorkspaceManagerApp` starts `ClaudeIntegrationLifecycle` outside CI. The main
window attaches its `HostTerminalStateStore` to the app-scoped
`AgentSessionRegistry`. The store mirrors both primary tabs and split sessions
into the registry and wires `AgentOSCRouter` with a surface-to-session resolver.

`HostTerminalSurfaceStore` injects the socket path and host session ID into every
directory-backed persistent Ghostty surface it creates.

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
- The GitHub Actions `@claude` mention executor is outside this Mac-app
  integration. Its contract lives in `docs/development/agent-team.md` and
  `.github/workflows/agent-executor.yml`: a green approved-mention run must
  leave a visible issue or PR response, even if only a brief no-findings note.

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
  `backlog/headless-claude-programmatic-runner.md`
- Host-owned durable event-log recovery:
  `backlog/agent-event-log-recovery.md`

## Historical PR Sequence

1. **#443**: contract layer, hook listener, registry, settings UI.
2. **#451**: OSC fallback and settings backup rotation.
3. **#452**: status-line forwarder and live status UI.
4. **#453**: removed from shipped architecture; headless runner was deferred.
5. **#454**: transcript reader kept for conversation viewing; cold-start
   registry recovery was deferred.
6. **#466**: command-hook forwarder replacing broken `http+unix://` hook URLs.
