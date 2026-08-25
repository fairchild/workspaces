# Performance Metrics Reference

This page explains what each dashboard metric means, where timing starts/ends, and the runtime flow being measured.

The machine-readable source of truth for scenarios, metric coverage, and budget formulas is:

- `config/performance/contract.json`

Canonical scenarios:

| Scenario | Build Kind | Purpose |
|---|---|---|
| `debug_no_activate` | `debug` | Raw SwiftPM debug startup without app activation; use for branch deltas and trend history, not release signoff |
| `debug_activate` | `debug` | Interactive debug startup timing with normal activation |
| `installed_clean_shell` | `installed` | Packaged-app release signoff with shell init bypassed and bundled Ghostty resources verified |
| `installed_login_shell` | `installed` | Installed-app startup with normal login shell cost included |
| `installed_input_short_capture` | `installed` | Short focused typing capture for input event age and handler timing |
| `main_window_agent_activity_burst` | `debug` | In-process sidebar status aggregation burst for agent activity churn |
| `main_window_session_switcher_snapshot` | `debug` | In-process Session Switcher snapshot construction and query ranking |
| `main_window_workspace_create_ui_stall` | `debug` | New Workspace sheet-open flow, including provider availability and Lume runtime refresh submetrics |
| `main_window_idle_cpu_diagnostics_closed` | `debug` | Debug app idle CPU while the Diagnostics pane is closed |
| `main_window_resident_memory_20_workspaces` | `debug` | Debug app RSS after prewarming 20 retained terminal surfaces |

## Metric Definitions

### `launch_to_first_prompt`

What it measures:
- Time from app launch initialization to the first successful terminal focus (ready for typing).

Start event:
- `PerformanceSignposts.beginLaunchToFirstPromptIfNeeded()` in app launch path.

End event:
- `PerformanceSignposts.endLaunchToFirstPromptIfNeeded(trigger: "terminal_focus")` when focus manager successfully sets terminal first responder.
- Installed no-activation captures may also end when terminal prompt readiness is
  observed through the terminal title path before foreground focus is possible.

Why it matters:
- This is the “is the app immediately usable?” number.

```mermaid
sequenceDiagram
    participant App as "AppDelegate"
    participant Perf as "PerformanceSignposts"
    participant View as "ContentView"
    participant Focus as "TerminalFocusManager"
    participant Term as "GhosttySurfaceView"

    App->>Perf: beginLaunchToFirstPromptIfNeeded()
    App->>View: window + content appears
    View->>Focus: requestFocus(for: terminal)
    Focus->>Term: makeFirstResponder(terminal)
    Focus->>Perf: endLaunchToFirstPromptIfNeeded("terminal_focus")
```

