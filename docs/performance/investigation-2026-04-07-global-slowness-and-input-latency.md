# Investigation: Global Slowness And Input Latency

Date: 2026-04-07
Branch: `codex/workspaces-perf-optimization`
Status: active

## Goal

Find and fix the root cause of broad Workspaces UI slowness.

Reported symptoms:

- slow launch and long beachballs
- typing lag in the embedded terminal
- slow menu interactions, including Help menu clicks
- worse behavior on one target machine, but reproducible locally as well

## Current Read

The current evidence does not support "slow shell startup" as the primary cause.

The strongest signals point to:

1. input events arriving at the app very late
2. focus restoration repeatedly losing the target terminal/window
3. expensive SwiftUI/AppKit layout work in sidebar/menu row rendering during lag
4. dynamic toolbar bridge rebuilds during layout, especially after the first sidebar fix reduced row churn
5. intermittent residual spikes that now look more like SwiftUI preference/focus churn than shell or Ghostty work

## Baseline Evidence

### Local host probe

Artifact:

- `/tmp/workspaces-host-probe-local-20260407/summary.txt`

Key numbers:

- login shell median: `71-80 ms`
- clean shell median: `3-6 ms`
- finding: no strong shell-startup anomaly detected

Interpretation:

- local slowness is not explained by login shell startup cost

### Installed app input diagnostics, clean shell

Artifact:

- `/tmp/workspaces-local-input-diag-single-20260407.log`

Key numbers:

- `terminal_investigation.surface_create_succeeded`: `29.80 ms`
- `input_investigation.event_age_ms`: min `1117.16 ms`, median `1198.85 ms`, max `2480.36 ms`
- `input_investigation.handler_duration_ms`: min `0.10 ms`, median `0.16 ms`, max `1.07 ms`
- `workspace_click_to_focus`: `36566.90 ms`, outcome `repo_overview_selected`

Interpretation:

- terminal surface creation is fast
- key events are arriving stale
- the app is not spending seconds inside the key handler
- focus restoration is failing badly enough to leave a click-to-focus span open for ~36.6s

### Focus failure markers

Artifact:

- `/tmp/workspaces-local-input-diag-single-20260407.log`

Observed markers:

- `focus_request_inactive_skip`
- `focus_request_missing_window_retry`
- `focus_request_missing_window_terminal_lost`
- `coordinator_pending_request_cancelled reason=repo_overview_selected`

Interpretation:

- focus routing and target resolution are unstable under the slow path

### Active lag sample, clean single-process run

Artifacts:

- `/tmp/workspaces-active-lag-single-20260407/sample-app-94289.txt`
- `/tmp/workspaces-active-lag-single-20260407/sample-child-97801.txt`

Observed app-side pattern:

- main thread heavily sampled in AppKit / SwiftUI display and layout work
- stacks go through `NSAnimationManager`, `NSHostingView.layout`, and `SidebarRows.swift`
- menu/help construction also appears in the hot path

Observed shell-side pattern:

- shell mostly blocked in `read`

Interpretation:

- current local lag is not a shell execution bottleneck
- UI/layout churn is a credible root contributor

### Debug build re-measure after repo-row churn reduction

Artifacts:

- `/tmp/workspaces-debug-input-diag-exp0006-20260407.log`
- `/tmp/workspaces-debug-active-lag-exp0006-20260407/sample-app-59644.txt`
- `/tmp/workspaces-debug-active-lag-exp0006-20260407/sample-child-60155.txt`

Key numbers:

- `input_investigation.event_age_ms`: min `1.16 ms`, median `17.47 ms`, max `219.34 ms`
- `input_investigation.handler_duration_ms`: min `0.06 ms`, median `0.20 ms`, max `7.43 ms`
- `workspace_click_to_focus`: `5870.88 ms`, outcome `focused`

Observed focus markers:

- repeated `focus_request_make_first_responder`
- repeated `focus_request_succeeded`
- a later `focus_request_missing_window_retry` and `focus_request_missing_window_terminal_lost` after unrelated sheet / Lume activity

Observed app-side sample pattern:

- the old direct `SidebarRows.swift`, `Menu.init`, and `View.help` signatures dropped out of the first pass grep
- `NSHostingView.layout` and `NSAnimationManager` remain present
- the strongest surviving high-count stack goes through SwiftUI `ToolbarBridge.preferencesDidChange` and `ToolbarBridge.updateStorage`

Interpretation:

- the first repo-row change materially improved key delivery
- sidebar churn was a real contributor, not just noise
- the problem is not fully fixed
- remaining slowness appears to involve broader SwiftUI/AppKit layout, with toolbar rebuilds as the next likely optimization target

### Clean-shell toolbar A/B

Artifacts:

- `/tmp/workspaces-exp0007-clean-control-summary.txt`
- `/tmp/workspaces-exp0007-clean-minimal-toolbar-summary.txt`
- `.dev-data/logs/launch-dev-20260408-000649.log`
- `.dev-data/logs/launch-dev-20260408-000722.log`

Interaction pattern:

- same debug build
- same clean-shell mode
- same auto-select-first-repo launch
- same automated terminal click
- same typed input sequence: `date`, `ls`, `clear`

Control result with normal toolbar:

- `input_investigation.event_age_ms`: min `5.36 ms`, median `60.81 ms`, max `897.08 ms`
- `repo_click_to_focus`: `3885.80 ms`
- `launch_to_first_prompt`: `5853.95 ms`

Variant result with `WORKSPACES_PERF_MINIMAL_TOOLBAR=1`:

- `input_investigation.event_age_ms`: min `3.29 ms`, median `25.36 ms`, max `54.71 ms`
- `repo_click_to_focus`: `1220.58 ms`
- `launch_to_first_prompt`: `4480.47 ms`

Interpretation:

- removing toolbar content materially improved responsiveness under the same interaction sequence
- the remaining lag is not explained by the terminal key handler itself, which stayed sub-millisecond
- dynamic toolbar composition is now a high-confidence contributor to the broad UI slowness

### Post-prompt toolbar refinement results

Artifacts:

- `/tmp/workspaces-exp0008-postprompt-stable-summary.txt`
- `/tmp/workspaces-exp0008-postprompt-minimal-summary.txt`
- `/tmp/workspaces-exp0009-no-context-toolbar-summary.txt`
- `.dev-data/logs/launch-dev-20260408-001254.log`
- `.dev-data/logs/launch-dev-20260408-001326.log`
- `.dev-data/logs/launch-dev-20260408-001558.log`

Interaction pattern:

- same debug build
- same clean-shell mode
- same auto-select-first-repo launch
- waited for `launch_to_first_prompt` to appear in the log before sending input
- same automated terminal click
- same typed input sequence: `date`, `ls`, `clear`

Variant results:

- stable contextual actions toolbar item:
  - `event_age_ms` median `284.48 ms`, max `571.51 ms`
  - `repo_click_to_focus` `1402.38 ms`
  - `launch_to_first_prompt` `5231.20 ms`
- minimal toolbar:
  - `event_age_ms` median `11.10 ms`, max `46.10 ms`
  - `repo_click_to_focus` `1170.99 ms`
  - `launch_to_first_prompt` `4044.79 ms`
- no contextual toolbar item, but rest of toolbar intact:
  - `event_age_ms` median `18.77 ms`, max `188.06 ms`
  - `repo_click_to_focus` `1158.80 ms`
  - `launch_to_first_prompt` `4512.09 ms`

Interpretation:

- a stable replacement menu in the toolbar was still too expensive
- the problem is not “any toolbar at all”
- the contextual actions item in the toolbar is the high-value offender
- removing just that item preserves most of the minimal-toolbar performance win

### Current-branch validation after the command-menu re-home

Artifacts:

- `/tmp/workspaces-exp0011-postprompt/summary.txt`
- `.dev-data/logs/launch-dev-20260408-073545.log`
- `/tmp/workspaces-exp0011-active-lag/samples/summary.txt`
- `/tmp/workspaces-exp0011-active-lag/samples/sample-app-89332.txt`
- `/tmp/workspaces-exp0011-active-lag/samples/sample-child-89355.txt`
- `/tmp/workspaces-exp0011-active-lag/samples/sample-child-89472.txt`
- `.dev-data/logs/launch-dev-20260408-073357.log`

Key numbers from the corrected clean-shell post-prompt run:

- `input_investigation.event_age_ms`: min `0.95 ms`, median `3.40 ms`, max `476.70 ms`, mean `133.90 ms`
- `input_investigation.handler_duration_ms`: min `0.06 ms`, median `0.11 ms`, max `0.96 ms`
- `repo_click_to_focus`: `1031.94 ms`
- `launch_to_first_prompt`: `3621.46 ms`

Observed fresh active-lag sample pattern on the same build:

