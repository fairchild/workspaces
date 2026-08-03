# UI Fixture Mode

In-memory SwiftData seeding plus deterministic agent-status and command-status seeding so the app can launch into a known visual state for screenshots, design review, and visual regression. Scope: the seeded model state is in-memory and no real agents drive the sessions. The rest of the app still does its normal launch IO — outside `CI=1`, `ClaudeIntegrationLifecycle` binds a Unix socket under Application Support keyed by pid (`Sources/WorkspaceManager/App/WorkspaceManagerApp.swift:55-60`), `LocalStateStore` writes SQLite under the dev-data dir, and the synthetic `HostTerminalSession`s spawn real PTYs (which fall back to `$HOME` when the seeded path doesn't exist — see "Known limits"). For a truly hermetic capture environment, set `CI=1` and a dedicated `WORKSPACES_DATA_DIR`.

## Quick start

```bash
# Sidebar with no agent statuses — clean baseline
WORKSPACES_UI_FIXTURE=1 WORKSPACES_DISABLE_AUTO_IMPORT=1 ./scripts/launch-dev.sh --no-build

# Sidebar with named status dots — the canonical Phase 1 release shape
WORKSPACES_UI_FIXTURE=1 \
WORKSPACES_DISABLE_AUTO_IMPORT=1 \
WORKSPACES_UI_FIXTURE_AGENT_STATES="feature-auth:thinking,bugfix-422:awaitingInput,refactor-runtime:errored" \
./scripts/launch-dev.sh --no-build

# Terminal command-status sliver
WORKSPACES_UI_FIXTURE=1 \
WORKSPACES_DISABLE_AUTO_IMPORT=1 \
WORKSPACES_UI_FIXTURE_COMMAND_STATUSES="feature-auth:failed" \
./scripts/launch-dev.sh --no-build

# Session Switcher open for capture
WORKSPACES_UI_FIXTURE=1 \
WORKSPACES_DISABLE_AUTO_IMPORT=1 \
WORKSPACES_UI_FIXTURE_OPEN_SESSION_SWITCHER=1 \
./scripts/launch-dev.sh --no-build
```

For repeatable captures, prefer the wrapper:

```bash
.claude/skills/release-screenshot/scripts/capture.sh phase-1-release
```

## Env vars

| Variable | Required | Purpose |
|----------|----------|---------|
| `WORKSPACES_UI_FIXTURE` | `1` to enable | Seeds an in-memory `ModelContainer` with the canonical fixture repos, web sources, and workspaces. Without this, none of the other vars do anything. |
| `WORKSPACES_DISABLE_AUTO_IMPORT` | `1` recommended | Stops the app from auto-importing `~/code/*` repos on launch — keeps the sidebar deterministic. |
| `WORKSPACES_UI_FIXTURE_AGENT_STATES` | optional | Comma-separated `<workspace-name>:<state>` pairs that drive specific workspaces into specific `AgentRunState`s. |
| `WORKSPACES_UI_FIXTURE_COMMAND_STATUSES` | optional | Comma-separated `<workspace-name>:<status>` pairs that drive specific terminal sessions into synthetic `LastCommandStatus` values. |
| `WORKSPACES_UI_FIXTURE_OPEN_SESSION_SWITCHER` | optional | `1` opens the Cmd-P Session Switcher after fixture launch for deterministic overlay captures. |

### `WORKSPACES_UI_FIXTURE_AGENT_STATES` grammar

```
<entry>     := <workspace-name> ":" <state>
<entries>   := <entry> ("," <entry>)*
<state>     := "idle" | "thinking" | "runningTool" | "awaitingInput" | "errored" | "complete"
```

- Whitespace around delimiters is tolerated.
- Workspace names are case-insensitive against the fixture's seeded names.
- Unknown names or unknown state tokens log via `NSLog("[UIFixture] …")` and are skipped — the remaining valid entries still apply. Fixture mode is best-effort and never crashes.

The first listed entry is also used as the foreground tab and active workspace — natural reading order; no separate "primary" flag.

### `WORKSPACES_UI_FIXTURE_COMMAND_STATUSES` grammar

```
<entry>     := <workspace-name> ":" <status>
<entries>   := <entry> ("," <entry>)*
<status>    := "success" | "failed" | "running" | "finished"
```

- `success` publishes a completed `swift build` status with exit `0`.
- `failed` publishes a completed `swift test` status with exit `1`.
- `running` publishes an in-flight `swift test` status.
- `finished` publishes a completed `git status` status with unknown exit code.

The first listed command-status entry is also used as the foreground tab.

## Seeded fixture shape

`UIFixtureSeeder.seedDataIfNeeded(in:)` inserts the following on first launch:

| Repo | Workspaces |
|------|------------|
| `skills` | `skills-v13` |
| `services` | — |
| `superpowers` | — |
| `workspaces` | — |
| `bertram-chat` | `feature-auth` (default selection), `bugfix-422`, `refactor-state` |
| `bread-builder` | `refactor-runtime` |

Plus one web source: `Swift Docs` (`https://docs.swift.org/`).

Workspace paths point under `~/code/workspaces/<repo>/<workspace>/` for tab labels and `cd` targets, but **the paths don't need to exist on disk** — SwiftData accepts any string, and terminal PTYs fall back to `$HOME` when the path is missing.

`feature-auth.lastAccessedAt` is bumped 60 s into the future so `MainWindowBootstrapController.fallbackSurface` picks it as the auto-selected workspace at launch.

## Architecture

The status pipeline is the same code path real agents flow through. Fixture mode just synthesises the inputs:

```
WORKSPACES_UI_FIXTURE_AGENT_STATES env var
                  │
                  ▼
  UIFixtureSeeder.seedAgentStatesIfNeeded(...)
                  │
       per workspace, for each entry:
                  │
                  ▼
  tileTreeStore.activateSession(.hostPath(path), …)
       └─▶ HostTerminalSession created in coordinator.sessions
       └─▶ syncRegistry() → AgentSessionRegistry.register(hostSessionID:…)
                  │
                  ▼
  AgentSessionRegistry.apply(events: [...], for: session.id, origin: .hook)
       └─▶ status.run = .thinking / .awaitingInput / .errored / ...
                  │
                  ▼
  ContentView.refreshWorkspaceStatusAggregator() (re-fires on
  agentSessionRegistry.statuses change)
       └─▶ presentation.sessionKey(for: workspace) → .hostPath(path)
       └─▶ presentation.freshestAgentStatus(for: key, sessions:, statuses:)
                  │
                  ▼
  WorkspaceStatusAggregator
       └─▶ sidebar dots, bubbled repo dots, "N need you" toolbar pill

WORKSPACES_UI_FIXTURE_COMMAND_STATUSES env var
                  │
                  ▼
  UIFixtureSeeder.seedCommandStatusesIfNeeded(...)
                  │
       per workspace, for each entry:
                  │
                  ▼
  tileTreeStore.activateSession(.hostPath(path), …)
       └─▶ HostTerminalSession created in coordinator.sessions
                  │
                  ▼
  LastCommandStatusRegistry.setStatus(..., for: session.id)
                  │
                  ▼
  TerminalCommandStatusSliver
       └─▶ command-state-only sliver above the visible terminal pane
```

Why we route through `HostTerminalSession` instead of injecting statuses straight into the aggregator: agent status is *defined* as a property of a terminal session in this app, and `freshestAgentStatus` short-circuits to `nil` when `sessions.isEmpty`. Synthetic statuses on phantom UUIDs would be orphaned in the registry, never surfaced. By driving through the production pipeline, the fixture exercises the same chain real agents do — if the fixture screenshot looks right, production rendering of the same statuses also works. Detailed reasoning is in `docs/development/notifications.md` and the inline comments in `UIFixtureSeeder.swift`.

## Where it runs

| When | Where | What |
|------|-------|------|
| `WorkspaceManagerApp.init()` | `Sources/WorkspaceManager/App/WorkspaceManagerApp.swift` | Calls `UIFixtureSeeder.seedDataIfNeeded(in:)` — populates SwiftData with the repos/workspaces above. |
| `MainWindowRootView.body` ▸ `AgentSessionRegistryAttacher.onAppear` | same file | Calls `UIFixtureSeeder.seedAgentStatesIfNeeded(…)` and `seedCommandStatusesIfNeeded(…)` — reads fixture env vars, drives sessions, and applies synthetic status. Runs after the registry/host store wiring; idempotent via module-static latches. |

The split is structural: the SwiftData seeder runs at app-init time because that's where the model container is created; the agent-state seeder runs at view-attach time because that's where the `TileTreeStore` first becomes reachable. The latch makes the agent-state seeder safe against repeat `onAppear` events.

## Adding fixtures

### A new workspace

Edit `UIFixtureSeeder.seedDataIfNeeded(in:)`. Pick a parent repo, give the workspace a unique name, point its path under `~/code/workspaces/<repo>/<name>/`. Don't bother creating directories on disk.

If you want the new workspace to be the default selection on launch, bump its `lastAccessedAt` higher than `feature-auth`'s (currently `Date().addingTimeInterval(60)`).

### A new agent run-state token

The env var's `<state>` tokens map to `AgentRunState` values inside `UIFixtureSeeder.runState(for:)`. To add a variant — e.g. `awaitingIdle` for `.awaitingInput(reason: .idlePrompt)` — add a `case` arm there and a row in `.claude/skills/release-screenshot/references/scenarios.md` under "Supported states." The events list in `events(for:)` may also need a new arm if the state requires a different synthetic event shape.

### A new command-status token

The command-status env var's `<status>` tokens map to `UIFixtureSeeder.FixtureCommandStatus` values. To add a variant, add a `case` arm in `commandStatus(for:)`, define the synthetic `LastCommandStatus`, and mirror the token in `.claude/skills/release-screenshot/references/scenarios.md`.

### A new named release-screenshot scenario

Edit `scripts/lib/fixture-scenarios.sh`'s `case` block — the single source of truth for named scenarios — and mirror the entry in `.claude/skills/release-screenshot/references/scenarios.md`. Both the release-screenshot `capture.sh` and the [app evidence lane](evidence.md#app-evidence-lane-first-choice-ui-capture) (`./scripts/evidence.sh --fixture <scenario>`) resolve scenarios through that library, so a new entry is immediately available to both. See `.claude/skills/release-screenshot/references/extending.md` for the full walkthrough.

## Known limits

- **One tab per agent-state entry.** Every `HostTerminalSession` shows in the tab bar. A three-entry scenario produces three tabs. The first entry is re-activated last so its workspace is the foreground tab; the others sit behind it.
- **Command-status entries also create tabs.** Every command-status entry activates a `HostTerminalSession`; the first entry is re-activated last so the sliver is visible in the foreground tab.
- **Tab labels are best-effort.** PTYs spawn into the workspace path or `$HOME` if it doesn't exist; the tab title shows whatever directory the shell actually lands in (often `fairchild` for `$HOME` rather than the workspace name). Create the directory at the seeded path if a clean label matters.
- **Repo expansion is "expand all" in fixture mode.** `SidebarExpansionStateController.initializeRepoExpansionIfNeeded` force-expands every fixture repo on boot, masking a latent race where the production `.onChange(of: selectedWorkspace?.id)` observer can miss the nil → set transition. Replicating the design mockup's "collapsed repo with bubbled dot" storytelling requires fixing that race first; not in scope for the fixture mode itself.
- **Terminal scrollback isn't seeded.** Whatever your shell's prompt produces is what you'll capture. Fixture mode is for chrome (sidebar, toolbar, title bar), not for terminal content.
- **Repo overview content isn't seeded.** PR lists, recent commits, etc. require a real git repo at the workspace path.

## Related

- `docs/development/evidence.md` § "App evidence lane" — the first-choice path that stages a fixture state, snapshots the main window via operator scope, and uploads in one command (`./scripts/evidence.sh --fixture <scenario>`).
- `scripts/lib/fixture-scenarios.sh` — single source of truth mapping scenario names to fixture env; shared by the evidence lane and the release-screenshot capture script.
- `.claude/skills/release-screenshot/SKILL.md` — the agent-facing skill that wraps fixture mode for repeatable captures.
- `Sources/WorkspaceManager/App/UIFixtureSeeder.swift` — the seeder implementation.
- `Tests/WorkspaceManagerAppTests/UIFixtureSeederTests.swift` — unit coverage for env-var parsing, state mapping, idempotency, and the "first entry becomes active session" invariant.