Notes:
- **Three state axes decide what a launch does before the prompt**, and a sample is
  only comparable to another sample that started from the same state.
  `WORKSPACES_DATA_DIR` scopes the SwiftData store and the SQLite sidecar;
  `WORKSPACES_PREFERENCES_SUITE` scopes `UserDefaults`, where the terminal
  continuity manifest lives; the process table decides whether the machine was
  quiet. Before #1258 the preferences axis was uncontrolled, so the debug lanes
  restored whatever sessions the last dev or fixture launch happened to leave
  behind (#1251, #1252).
- **`perf-baseline.sh --preferences`** picks how the preferences axis behaves across
  a run's samples. `clean` (default) wipes the run's scratch suite before every
  sample, so each launch seeds a fresh default-home shell. `carry-over` wipes once
  per invocation, so sample 1 seeds continuity state and samples 2..N restore it —
  the shape the lane had when nothing isolated the domain. Neither mode ever reads
  or writes the developer's own preferences; the suite is named per invocation and
  removed on exit.
- **Each sample carries the branch it took.** `[Perf] event=initial_host_session
  caller=<prologue|sequence> branch=<manifest_restore|fresh_seed|noop>
  sessions=<n>` says which launch path seeded the session and what it seeded, and
  `summary.json` lifts it into `metadata.launch_samples` alongside the duration,
  the 1-minute load average, and the hydration cost that sample paid. Read the
  correlation there rather than inferring the mode from the shape of the
  distribution. `caller` matters because the prologue seeds ahead of SwiftUI's
  first layout pass and the sequence seeds after it (#1276); `branch` matters
  because restoring N sessions is not the same work as seeding one.
- **Isolation fails closed.** A sample whose log has no `[LaunchPreferences]` line,
  or reports the persistent domain, or names a suite other than the one the run
  set, exits the lane non-zero and records nothing. An unknown starting state is
  what this protocol exists to remove, so it is a harness failure rather than a
  slow launch.
- **The lane refuses to measure next to a live instance, and never kills one it
  didn't start.** Each sample checks the process table before and after, and
  aborts when a debug instance from this worktree is running — a `launch-dev.sh`
  app or a concurrent capture is someone's live work. Teardown signals only the
  pid this invocation launched, TERM then KILL (#1277, #1280).
- **`repo_hydration` per sample is also the data-store axis.** `WORKSPACES_DATA_DIR`
  is shared by every sample in one invocation and is not reset between them, so
  sample 1 imports the discovered repos and samples 2..N open a populated store.
  That is deliberate — it is the protocol the 2026-06-08 reference was captured
  under — but it means `--preferences clean` says nothing about the store, and the
  per-sample hydration cost is what makes the difference visible.
- **History rows carry a `protocol_epoch`.** Rows from before the isolated protocol
  are `legacy-unisolated`; the isolated lane recorded `isolated-preferences-v1`;
  rows from 2026-08-23 on are `deterministic-delivery-v1`. Dashboard deltas only
  compare within one scenario and epoch, and `perf-compare.py` warns when a
  comparison spans either boundary, so a protocol change is never rendered as an
  app-side regression.
- **Why the second boundary exists — this metric could stop early.** Until #1251,
  libghostty occasionally raised the shell signal that closes the interval *inline
  on the main thread*, from inside a call the app made during first-window bring-up.
  Those samples closed while the main thread was still hundreds of milliseconds from
  servicing anything, and they read as the fast mode of a bimodal distribution rather
  than as a defect — which is why the retired 592 ms reference looked achievable for
  three investigation passes. The wakeup tick now always enqueues, so every sample
  closes at main-drain. Treat a suspiciously fast launch sample as a measurement
  question first: `WORKSPACES_TERMINAL_DIAGNOSTICS=1` arms `LaunchWindowProbe`, whose
  main-queue heartbeat says independently whether the app was actually servicing work
  when the metric stopped.

### `repo_hydration`

What it measures:
- Time spent auto-discovering repositories under `~/code` and importing any missing repo entries into model state.

Start event:
- `PerformanceSignposts.beginRepoHydration(rootPath:)` before discovery.

End event:
- `PerformanceSignposts.endRepoHydrationIfNeeded(discoveredCount:importedCount:)` after discovery + import pass completes.

Why it matters:
- It captures startup portfolio load cost.

```mermaid
sequenceDiagram
    participant Sidebar as "SidebarView"
    participant Perf as "PerformanceSignposts"
    participant Discovery as "RepositoryDiscovery"
    participant Model as "SwiftData ModelContext"

    Sidebar->>Perf: beginRepoHydration(root=~/code)
    Sidebar->>Discovery: discoverGitRepositories(in: ~/code)
    Discovery-->>Sidebar: discovered repo URLs
    Sidebar->>Model: insert missing repos + save
    Sidebar->>Perf: endRepoHydrationIfNeeded(discovered, imported)
```

### `repo_click_to_focus`

What it measures:
- Time from selecting a repo row to terminal focus being restored for that repo session.

Start event:
- `PerformanceSignposts.beginRepoClickToFocusedInput(sessionID:repoPath:)` in `handleRepoSelection`.

End event:
- `PerformanceSignposts.endRepoClickToFocusedInputIfNeeded(...)` when focus callback confirms terminal became first responder.

Why it matters:
- It reflects interaction responsiveness during context switching.

Notes:
- Current flow uses immediate focus request plus a short retry; a successful
  restore ends with outcome `focused` (or `prompt_ready` via the terminal
  readiness signal).
- Only `outcome=prompt_ready` and `outcome=focused` are measured latency. Any
  other termination (user navigated away, selection superseded) is an abandoned
  interval: the cancel path logs `status=abandoned elapsed_ms=...` instead of
  `duration_ms=...`, and `perf-baseline.sh` additionally allowlists the success
  outcomes so abandoned idle time can never enter the median/mean pool.
- `debug_no_activate` intentionally does not gate this metric. Shared-desktop
  no-activation mode skips foreground focus, and automation can reuse a
  prompt-ready terminal before the repo-selection timer has a foreground focus
  callback to complete. Use `debug_activate` when validating repo-switch focus
  timing.

```mermaid
sequenceDiagram
    actor User
    participant Sidebar as "SidebarView"
    participant Content as "ContentView"
    participant Session as "TileTreeStore"
    participant Perf as "PerformanceSignposts"
    participant Focus as "TerminalFocusManager"
    participant Term as "GhosttySurfaceView"

    User->>Sidebar: click repo row
    Sidebar->>Content: onRepoSelected(repo)
    Content->>Session: activateSession(repoPath)
    Content->>Perf: beginRepoClickToFocusedInput(sessionID, path)
    Content->>Focus: requestFocus(targetSession terminal)
    Focus->>Term: makeFirstResponder(terminal)
    Focus-->>Content: onFocused callback
    Content->>Perf: endRepoClickToFocusedInputIfNeeded(outcome)
```

### `workspace_click_to_focus`

What it measures:
- Time from selecting a workspace row to terminal focus being restored for that workspace session.

Start event:
- `PerformanceSignposts.beginWorkspaceClickToFocusedInput(sessionID:workspacePath:)` in `handleWorkspaceSelection`.

End event:
- `PerformanceSignposts.endWorkspaceClickToFocusedInputIfNeeded(...)` when focus callback confirms terminal became first responder.

Why it matters:
- It reflects interaction responsiveness when switching between workspaces, analogous to `repo_click_to_focus` for repo switches.

Sub-spans (emitted via `InvestigationDiagnostics.emitFocus`):
- `focus_surface_resolution` — from `requestMainTerminalFocus` call to terminal resolved from `surfaceStore.terminal(for:)`
- `focus_request_to_first_responder` — from `TerminalFocusManager.requestFocus()` call to `makeFirstResponder` success

Notes:
- Mirrors the `repo_click_to_focus` pattern exactly, including abandonment
  semantics: only `outcome=prompt_ready` / `outcome=focused` intervals carry
  `duration_ms`; cancelled or superseded intervals log
  `status=abandoned elapsed_ms=...` and are excluded from latency summaries.
- `debug_no_activate` intentionally does not gate this metric. Shared-desktop
  no-activation mode skips foreground focus, and automation can reuse a
  prompt-ready terminal before the workspace-selection timer has a foreground
  focus callback to complete. Use `debug_activate` when validating workspace
  switch focus timing.

```mermaid
sequenceDiagram
    actor User
    participant Sidebar as "SidebarView"
    participant Content as "ContentView"
    participant Session as "TileTreeStore"
    participant Perf as "PerformanceSignposts"
    participant Coord as "TerminalFocusCoordinator"
    participant Focus as "TerminalFocusManager"
    participant Term as "GhosttySurfaceView"

    User->>Sidebar: click workspace row
    Sidebar->>Content: onWorkspaceSelected(workspace)
    Content->>Session: activateSession(workspacePath)
    Content->>Perf: beginWorkspaceClickToFocusedInput(sessionID, path)
    Content->>Coord: requestMainTerminalFocus(targetSession)
    Note over Coord: sub-span: focus_surface_resolution
    Coord->>Focus: requestFocus(for: terminal)
    Note over Focus: sub-span: focus_request_to_first_responder
    Focus->>Term: makeFirstResponder(terminal)
    Focus-->>Content: onFocused callback
    Content->>Perf: endWorkspaceClickToFocusedInputIfNeeded(outcome)
```

### `new_workspace_sheet_ready`

What it measures:
- Time from a user-initiated New Workspace action to the sheet being ready for interaction after provider/runtime refresh work finishes.

Start event:
- `PerformanceSignposts.beginNewWorkspaceSheetReady(trigger:)` at the two production entry points:
  - `SidebarView.prepareNewWorkspaceSheet(for:)`
  - `ContentView.presentNewWorkspaceFromLanding(_:)`

End event:
- `PerformanceSignposts.endNewWorkspaceSheetReadyIfNeeded(attemptID:outcome:)` after the environment options refresh work completes and the sheet presentation state is set.

Why it matters:
- This isolates the deferred cost that was moved off app launch so startup can stay responsive without hiding the user-facing cost of opening the sheet.

Trigger field:
- `trigger=sidebar|landing`

Outcome field:
- `outcome=success|superseded`
- `superseded` means a second sheet-open attempt replaced the first before the first one completed; the old interval is closed and should not be treated as a successful ready signal.

Notes:
- This metric is intentionally not in `metrics-history.csv` or the shared dashboard yet. Use the dedicated benchmark script and dated reports until the signal proves stable enough to gate routinely.

```mermaid
sequenceDiagram
    actor User
    participant Sidebar as "Sidebar or Landing UI"
    participant Perf as "PerformanceSignposts"
    participant Options as "WorkspaceEnvironmentOptionsController"
    participant Lume as "LumeRuntimeService"
    participant Sheet as "NewWorkspaceSheet"

    User->>Sidebar: Open New Workspace
    Sidebar->>Perf: beginNewWorkspaceSheetReady(trigger)
    Sidebar->>Options: refresh provider availability
    Options-->>Sidebar: providers ready
    Sidebar->>Lume: snapshot()
    Lume-->>Sidebar: runtime snapshot ready
    Sidebar->>Sheet: set sheet presentation state
    Sidebar->>Perf: endNewWorkspaceSheetReadyIfNeeded(outcome=success)
```

### `main_window_agent_activity_burst_sidebar_latency_ms`

What it measures:
- Time spent rebuilding sidebar agent-status inputs and updating `WorkspaceStatusAggregator` for a bursty main-window workload.

Scenario:
- `main_window_agent_activity_burst`

Why it matters:
- It guards the path that refires when agent session status changes, where repeated sidebar refresh work can become visible during active agent sessions.

### `main_window_attention_dropdown_resolution_ms`

What it measures:
- Time spent resolving `WorkspaceStatusAggregator.attentionItems` into the concise rows used by the top-right "Needs You" dropdown.

Scenario:
- `main_window_agent_activity_burst`

Why it matters:
- It guards the click-prep path for the notification bubble so the dropdown stays cheap even when agent status changes rapidly across many tabs.

### `main_window_session_switcher_snapshot_ms`

What it measures:
- Time spent building Session Switcher rows from already-loaded repos, web sources, host sessions, pane counts, and agent statuses, then filtering/ranking them for a query.

Scenario:
- `main_window_session_switcher_snapshot`

Why it matters:
- It keeps Cmd-P opening and search responsive as live agent/session metadata grows.

### `workspace_provider_availability_refresh`

What it measures:
- The provider availability refresh span emitted while preparing the New Workspace sheet.

Scenario:
- `main_window_workspace_create_ui_stall`

Why it matters:
- It separates provider option refresh cost from the final sheet-ready marker.

### `lume_runtime_snapshot_refresh`

What it measures:
- The Lume runtime snapshot refresh span used while preparing New Workspace environment options.

Scenario:
- `main_window_workspace_create_ui_stall`

Why it matters:
- It captures the deferred runtime-readiness work that can make workspace creation feel stalled even when the final sheet presentation marker is short.

### `main_window_idle_cpu_diagnostics_closed_percent`

What it measures:
- `WorkspaceManager` process CPU percent sampled from the debug app while the Diagnostics pane is closed.

Scenario:
- `main_window_idle_cpu_diagnostics_closed`

Why it matters:
- It verifies that diagnostics sampling and ordinary idle work stay quiet during sustained sessions when the diagnostics UI is not visible.

### `main_window_resident_memory_20_workspaces_mb`

What it measures:
- `WorkspaceManager` process RSS after the debug app prewarms and retains 20 terminal surfaces.

Scenario:
- `main_window_resident_memory_20_workspaces`

Why it matters:
- It establishes a contract around retained terminal surface memory before adding any eviction or suspension policy.

### `open_in_editor_launch`

What it measures:
- Time from `Open in Editor` invocation to editor process launch return (`Process.run()` success or failure).

Start event:
- `PerformanceSignposts.beginOpenInEditorLaunch(...)` in `OpenInEditorShortcutFlow.perform(...)`.

End event:
- `PerformanceSignposts.endOpenInEditorLaunchIfNeeded(...)` on launch success or failure.

Why it matters:
- This is the user-facing latency for the `Cmd+Shift+O` hero flow.
- It also records guardrail outcomes for launch failures with categorized reasons.

Outcome + guardrail fields:
- `outcome=success|failure`
- `failure_reason` (only when `outcome=failure`):
  - `project_root_not_found`
  - `file_not_found`
  - `file_outside_project`
  - `editor_not_installed`
  - `editor_cli_unavailable`
  - `launch_failed`
  - `unexpected_error`

Trigger field:
- `trigger=shortcut|uiPrimaryAction|uiMenuSelection|unknown`

```mermaid
sequenceDiagram
    actor User
    participant View as "ContentView"
    participant Flow as "OpenInEditorShortcutFlow"
    participant Perf as "PerformanceSignposts"
    participant Editor as "ExternalEditorService"

    User->>View: Cmd+Shift+O (or Open control)
    View->>Flow: perform(target, editor, trigger)
    Flow->>Perf: beginOpenInEditorLaunch(...)
    Flow->>Editor: open(projectRoot, file?, editor)
    alt Launch succeeds
        Flow->>Perf: endOpenInEditorLaunchIfNeeded(outcome=success)
    else Guardrail / launch failure
        Flow->>Perf: endOpenInEditorLaunchIfNeeded(outcome=failure, failure_reason=...)
    end
```

## Budget Contract

Budgets are derived from the reference baselines in `config/performance/contract.json` using one formula everywhere:

- gate budget: `ceil(reference median * 1.25)`
- diagnostic threshold: `ceil(reference p95 * 1.5)`

Rules:

- median is the gating statistic
- p95 is diagnostic and should trigger investigation even when median still passes
- existing `[Perf]` metric names remain the raw telemetry source; contract logic sits above them
- debug scenario budgets are release-advisory only; a debug failure does not
  block a release when installed-build verification passes and the difference is
  classified in the release notes or PR context

Enforcement points:

- `./scripts/perf-baseline.sh --assert-budget`
- `./scripts/perf-runner.sh --scenario <id> --assert-budget`

Both run on the owner's laptop, opt-in per approved session — budgets are
`Mac16,13`-derived, so nothing off-host may assert them. No CI workflow enforces
them; see [../decisions/perf-measurement-laptop-optin.md](../decisions/perf-measurement-laptop-optin.md).

Release signoff uses installed-build verification:

- `./scripts/verify-release-bundle.sh`
- `./scripts/verify-installed-perf.sh`

`verify-installed-perf.sh` must confirm bundled Ghostty resources, bundled
terminfo, `terminal_first_output`, and `first_prompt_ready`. These installed
metrics are the release-relevant signal for packaged app startup.

## Interpreting Dashboard Changes

1. Small run-to-run movement is normal (scheduler/window focus variance).
2. Regressions to investigate:
- sustained increases over multiple recorded runs
- crossing target thresholds
- sudden jump with no corresponding product change
3. Compare with context:
- repo count discovered/imported
- machine and OS build
- run settings (`runs`, `sleep`)
