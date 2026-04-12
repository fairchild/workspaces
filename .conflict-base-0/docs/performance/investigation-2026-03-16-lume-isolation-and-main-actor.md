# Performance Investigation - 2026-03-16

## Goal

Investigate the release-blocking latency regressions and identify where Lume is still coupled into core user flows so it can be isolated further or removed cleanly later.

## Reproduction

Primary comparison commands:

```bash
WORKSPACES_FOCUS_DIAGNOSTICS=1 WORKSPACES_SHEET_DIAGNOSTICS=1 \
  ./scripts/perf-baseline.sh 5 8 --launch-mode no-activate

WORKSPACES_FOCUS_DIAGNOSTICS=1 WORKSPACES_SHEET_DIAGNOSTICS=1 \
  ./scripts/perf-baseline.sh 5 8 --launch-mode activate

WORKSPACES_FOCUS_DIAGNOSTICS=1 WORKSPACES_SHEET_DIAGNOSTICS=1 \
  ./scripts/new-workspace-perf.sh 5 12 --launch-mode no-activate

WORKSPACES_FOCUS_DIAGNOSTICS=1 WORKSPACES_SHEET_DIAGNOSTICS=1 \
  ./scripts/new-workspace-perf.sh 5 12 --launch-mode activate
```

Artifacts captured during this pass:

- `/tmp/workspaces-perf-baseline-20260316-012612/summary.json`
- `/tmp/workspaces-perf-baseline-20260316-012700/summary.json`
- `/tmp/workspaces-new-workspace-perf-20260316-012749/summary.json`
- `/tmp/workspaces-new-workspace-perf-20260316-012857/summary.json`
- `/tmp/workspaces-perf-baseline-20260316-013107/run-1.log`
- `/tmp/workspaces-perf-baseline-20260316-013122/run-1.log`

## Investigation Aids Added

This investigation added opt-in diagnostics rather than changing normal runtime behavior:

- `WORKSPACES_FOCUS_DIAGNOSTICS=1`
  - emits `metric=focus_investigation`
- `WORKSPACES_SHEET_DIAGNOSTICS=1`
  - emits `metric=new_workspace_sheet_investigation`
- `./scripts/perf-baseline.sh --launch-mode no-activate|activate`
- `./scripts/new-workspace-perf.sh --launch-mode no-activate|activate`

## Benchmark Summary

### Launch / Repo Focus

| Mode | `launch_to_first_prompt` median | `repo_click_to_focus` median | `repo_hydration` median |
| --- | ---: | ---: | ---: |
| `no-activate` | `2843.13 ms` | `2854.25 ms` | `2.45 ms` |
| `activate` | `3697.77 ms` | `2597.76 ms` | `2.14 ms` |

Readout:

- Activation policy changes the shape of the delay, but does not remove it.
- `repo_hydration` remains small, so startup latency is not explained by repo discovery/import.
- The main regression remains the focus-ready path.

### New Workspace Sheet

| Mode | `new_workspace_sheet_ready` median | `lume_runtime_snapshot_refresh` median | `lume_runtime_host_profile` median |
| --- | ---: | ---: | ---: |
| `no-activate` | `2287.82 ms` | `197.28 ms` | `116.73 ms` |
| `activate` | `1485.90 ms` | `214.76 ms` | `116.18 ms` |

Readout:

- Lume runtime snapshot cost is measurable but not dominant.
- The sheet-open path is much slower than the Lume snapshot itself, so most of the user-visible delay sits outside the Lume command timings.

## Coupling Map

Lume is still structurally coupled into core flows:

1. Live app dependencies always resolve Lume at startup via `AppRuntimeDependencies`.
   - `Sources/WorkspaceManager/App/AppRuntimeDependencies.swift`
2. The default provider registry always includes `LumeWorkspaceProvider`.
   - `Sources/WorkspaceManagerCore/Services/WorkspaceProviders.swift`
3. Opening New Workspace from landing awaits provider availability and a Lume runtime snapshot before setting sheet state.
   - `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift`
4. Opening New Workspace from the sidebar does the same.
   - `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift`
5. The sheet options model directly bakes Lume-derived availability/status into the option list.
   - `Sources/WorkspaceManager/Views/MainWindow/WorkspaceEnvironmentOptionsController.swift`

Implication:

