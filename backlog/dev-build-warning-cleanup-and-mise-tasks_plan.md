---
status: pending
category: followup
topic: developer-tooling
priority: 2
description: Reduce remaining Swift 6 warning noise in local builds and consolidate the now-partially-adopted mise task surface.
---

# Developer Build Warning Cleanup and Mise Task Migration

## Problem Statement

Local developer workflows currently work, but they are still noisier than they should be. A cold `./scripts/launch-dev.sh --no-activate` run succeeds and launches the debug app, but the underlying build still emits a large Swift 6 warning set centered on SwiftData models crossing actor and `@Sendable` boundaries. On 2026-03-08, a cold launcher rebuild reported `174` warnings and wrote the full output to `.dev-data/logs/build-dev-20260308-141224.log`.

We also explored whether `launch-dev.sh` should be the one canonical "do the right thing" entrypoint. The launcher is better now: it preflights `.mise.toml` trust, auto-builds GhosttyKit when needed, and summarizes build logs instead of flooding the terminal. The repo now has a small `mise` task catalog, but it is uneven: the primary `dev-*` launch and Lume flows are represented, while the broader build/test/task surface is still split between direct scripts, raw SwiftPM commands, and docs.

This work matters because warning fatigue obscures real regressions, and fragmented entrypoints make it harder for future sessions to discover the correct build/test/launch path. The next step is not another round of tactical suppression. It is a deliberate boundary cleanup for provider/runtime APIs plus a decision on how far to standardize the existing `mise` task surface.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Warning strategy | Fix warnings by moving provider/runtime boundaries toward immutable snapshots, not by adding unsafe model conformances | The current warnings come from `Repo` and `Workspace` crossing actor and `@Sendable` boundaries; suppressing them would hide real concurrency debt |
| First migration step for dev tooling | Introduce `mise` tasks as the top-level task catalog while keeping existing scripts as the first implementation layer | This reduces risk and preserves proven scripts while improving discoverability |
| Launcher role | Keep `scripts/launch-dev.sh` as the implementation behind `mise run launch-dev` during migration | Existing docs and automation already depend on the script |
| Migration scope | Move only the most common developer flows first: GhosttyKit build, app build, launch, tests, smoke/capture | A full script-to-task rewrite is unnecessary until the task surface proves valuable |
| Success metric | Reduce launcher-visible build noise and provide one obvious developer entrypoint | Developers need a clean day-to-day workflow more than an immediate full tooling rewrite |

## Architecture

```text
Current
-------
developer
   |
   +--> scripts/build-ghosttykit.sh
   +--> swift build
   +--> scripts/launch-dev.sh
   +--> scripts/ui-smoke.sh
   +--> scripts/lume-e2e-capture.sh

Planned
-------
developer
   |
   +--> mise run build-ghosttykit
   +--> mise run build
   +--> mise run launch-dev
   +--> mise run test
   +--> mise run lume-e2e
             |
             +--> existing scripts (initially)
             +--> direct task logic where it becomes cleaner

Concurrency boundary cleanup
----------------------------
SwiftData Repo/Workspace models
   |
   X  today: passed directly into actor/provider APIs
   |
   +--> planned: immutable snapshots / ids / value payloads
             |
             +--> actor/provider logic
             +--> MainActor persistence/update layer
```

## Research Artifacts

- `scripts/launch-dev.sh` now includes:
  - `.mise.toml` trust preflight at `scripts/launch-dev.sh:166-190`
  - GhosttyKit existence check and auto-build at `scripts/launch-dev.sh:193-207`
  - summarized build logging at `scripts/launch-dev.sh:209-244`
- `.mise.toml` now includes a small `dev-*` task catalog for launch/smoke/Lume flows, but still lacks a full common build/test/task surface.
- `WorkspaceProviderProtocol` currently exposes `Workspace` and `[Workspace]` directly across provider boundaries at `Sources/WorkspaceManagerCore/Services/WorkspaceProviders.swift:162-185`.
- `SidebarWorkspaceController` persists partial results through a closure that captures non-Sendable SwiftData state at `Sources/WorkspaceManager/Views/MainWindow/SidebarWorkspaceController.swift:85-98`.
- The fixture provider still mirrors the same pattern and warns on actor-isolated methods that take `Workspace` at `Sources/WorkspaceManager/App/UIFixtureLumeEnvironment.swift:387-421`.
- `LumeSetupCoordinator` had a separate progress-handler warning path, partially reduced by making progress handlers `@MainActor @Sendable`, but the broader SwiftData boundary warnings remain at `Sources/WorkspaceManager/Views/MainWindow/LumeSetupCoordinator.swift:133-142`.
- Official `mise` task support is suitable for incremental migration:
  - tasks can live in `[tasks]` sections in `mise.toml`
  - tasks can shell out to existing scripts via `run` or `file`
  - tasks can be invoked with `mise run <task>`

Example TOML task shape from official `mise` docs:

```toml
[tasks.launch-dev]
description = "Launch the local debug app"
file = "scripts/launch-dev.sh"
```

