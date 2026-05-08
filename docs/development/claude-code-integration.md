# Claude Code integration

The Mac app embeds libghostty terminals where users run interactive coding agents — primarily Claude Code, but also opencode, aider, and friends. The integration layered over those terminals lets the host see what the agent is doing in real time so it can drive native chrome (sidebar status, tab titles, macOS notifications) and run agents non-interactively for setup tasks. This document is the operational reference; for design rationale see the spec at `.context/attachments/pasted_text_2026-05-03_22-18-10.txt`.

## Five channels

Each channel has a defined role. They complement each other; collapsing them loses signal. The five together feed a single registry which the UI observes.

| Channel | Role | Shipped in |
|---|---|---|
| 1. HTTP hooks (Unix socket) | Primary event stream — tool start/end, awaiting input, complete, errored | PR #443 |
| 2. Status-line forwarder | Continuous state — context fill, cost, rate-limit headroom, model | PR #452 |
| 3. libghostty OSC parser | Fallback for unhooked sessions; watchdog for hook delivery failures | PR #451 |
| 4. Transcript JSONL | Replay / audit log; cold-start state recovery after a crash | PR #454 |
| 5. `claude -p` headless | Setup scripts, scheduled tasks, sidebar quick actions | PR #453 |

### Architecture

```
                 ┌─────────────────────────────────────────┐
                 │  AgentSessionRegistry (@MainActor)      │
                 │  hostSessionID ⇄ agentSessionID         │
                 │  state machine + 750ms OSC dedup        │
                 │  ingestBatch for high-rate replay       │
                 └──────────┬──────────────────────────────┘
                            │
   ┌────────────┬───────────┼─────────────┬──────────────┐
   ▼            ▼           ▼             ▼              ▼
 Hooks      StatusLine    OSC parser   Transcript     headless
 (NWListener (POST       (Ghostty       (TranscriptReader
  Unix       /statusline) actions:      tail+live;     HeadlessClaudeRunner
  socket,     forwarder    DESKTOP_     cold-start     stream-json
  /event)     script)      NOTIFICATION recovery       NDJSON parser)
                           BELL,        gated 500 ev/s)
                           SET_TITLE)
```

The registry is the single source of truth. UI surfaces (`SidebarRows`, `AgentsSettingsView`, `ConversationLogView`, the macOS notification poster) observe `@Published var statuses: [UUID: AgentSessionStatus]`. Adapters per agent kind (`ClaudeCodeAdapter`, `GenericOSCAdapter`) translate channel-specific events into adapter-agnostic `AgentEvent` values; the UI doesn't branch on `AgentKind` — it observes `AgentRunState`.

## Locked contract

These types are the API four parallel teams built against. Additive changes only — never rename, never repurpose, never remove a case.

- `Sources/WorkspaceManagerCore/Models/AgentSession.swift` — `AgentKind`, `AgentRunState`, `AwaitingReason`, `AgentErrorCategory`, `AgentSessionStatus`.
- `Sources/WorkspaceManagerCore/Models/ClaudeHookEvent.swift` — full hook event enum + `ClaudeHookDecoder` (forward-compatible: unknown events decode to `.unknown`).
- `Sources/WorkspaceManagerCore/Models/AgentEvent.swift` — adapter-agnostic event the registry consumes.
- `Sources/WorkspaceManagerCore/Services/AgentAdapters/AgentAdapter.swift` — protocol surface, `ClaudeCodeAdapter`, `GenericOSCAdapter`, `AgentAdapterRegistry`.
- `ClaudeSettingsInstaller` *merge algorithm* (the contributor API is open; the algorithm is closed).
- `AgentHookListener` route table: `/event`, `/statusline`, `/healthz`.
- Socket path: `~/Library/Application Support/<bundle-id>/hooks-<pid>.sock` (pid-scoped; stale-sibling sweep at startup).

## Per-channel reference

### Channel 1 — HTTP hooks

Listener: `Sources/WorkspaceManagerCore/Services/AgentHookListener.swift`. Wraps `Network.NWListener` on the Unix socket. Sub-10ms response: parse → enqueue into actor mailbox → return `200 OK`. Routes:

- `POST /event` → decode via `ClaudeCodeAdapter`, resolve host session via `AgentSessionRegistry.resolveHostSession(cwd:agentSessionID:)`, ingest.
- `POST /statusline` → decode `StatusLinePayload`, call `registry.updateStatusFields(_:for:)`. Channel 2 surface.
- `GET /healthz` → `200 OK` with body `OK`.

Resolve order is `agentSessionID` first, then cwd-pick (only for `SessionStart`-shaped events with no prior binding, restricted to entries where `agentSessionID == nil`, tie-broken by `createdAt`). This prevents two terminals on the same repo from collapsing onto the first match.

Production callsite: `HostTerminalStateStore.attach(agentSessionRegistry:)` then `syncRegistry(forSessions:)` from `publishSnapshot`. Every newly-created `HostTerminalSession` registers; every removed one deregisters. Wired from `WorkspaceManagerApp.swift` via the `AgentSessionRegistryAttacher` view modifier.

### Channel 2 — Status-line forwarder

Forwarder script: `Sources/WorkspaceManager/Resources/HookForwarders/statusline.sh`. Bundled. Reads JSON from stdin, POSTs to `http+unix://$WORKSPACES_HOOKS_SOCKET/statusline`, prints a single space (Claude Code's status row stays empty; the host owns visualization).

Handler: `AgentHookListener.processStatusLine`. Decodes `StatusLinePayload` (`Sources/WorkspaceManagerCore/Models/StatusLinePayload.swift`), resolves cwd → host session, calls `updateStatusFields`. Drops pre-`SessionStart` ticks silently. Tolerant decoder accepts both snake_case and camelCase wire keys, ISO-8601 with or without fractional seconds.

UI: `AgentsSettingsView` shows model badge, cost, context %, rate-limit headroom for the focused workspace's session. The Settings scene injects the registry both as `.environmentObject(...)` (for sub-view `@EnvironmentObject` access) and `.environment(\.agentSessionRegistry, ...)` (for the keyed `@Environment` read in `AgentsSettingsView`).

### Channel 3 — libghostty OSC fallback

Bridge: `Sources/WorkspaceManager/Terminal/GhosttyRuntimeActionBridge.swift` recognizes `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` and `GHOSTTY_ACTION_RING_BELL`. Dispatch goes through `Sources/WorkspaceManager/Terminal/AgentOSCRouter.swift` to the adapter-mapped event, ingested with `origin: .osc(surfaceID:)`.

Dedup: when an OSC event arrives within 750ms of a hook event with the same effective state, the registry suppresses it. After 750ms the OSC event applies (hook delivery failure was real). After 60s with no hook events, `hookActive` clears and OSC takes over.

Title-emit: `Sources/WorkspaceManager/Resources/HookForwarders/title-emit.sh` is registered as a hook on `UserPromptSubmit` and `Stop`. It writes `\e]2;%s\a` to `/dev/tty`, libghostty surfaces it as `GHOSTTY_ACTION_SET_TITLE`, and `GhosttySurfaceView.terminalTitle` updates.

Channel selection: `workspacesNotifChannelContribution()` writes `preferredNotifChannel: "iterm2"` into `~/.claude.json` on opt-in. The Ghostty channel still has reliability bugs through 2026; OSC 9 via the iterm2 setting is the empirically reliable path.

### Channel 4 — Transcript JSONL

Reader: `Sources/WorkspaceManagerCore/Services/TranscriptReader.swift`. Actor exposing `tail()` (cold-start replay) and `live()` (tail-f for currently-active sessions) `AsyncStream<TranscriptRecord>`. Tolerant decoder: known types (`user`, `assistant`, `tool_use`, `tool_result`, `summary`) get rich `ConversationLogView` rendering; unknown types decode to `.opaque(raw:)` and render as collapsed JSON.

Cold-start: `TranscriptColdStartRecovery` token-bucket-throttles replay to ≤500 events/sec and uses `AgentSessionRegistry.ingestBatch(events:for:origin:)` so a multi-thousand-record JSONL produces one `@Published` write per flush, not per record. Direct hard-constraint from the perf audit (PR #443) — the registry's per-event allocation amplifies under sustained high-rate flow.

Sidecar: `KnownSessionStore` persists known transcript paths; on launch, sessions whose hook listener was unreachable last run get their tail replayed.

### Channel 5 — Headless `claude -p`

Runner: `Sources/WorkspaceManagerCore/Services/HeadlessClaudeRunner.swift`. Actor wrapping `ProcessRunner`. Canonical invocation:

```
claude --bare -p "<prompt>" \
  --output-format stream-json --verbose --include-partial-messages \
  --allowedTools "<comma-list>" --permission-mode acceptEdits \
  [--resume <session_id>]
```

`--bare` always — skips user hooks/skills/plugins/MCP servers/CLAUDE.md for deterministic behavior. Required for any host-driven invocation; we never run with the user's interactive Claude config.

Parser: `HeadlessClaudeStreamParser` mirrors the web side's `parseStreamJsonLine` (`web/src/lib/agent-runtime/vercel-sandbox.ts`) so event semantics agree across host and web. Emits a forward-compatible `HeadlessClaudeEvent` enum with `.unknown(raw:)` for unrecognized line shapes.

Resume: capture `session_id` from the first `.result` event, persist under `<workspace>/.workspaces/headless/sessions.json`, resume with `--resume`. Headless runs use a synthetic `hostSessionID` namespace separate from interactive sessions — never share registry entries.

Setup hook: `WorkspaceService.createWorkspace(...)` after `setup.sh` chains `WorkspaceClaudeSetup` if `.workspaces/claude-setup.json` is present. Sidebar quick-action service-layer (`WorkspaceClaudeActions`) is plumbed; the SwiftUI surface for the action menu is a deferred follow-up.

## Settings UI & opt-in flow

`Settings → Agents` (`Sources/WorkspaceManager/Views/AgentsSettingsView.swift`) hosts the user-visible opt-in:

- Toggle "Send Claude Code status to WorkSpaces" — self-healing, reflects `ClaudeSettingsInstaller.isInstalled()`.
- Merge-preview sheet renders the diff against the user's current `~/.claude/settings.json` and `~/.claude.json` and requires explicit accept.
- Status row: install state, settings file path, last-detected mtime, last backup path.
- Manual-revert sheet: copyable `cp <backup> <settings>` command. Surgical removal of merged JSON is deferred.

Install lifecycle: `ClaudeIntegrationLifecycle.start(registry:)` registers all four contributions (`workspaces.hooks`, `workspaces.statusLine`, `workspaces.notifChannel`) with the installer. When the persisted opt-in is true, calls `installer.install()` silently on every launch so the pid-scoped socket path is always current — without this, every relaunch invalidates the URLs the previous launch wrote into `~/.claude/settings.json`.

Backup rotation: the installer keeps the most recent 5 `settings.json.workspaces-backup-<timestamp>` files (and the same for `.claude.json`). Older files are pruned after each successful install. Confirmed by `ClaudeSettingsInstallerBackupRotationTests`.

## Operational notes

- **Socket path** lives under `~/Library/Application Support/<bundle-id>/hooks-<pid>.sock`. Stale-sibling sweep on every startup removes orphan sockets whose pid is no longer alive (`kill -0`). If the app crashes without firing `willTerminateNotification`, the next launch cleans up.
- **CI gate**: `ClaudeIntegrationLifecycle.start` is a no-op when `CI=true` so self-hosted runners don't accumulate sockets.
- **`PTYForegroundProbe`** ships as a documented stub returning `.claudeCode`. libghostty doesn't expose the slave PTY fd publicly; real opencode/aider detection is a follow-up. Fail-safe today because Claude is the only adapter that decodes hooks; OSC works for everything else.
- **iCloud-synced `~/.claude/`**: pid-scoped socket paths from one Mac will overwrite another's. Last Mac to launch wins; others are silently dormant. Document this if it bites a real user.
- **Malformed `~/.claude/settings.json`**: silently overwritten with byte-for-byte backup of the broken bytes. Defensible. Worth a Settings UI surface someday.

## Performance characteristics

From the perf audit on PR #443's contract layer (`.context/claude-integration/perf-audit-pr443-final.md`, `Tests/WorkspaceManagerTests/Perf/PerfChannel1Tests.swift`):

| Surface | Number | Budget | Headroom |
|---|---:|---:|---|
| Hook ingest HTTP-200 p99 | 1.01 ms | 50 ms | 50× |
| Registry update p99 | 0.87 ms | 80 ms | 90× |
| Sidebar churn CPU (8 sess × 5 Hz × 60 s) | 0.49% | 5% | 10× |
| Status-line burst HTTP p99 | 0.86 ms | 50 ms | 58× |
| Channel 4 replay 10k records | 19.72 s | 25 s | 21% |
| Channel 4 replay RSS delta | 3.09 MB | 50 MB | 16× |

Real-world projection at 10 events/sec sustained: ~12 MB allocator pressure / 8-hour day. The 10-min stress at 5,000× realistic rate (1.92 GB RSS) is allocator pressure with periodic autorelease drains, not a registry leak. Channel 4's 500 ev/s replay cap and `ingestBatch` were specifically introduced because of that finding.

## Verification runbook

After any non-trivial change to the integration, run:

1. **Unit + perf tests** — `swift build && swift test`. The integration's full suite lives across `AgentSessionRegistryTests`, `AgentHookListenerTests`, `ClaudeSettingsInstallerTests`, `OSCDedupIntegrationTests`, `GhosttyRuntimeActionBridgeTests`, `TranscriptReaderTests`, `AgentSessionRegistryBatchTests`, `ColdStartRecoveryTests`, `HeadlessClaudeStreamParserTests`, `HeadlessClaudeRunnerTests`, `WorkspaceServiceClaudeSetupTests`, `StatusLinePayloadTests`. Perf tests are gated behind `WORKSPACES_PERF_RUN=1`.
2. **Build GhosttyKit** if framework is missing: `./scripts/build-ghosttykit.sh`.
3. **Lint**: `swift-format lint --strict --recursive Sources/ Tests/`.
4. **Dev launch**: `./scripts/launch-dev.sh --no-build --no-activate` for a shared-desktop-friendly smoke. The launcher should report the listener path it bound to.
5. **Manual end-to-end with a real `claude` session** (the only path some of these can be smoke-tested):
   - Open Settings → Agents, toggle on "Send Claude Code status to WorkSpaces", review the merge preview, accept.
   - Open a workspace, run `claude` in the embedded terminal.
   - Drive a tool call that triggers a permission prompt. Sidebar dot turns yellow; macOS notification fires.
   - Capture screenshots and `./scripts/evidence.sh --pr <N> --name claude-integration-smoke` to upload to R2.
6. **OSC fallback verification**: with the Settings toggle on, kill the dev binary's hook listener (find pid + `kill -USR1` if instrumented; otherwise full quit). Drive a notification from the embedded `claude` session. Confirm the sidebar dot transitions via the OSC path — the registry should log `origin: .osc` ingestion.
7. **Transcript replay verification**: open the conversation-log surface for a session that's still receiving live events. Confirm rich rendering for canonical types and collapsed JSON for unknown types. Replay the same JSONL through cold-start path; verify `ingestBatch` fires `@Published` exactly once per batch flush.
8. **Headless verification**: invoke the runner with `claude --bare -p "hello"` (real CLI required); confirm `system/init` arrives, text deltas stream, `result` event captures `session_id`. Resume with `--resume <session_id>`; confirm context carries.

## References

- Architecture spec: `.context/attachments/pasted_text_2026-05-03_22-18-10.txt`
- Coordinator's plan: `~/.claude/plans/system-instruction-you-are-working-golden-hearth.md`
- Perf audit: `.context/claude-integration/perf-audit-pr443-final.md`
- Coordination running file: `.context/claude-integration/coordination.md`
- Official Claude Code references:
  - Hooks: <https://code.claude.com/docs/en/hooks>
  - Status line: <https://code.claude.com/docs/en/statusline>
  - Headless / programmatic: <https://code.claude.com/docs/en/headless>
  - Settings: <https://code.claude.com/docs/en/settings>
  - Terminal config (notification channels, bell): <https://code.claude.com/docs/en/terminal-config>

## PR sequence (history)

1. **#443** — Contract layer + Channel 1 (hook listener, registry, settings installer, Settings UI).
2. **#451** — Channel 3 OSC fallback + backup rotation in `ClaudeSettingsInstaller`.
3. **#452** — Channel 2 status-line forwarder + `/statusline` route + Live Status indicator.
4. **#453** — Channel 5 headless `claude -p` runner + workspace warm-up chain.
5. **#454** — Channel 4 transcript replay + cold-start state recovery + `ingestBatch`.
6. **This PR** — Final integration: documentation, smoke runbook, residual cleanup.