- Even if Lume becomes optional or is removed entirely later, the current UI structure still treats it as part of the default sheet-open readiness path.

## Key Findings

### 1. Repo-click latency is not caused by slow surface creation

From the focused one-run traces:

| Mode | Click -> surface created | Click -> target terminal resolved | Click -> focus success |
| --- | ---: | ---: | ---: |
| `no-activate` | `51 ms` | `1156 ms` | `1930 ms` |
| `activate` | `39 ms` | `1733 ms` | `1734 ms` |

Interpretation:

- The target `GhosttySurfaceView` is created quickly.
- The large delay is between surface creation and the delayed retry/focus handoff running on the main actor.
- This points to main-actor starvation or scheduling delay after surface creation, not to surface instantiation itself.

Evidence:

- `/tmp/workspaces-perf-baseline-20260316-013107/run-1.log`
- `/tmp/workspaces-perf-baseline-20260316-013122/run-1.log`

### 2. The 150ms retry is firing far later than intended

`ContentView` schedules a retry after `0.15s`, but in the traced runs the second focus attempt did not run until roughly `1.1s` to `1.7s` after the repo click.

Interpretation:

- The retry policy itself is not the whole issue.
- Something is delaying main-queue work after the session/surface handoff.

### 3. New Workspace delay is not mostly Lume runtime cost

Representative traced run timings:

#### `no-activate`

- Start -> provider refresh completed: `1483 ms`
- Provider refresh completed -> snapshot refresh completed: `378 ms`
- Snapshot refresh completed -> runtime refresh completed on main actor: `474 ms`
- Runtime refresh completed -> sheet appeared: `84 ms`

#### `activate`

- Start -> provider refresh completed: `7 ms`
- Provider refresh completed -> snapshot refresh completed: `215 ms`
- Snapshot refresh completed -> runtime refresh completed on main actor: `579 ms`
- Runtime refresh completed -> sheet appeared: `49 ms`

Interpretation:

- The actual sheet presentation after state is set is fast.
- A large share of the missing time is the handoff back to the main actor after async refresh work, not the sheet UI itself.
- `workspace_provider_availability_refresh` is trivial in both modes, so waiting for it before opening the sheet is architectural coupling without meaningful performance value.

Evidence:

- `/tmp/workspaces-new-workspace-perf-20260316-012749/run-1.log`
- `/tmp/workspaces-new-workspace-perf-20260316-012857/run-1.log`

### 4. Activation mode alone is not a sufficient fix

- `activate` improves `new_workspace_sheet_ready` versus `no-activate`.
- `activate` does not make startup or repo focus fast enough.
- The focus-ready path and the sheet-open path still show delayed main-actor continuation after background work completes.

## Interpretation

There are two related but distinct problems:

1. **Architectural coupling**
   - Lume is still treated as part of default New Workspace readiness, even though it should be optional and potentially removable.

2. **Main-actor starvation**
   - Focus retries and post-refresh UI state application are running far later than their scheduled times.
   - The stall appears after background work completes and after surfaces are created, which points away from pure Lume command cost and toward UI/main-thread contention.

## Recommended Next Actions

1. Remove Lume from the blocking path for opening New Workspace.
   - Open the sheet immediately with core options.
   - Refresh Lume-specific availability/status asynchronously inside the sheet.
2. Split provider responsibilities into core vs optional providers.
   - Local and primary non-Lume flows should not depend on `LumeRuntimeService` or `LumeWorkspaceProvider` readiness.
3. Run one focused main-thread profiling pass on the repo-click path.
   - Target the interval between `surface_store_created` and `coordinator_target_terminal_resolved`.
   - Use `sample` or `xctrace Time Profiler` around launch + first repo auto-selection.
4. Run one focused main-thread profiling pass on New Workspace open.
   - Target the interval between `lume_runtime_snapshot_refresh` completion and `landing_runtime_refresh_completed`.
5. After isolating the main-thread stall, decide whether the fix belongs in:
   - terminal surface lifecycle / view construction
   - focus scheduling and retry structure
   - a broader main-window rendering path

## Decision Boundary

Do not treat Lume command-time improvements alone as sufficient.

The evidence from this pass says:

- Lume should be decoupled from core flows regardless of whether it remains in the product.
- The release-blocking latency is broader than Lume command cost and includes delayed UI/main-actor progression.
