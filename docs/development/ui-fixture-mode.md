# UI Fixture Mode

In-memory SwiftData seeding plus deterministic agent-status and command-status seeding so the app can launch into a known visual state for screenshots, design review, and visual regression. Scope: the seeded model state is in-memory and no real agents drive the sessions. The rest of the app still does its normal launch IO — outside `CI=1`, `ClaudeIntegrationLifecycle` binds a Unix socket under Application Support keyed by pid (`Sources/WorkspaceManager/App/WorkspaceManagerApp.swift:55-60`), `LocalStateStore` writes SQLite under the dev-data dir, and the synthetic `HostTerminalSession`s spawn real PTYs (which fall back to `$HOME` when the seeded path doesn't exist — see "Known limits"). For a truly hermetic capture environment, set `CI=1`, a dedicated `WORKSPACES_DATA_DIR`, and an isolation signal for preferences (see "Preferences isolation").

Fixture mode is debug-only. The seeding harness was compiled out of release builds in #1235 and the launch-surface parsers (`_OPEN_PREVIEW`, `_OPEN_DIAGNOSTICS`, `_OPEN_SESSION_SWITCHER`, `_SELECT_WEB_SOURCE`, `_FILE_TREE_FAILURE`) follow the same release-absence contract, so their arming variables are inert in a release binary — `scripts/check-release-harness-absence.sh` enforces that. Drive fixtures from `./scripts/launch-dev.sh` (debug), never from an installed release app.

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
| `WORKSPACES_UI_FIXTURE_FILE_TREE_FAILURE` | optional | `unavailable` or `permission`; opens the Detail Pane and stages the corresponding file-tree recovery state. Prefer the named `file-tree-unavailable` and `file-tree-permission` evidence scenarios. |
| `WORKSPACES_UI_FIXTURE_SIDEBAR_ARRANGEMENT` | optional | `alphabetical`, `lastAccessed`, or `recent`; pins the sidebar arrangement for the launch, overriding the stored preference so a scenario renders the same way on any machine. Debug-only (`UIFixtureSidebarArrangementBootstrap`), enforced absent from release by `scripts/check-release-harness-absence.sh`. The `sidebar-recent` scenario sets it. |
| `WORKSPACES_UI_FIXTURE_CMD_T_REPO` | optional | Opens the named seeded repository overview for Cmd-T before/after evidence. Prefer the named `cmd-t-repo-overview` and `cmd-t-repo-terminal` scenarios. |
| `WORKSPACES_UI_FIXTURE_TRIGGER_CMD_T` | optional | With `WORKSPACES_UI_FIXTURE_CMD_T_REPO`, invokes the production new-terminal-tab action after selecting the overview. |
| `WORKSPACES_UI_FIXTURE_OPEN_SESSION_SWITCHER` | optional | `1` opens the Cmd-P Session Switcher after fixture launch for deterministic overlay captures. |
| `WORKSPACES_UI_FIXTURE_SEED_RESTORE_BANNER` | optional | `1` seeds a synthetic previous-run continuity row (see "Staging the restore banner" below) so the cold-start restore banner has something to offer. Also requires `WORKSPACES_RESTORE_SESSIONS_ON_LAUNCH=1` — the banner itself is gated behind that experiment independently of fixture mode. |
| `WORKSPACES_UI_FIXTURE_SEED_ORPHAN_BANNER` | optional | `1` stages the workspace-orphan cleanup banner with one deterministic synthetic item (`UIFixtureOrphanBannerBootstrap`, debug-only behind `#if DEBUG` per #1235/#1237 — the release build carries a stub and `scripts/check-release-harness-absence.sh` enforces the key's absence). Fixture mode always replaces the real filesystem orphan scan — with the synthetic item when this is set, with an empty result otherwise — so dev-machine leftovers never leak into captures or ui-state goldens (issue #1228). The `orphan-banner` scenario sets it. The banner is decided by deferred startup work ~2s after first paint, so its golden declares a `settle` (`fixtures/ui-state/README.md`). |

## Preferences isolation

`WORKSPACES_DATA_DIR` scopes the SwiftData store and the SQLite sidecar; `UserDefaults` is a third state axis, and a launch that ignores it inherits whatever selection the last dev or fixture session left behind — which costs a spurious terminal attach at launch and makes "clean launch" assertions unreliable (#1252).

| Variable | Effect |
|----------|--------|
| `WORKSPACES_SYNTHETIC_ROOT` | Any non-blank value marks the run synthetic: preferences resolve to a scratch suite named `com.cloudcompute.workspaces.isolated.<digest>`, where the digest is derived from the root itself, and the app wipes that suite at bootstrap. Every isolated launch therefore starts with no stored selection, theme, or settings state, and two launches under different roots neither share a plist nor wipe each other. |
| `WORKSPACES_PREFERENCES_SUITE` | Names an explicit suite instead. Nothing wipes it on the app's behalf, so this is the form to use for isolation without a synthetic root, for two isolated launches that share one root but must not share one suite, or when preferences should survive a relaunch inside one run. A name that resolves back to a persistent domain (the app id, `WorkspaceManager`, the global domain) or to the scratch-suite base `com.cloudcompute.workspaces.isolated` is ignored. |

Both are read once at bootstrap (`Sources/WorkspaceManagerCore/Services/LaunchPreferences.swift`) and the resolved store backs every `@AppStorage` and settings read in the app. Unset, the app reads and writes the persistent domain exactly as before. The resolved domain is logged at launch:

```bash
log stream --predicate 'subsystem == "com.cloudcompute.workspaces"' --level info --style compact | grep LaunchPreferences
# [LaunchPreferences] domain=scratch suite=com.cloudcompute.workspaces.isolated.cc2195059e870052 reset=true isolated=true
```

The digest is a stable FNV-1a of the root string, not a per-process hash, so helper processes that share the environment (the `workspaces` CLI driving a live isolated app) land on the same suite and read it without clearing it — only the app's own bootstrap resets.

**Lanes that seed preferences before launch.** `scripts/continuity-evidence.sh` and `scripts/shortcut-pass-through-smoke.sh` write and read `com.cloudcompute.workspaces` directly (`defaults write com.cloudcompute.workspaces mainWindow.lastSurface …`, `defaults read com.cloudcompute.workspaces terminalMultiplexingMode`). That domain is the right target only while the lane launches the app unisolated. The moment a lane sets `WORKSPACES_SYNTHETIC_ROOT`, the app stops reading that domain and its seeds go nowhere — such a lane must seed the same scratch suite the app will resolve to, or set `WORKSPACES_PREFERENCES_SUITE` to a name it picks and seed that. Migrating those two lanes belongs with the synthetic-root integration (#1245), not here.

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

The other workspaces carry spread access dates so the Recent arrangement renders all three of its buckets from one seed: `skills-v13` and `refactor-state` sit 3 days back (This Week), `bugfix-422` and `refactor-runtime` 30 days back (Earlier). The spread is relative to the `now` passed to `seedDataIfNeeded(in:now:)`, so it is stable within a run and deterministic in tests.

## Staging the restore banner

The cold-start restore banner (`MainWindowRestoreController` / `TerminalRestorePlanner`, #1160 slice 4) reads durable continuity rows from `LocalStateStore`'s SQLite sidecar — a *different* store than the in-memory SwiftData `UIFixtureSeeder` seeds above. The app evidence lane (`./scripts/evidence.sh --fixture`) always launches with `--clean-data`, which wipes that SQLite sidecar before every capture for determinism — but that leaves nothing for the banner to offer, since it only ever shows continuity carried over from a run that already ended (issue #1192).

`WORKSPACES_UI_FIXTURE_SEED_RESTORE_BANNER=1` closes that gap by writing one synthetic "previous run" row directly through a second `LocalStateStore` instance, stamped with a `runStartedAt` several minutes before the real launch's own. `UIFixtureContinuitySeeder.swift` does this at `WorkspaceManagerApp.init()`, targeting the `feature-auth` workspace `UIFixtureSeeder` already seeds into SwiftData, so `TerminalRestoreTargetResolver` resolves it against live data exactly as it would a real prior session. `ContentView.computeRestorePlanIfEnabled()` awaits the seed write (`UIFixtureContinuitySeeder.waitUntilSeeded()`) before reading continuity data, so there's no race between the seed and the plan it feeds.

The seeded row deliberately avoids all three suppression predicates in `MainWindowRestoreController.disposition(for:handledRunID:seedKey:seedDirectory:)`:

- **`noRestorableSurfaces`** — the row is active (`ended_at IS NULL`), so the plan is non-empty.
- **`alreadyHandled`** — each seed mints a fresh `runID`, which can't collide with a `terminalRestoreHandledRunID` recorded by an earlier capture.
- **`onlyDuplicatesLaunchSeed`** — the row resolves to `.hostPath(<feature-auth path>)`, distinct from the `.defaultHome` key the pre-restore launch seed uses, so it's never just a duplicate of that seed regardless of which restore action (`freshShell`, absent a live tmux session or resumable transcript) the planner picks.

**Production-database safety.** `UIFixtureContinuitySeeder.isSafeToSeed(databaseURL:)` refuses to write into the real, unconfigured production `LocalStateStore` path — the one `LocalStateStoreBootstrapper.defaultDatabaseURL` resolves to absent any `WORKSPACES_DATA_DIR`/`WORKSPACES_LOCAL_STATE_DIR` override — regardless of which override produced a match. `seedIfNeeded()` is only reachable when the primary store bootstrap already confirmed an explicit override was live (`localStateBootstrap.store != nil` in `WorkspaceManagerApp.init()`), so this check is specifically about an override that happens to *equal* the production path (set by accident, or inherited from a shell profile) rather than fixture mode's own "no override" case, which the primary bootstrap already disables independently.

**Known residual risk: banner-decision timing.** The evidence lane's readiness gate is "operator credential present" plus "non-blank window content" — neither directly observes whether `computeRestorePlanIfEnabled()` has finished deciding the banner, only that the base window painted *something*. `app_capture_window` adds a fixed settle delay before its final snapshot when a restore-banner scenario is requested, but this is a heuristic margin, not a hard guarantee: under enough I/O contention (e.g. the launch-time retention pass overlapping the seed write), a capture could in principle land after the base chrome paints but before the banner does. No introspection signal currently distinguishes "restore plan decided" from "window painted" for the evidence lane to poll instead. A seed write that fails outright (e.g. a busy-timeout under that same contention) is caught and logged at `UIFixtureContinuitySeeder.swift`'s call site rather than surfaced to the capture script, so that failure mode also degrades to a banner-less capture rather than a loud error — check `.dev-data/logs` for `[UIFixtureContinuitySeeder]` if a `restore-banner` capture comes back without the banner.

This also requires `WORKSPACES_RESTORE_SESSIONS_ON_LAUNCH=1` — `restoreSessionsOnLaunch` is an experimental flag independent of fixture mode, and `computeRestorePlanIfEnabled()` no-ops without it. The `restore-banner` fixture scenario (`scripts/lib/fixture-scenarios.sh`) sets both env vars together so callers don't need to remember the pairing:

```bash
./scripts/evidence.sh --pr <N> --fixture restore-banner
```

This wires through `app-capture.sh` only — the interactive `release-screenshot/scripts/capture.sh` path doesn't pass `--clean-data` between runs, so it doesn't hit the gap this seeds around.

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
| `WorkspaceManagerApp.init()` | `Sources/WorkspaceManager/App/UIFixtureContinuitySeeder.swift` | Calls `UIFixtureContinuitySeeder.seedIfNeeded()` — writes the synthetic previous-run continuity row (see "Staging the restore banner" above). `ContentView.computeRestorePlanIfEnabled()` awaits its completion before reading. |

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
- `Sources/WorkspaceManager/App/UIFixtureContinuitySeeder.swift` — the restore-banner continuity seeder (issue #1192).
- `Tests/WorkspaceManagerAppTests/UIFixtureContinuitySeederTests.swift` — unit coverage for the seed plan and an end-to-end proof that the seeded row reaches `.offer` in `MainWindowRestoreController.disposition`.