- shell remained blocked in `read`
- app main thread still concentrated in:
  - `NSHostingView.layout`
  - `NSHostingView.preferencesDidChange`
  - `AppWindowsController.updateWindowFocus`
  - `ToolbarBridge.preferencesDidChange`
  - `RepoRow.body`

Interpretation:

- on the current branch, median input delivery during a corrected post-prompt run is now fast
- the key handler is still not the problem
- the remaining issue is intermittent UI spikes, with current evidence pointing at SwiftUI preference and focus churn plus residual sidebar row work

## Important Session Finding

Before the clean rerun, there were two installed `WorkspaceManager` processes alive at once:

- `22196`
- `90618`

That state was cleared manually before the clean diagnostic rerun. It is a confounder worth watching, but it does not explain the full issue because the slowdown remained after returning to a single process.

## Ranked Hypotheses

### H1. Focus/window restoration is leaving input events queued before they ever reach the terminal view

Why it fits:

- stale `event_age_ms`
- repeated `focus_request_missing_window_*`
- long `workspace_click_to_focus`

Primary code:

- `Sources/WorkspaceManager/Controllers/TerminalWindowController.swift`
- `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`

### H2. Sidebar row hover/menu/help rendering is causing expensive layout and animation churn on the main thread

Why it fits:

- sample shows `NSAnimationManager` and `NSHostingView.layout`
- stacks point into `SidebarRows.swift`
- sample includes `View.help` and `Menu.init`

Primary code:

- `Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift`

### H2b. Dynamic toolbar content is being rebuilt too often during view updates

Why it fits:

- post-change sample still shows heavy `NSHostingView.layout`
- surviving stack now runs through SwiftUI `ToolbarBridge.preferencesDidChange`
- clean-shell A/B improved responsiveness substantially when toolbars were removed
- the app is reported as slow even outside terminal typing, including menu interactions

Primary code:

- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift`
- `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift`
- `Sources/WorkspaceManager/Views/Components/WorkspaceEditorToolbarButton.swift`

### H2c. Focused scene values and related SwiftUI window preference updates are still expensive under live interaction

Why it fits:

- fresh active-lag sample still shows `NSHostingView.preferencesDidChange`
- sample still shows `AppWindowsController.updateWindowFocus`
- sample still shows `ToolbarBridge.preferencesDidChange` even after removing the contextual toolbar item
- the latest corrected post-prompt run is good on median input latency but still has occasional large spikes

Primary code:

- `Sources/WorkspaceManager/App/WorkspaceManagerApp.swift`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift`

### H3. Shortcut/local-event routing may be amplifying focus churn, but is probably not the primary root cause

Why it is still plausible:

- app has custom Ghostty-first shortcut routing
- a local event monitor is installed on each terminal surface
- user suspicion is specifically around shortcut pass-through work

Why it is not ranked first:

- menu/help slowness is broader than terminal shortcut handling
- shell samples are idle
- current hottest stack is layout/display rather than shortcut encoding

Primary code:

- `Sources/WorkspaceManager/Terminal/GhosttySurfaceInputRouter.swift`
- `Sources/WorkspaceManager/App/ShortcutRoutingPolicy.swift`

## Excluded Or Deprioritized Causes

- shell startup as the primary local cause
- Ghostty surface creation latency as the primary local cause
- child shell execution as the primary local cause

## Next Experiments

1. Reduce the remaining sidebar row and preference churn that still appears in `RepoRow.body`, `View.help`, and `ToolbarBridge`.
2. Separate focused-scene-value cost from toolbar bridge cost so the next command-surface choice is evidence-based.
3. Re-measure:
   - corrected clean-shell post-prompt input diagnostics
   - active-lag sample
   - focus spans
4. Only if the SwiftUI-side reductions stop helping, instrument shortcut/local-event routing more deeply:
   - local event monitor entry/exit
   - `performKeyEquivalent`
   - first-responder transitions around focus restore
5. If focus loss remains after UI churn drops further, narrow in on `TerminalWindowController` / surface-store timing.

## Success Criteria

We should consider the first pass successful when local runs show:

- `input_investigation.event_age_ms` reduced from ~`1.2-2.5s` to low double-digit milliseconds
- corrected post-prompt reruns stay low without occasional 400ms+ spikes
- `workspace_click_to_focus` no longer stalls in the seconds range during normal repo/session selection
- no repeated `focus_request_missing_window_terminal_lost` during normal selection and typing
- subjective menu and terminal interactions feel immediate