## Implementation Phases

### Phase 1: Classify and Reduce Warning Roots

**Files to modify:**
- `Sources/WorkspaceManagerCore/Services/WorkspaceProviders.swift` - replace direct `Workspace` model arguments in provider protocols where possible
- `Sources/WorkspaceManager/Views/MainWindow/SidebarWorkspaceController.swift` - stop capturing `Repo` and `Workspace?` inside `@Sendable` persistence closures
- `Sources/WorkspaceManager/App/UIFixtureLumeEnvironment.swift` - align fixture provider APIs with the same value-based boundaries as production providers
- `Sources/WorkspaceManager/Views/MainWindow/LumeSetupCoordinator.swift` - finish progress callback isolation cleanup
- `Sources/WorkspaceManagerCore/Models/Models.swift` - add snapshot/value helpers, not unchecked model conformances

**Files to create:**
- `Sources/WorkspaceManagerCore/Models/WorkspaceSnapshots.swift` - immutable value types for provider/runtime crossings

**Acceptance criteria:**
- [ ] `swift build` no longer emits the current `Workspace`/`Repo` sendability warning family
- [ ] No `@unchecked Sendable` conformance is added to SwiftData models as the final fix
- [ ] Production and fixture provider paths use the same value-based boundary shape

### Phase 2: Introduce a Mise Task Catalog

**Files to modify:**
- `.mise.toml` - add task definitions for common development flows
- `scripts/launch-dev.sh` - keep as implementation backend for the launcher task during migration
- `scripts/README.md` - document `mise run ...` entrypoints first, scripts second
- `README.md` - update developer workflow references
- `docs/development/libghostty-integration.md` - mention task equivalents for the shortcut verification loop
- `docs/development/lume-validation.md` - add `mise` task equivalents for fixture capture and real-host validation

**Acceptance criteria:**
- [ ] `mise tasks` shows the main developer flows
- [ ] `mise run launch-dev` maps to the current launcher behavior
- [ ] `mise run build-ghosttykit`, `mise run build`, `mise run test`, and `mise run lume-e2e` exist
- [ ] Existing scripts continue to work during the migration period

### Phase 3: Decide What Stays as Scripts

**Files to modify:**
- `.mise.toml` - decide which tasks remain shell-backed vs move inline
- `scripts/README.md` - narrow the documented direct-script surface

**Acceptance criteria:**
- [ ] Each script is categorized as one of:
  - implementation detail behind a `mise` task
  - standalone automation artifact worth keeping directly callable
  - obsolete and removable
- [ ] The repo has one documented "start here" developer entrypoint strategy

### Phase 4: Verification and Rollout

**Files to modify:**
- `docs/development/troubleshooting.md` - include task-runner troubleshooting
- `AGENTS.md` - update recommended local verification commands if `mise` becomes primary

**Acceptance criteria:**
- [ ] Fresh-session instructions point to one canonical path
- [ ] The launcher output is concise by default
- [ ] Full build logs are still discoverable when needed

## Verification Commands

```bash
# Current baseline
./scripts/build-ghosttykit.sh
swift build
./scripts/launch-dev.sh --no-activate

# Inspect current warning count from the summarized launcher
swift package clean
./scripts/launch-dev.sh --no-activate

# Review full build log when warning cleanup work starts
ls -1t .dev-data/logs/build-dev-*.log | head -n 1

# Future-state target
mise tasks
mise run build-ghosttykit
mise run build
mise run launch-dev -- --no-activate
mise run test
mise run lume-e2e
```

## Rollback Plan

If the `mise` task migration becomes confusing or breaks existing automation:

1. Keep all existing scripts as the source of truth until task parity is proven.
2. Revert `.mise.toml` task additions and doc changes only.
3. Leave the improved `launch-dev.sh` preflights and summarized logging intact, since they already improve the script-first workflow.

If warning cleanup refactors destabilize persistence or provider behavior:

1. Revert snapshot-boundary changes in `WorkspaceProviders.swift`, provider implementations, and `SidebarWorkspaceController`.
2. Restore the last known-good protocol surface.
3. Keep any test additions that cover the intended snapshot behavior for the next attempt.

## References

- `Sources/WorkspaceManagerCore/Services/WorkspaceProviders.swift:162-185`
- `Sources/WorkspaceManager/Views/MainWindow/SidebarWorkspaceController.swift:85-98`
- `Sources/WorkspaceManager/App/UIFixtureLumeEnvironment.swift:387-421`
- `Sources/WorkspaceManager/Views/MainWindow/LumeSetupCoordinator.swift:133-142`
- `scripts/launch-dev.sh:166-244`
- `.mise.toml:1-2`
- `docs/development/lume-validation.md`
- `scripts/README.md`
- [mise Tasks](https://mise.jdx.dev/tasks/)
- [mise TOML-based Tasks](https://mise.jdx.dev/tasks/toml-tasks.html)
- [mise run](https://mise.jdx.dev/cli/run.html)
