# Experiment Log: Global Slowness And Input Latency

Date: 2026-04-07
Branch: `codex/workspaces-perf-optimization`

Use this file as the append-only experiment log for this investigation.

## Baseline

### EXP-0001: Local active-lag capture against installed app

Status: complete

Setup:

- captured live lag against installed `WorkspaceManager`
- target app PID: `22196`

Artifacts:

- `/tmp/workspaces-active-lag-local-20260407/summary.txt`
- `/tmp/workspaces-active-lag-local-20260407/sample-app-22196.txt`
- `/tmp/workspaces-active-lag-local-20260407/sample-child-22307.txt`

Result:

- app sample succeeded
- shell sample succeeded
- shell was idle in `read`
- app main thread mostly parked in normal event loop with some render/transaction work

Takeaway:

- this did not implicate the child shell

### EXP-0002: Local host probe across repo, worktree, and home

Status: complete

Setup:

- ran `host_perf_probe.py`
- directories:
  - `/Users/fairchild/code/workspaces`
  - `/Users/fairchild/.worktrees/workspaces/codex/workspaces-perf-optimization`
  - `/Users/fairchild`

Artifacts:

- `/tmp/workspaces-host-probe-local-20260407/summary.txt`

Result:

- login shell median: `71-80 ms`
- clean shell median: `3-6 ms`
- no strong shell-startup anomaly

Takeaway:

- shell startup is not the primary local bottleneck

### EXP-0003: Installed app clean-shell input diagnostics, contaminated by duplicate app processes

Status: complete

Setup:

- attempted clean-shell installed diagnostics with input logging

Finding:

- two installed `WorkspaceManager` processes were alive simultaneously:
  - `22196`
  - `90618`

Takeaway:

- duplicate app state can contaminate measurements and should be cleared before any rerun

### EXP-0004: Installed app clean-shell input diagnostics after clearing duplicate processes

Status: complete

Setup:

- killed all installed `WorkspaceManager` processes
- relaunched installed app with:
  - `WORKSPACES_FOCUS_DIAGNOSTICS=1`
  - `WORKSPACES_TERMINAL_DIAGNOSTICS=1`
  - `WORKSPACES_INPUT_DIAGNOSTICS=1`
  - `WORKSPACES_SHELL_PROFILE_MODE=clean`

Artifacts:

- `/tmp/workspaces-local-input-diag-single-20260407.log`

Result:

- `surface_create_succeeded`: `29.80 ms`
- `input event_age_ms`: median `1198.85 ms`, max `2480.36 ms`
- `handler_duration_ms`: median `0.16 ms`, max `1.07 ms`
- `workspace_click_to_focus`: `36566.90 ms`, outcome `repo_overview_selected`
- focus failure markers observed:
  - `focus_request_inactive_skip`
  - `focus_request_missing_window_retry`
  - `focus_request_missing_window_terminal_lost`

Takeaway:

- the app is receiving key events late, not handling them slowly
- focus restore instability is a core part of the stall

### EXP-0005: Clean single-process active-lag sample

Status: complete

Setup:

- captured fresh active-lag sample against clean single-process run
- target app PID: `94289`

Artifacts:

- `/tmp/workspaces-active-lag-single-20260407/sample-app-94289.txt`
- `/tmp/workspaces-active-lag-single-20260407/sample-child-97801.txt`

Result:

- shell still idle in `read`
- app sample hot path includes:
  - `NSAnimationManager`
  - `NSHostingView.layout`
  - `SidebarRows.swift`
  - `View.help`
  - `Menu.init`

Takeaway:

- sidebar/menu/help layout is a strong next optimization target

### EXP-0006: Reduce repo-row hover/menu/layout churn

Status: complete

Hypothesis:

- repo row hover animation and hidden quick-action menu construction are causing avoidable layout/display churn on the main thread

Change:

- remove or reduce hover animation
- avoid constructing quick action menu when hidden
- reduce repeated dynamic property reads during row rendering

Implementation notes:

- patched `Sources/WorkspaceManager/Views/MainWindow/SidebarRows.swift`
- removed `withAnimation(.easeInOut(duration: 0.12))` from repo-row hover handling
- replaced always-built hidden quick-action menu with a fixed-size placeholder when not hovering
- hoisted `repo.name` and related label text into local body constants to reduce repeated reads per render pass

Artifacts:

- `/tmp/workspaces-debug-input-diag-exp0006-20260407.log`
- `/tmp/workspaces-debug-active-lag-exp0006-20260407/sample-app-59644.txt`
- `/tmp/workspaces-debug-active-lag-exp0006-20260407/sample-child-60155.txt`

Result:

- `input event_age_ms`: median improved from `1198.85 ms` to `17.47 ms`
- `input event_age_ms` max improved from `2480.36 ms` to `219.34 ms`
- `handler_duration_ms`: median `0.20 ms`, max `7.43 ms`
- `workspace_click_to_focus`: improved from `36566.90 ms` with `repo_overview_selected` to `5870.88 ms` with `focused`
- first-pass grep of the new app sample no longer surfaced:
  - `SidebarRows.swift`
  - `Menu.init`
  - `View.help`
- remaining hot sample stacks still show:
  - `NSHostingView.layout`
  - `NSAnimationManager`
  - SwiftUI `ToolbarBridge.preferencesDidChange`
  - SwiftUI `ToolbarBridge.updateStorage`
- later in the session, after unrelated sheet / Lume activity, focus failure markers still reappeared:
  - `focus_request_missing_window_retry`
  - `focus_request_missing_window_terminal_lost`

Takeaway:

- repo-row hover/menu churn was a real contributor
- the change produced a large quantitative improvement in event delivery
- the remaining issue appears broader than the sidebar row itself
- toolbar/layout churn is the next best local optimization target

## Planned

### EXP-0007: Reduce toolbar bridge churn during selection and terminal updates

Status: complete

Hypothesis:

- dynamic toolbar content in `ContentView` and related views is being rebuilt too often, causing additional SwiftUI/AppKit layout and animation work even when terminal handling itself is fast

Change:

- added `PerformanceExperimentFlags.minimalToolbar`
- gated both `ContentView` and `SidebarView` toolbars behind `WORKSPACES_PERF_MINIMAL_TOOLBAR=1`
- used the flag as a measurement-only A/B switch rather than a product decision

Artifacts:

- `/tmp/workspaces-exp0007-clean-control-summary.txt`
- `/tmp/workspaces-exp0007-clean-minimal-toolbar-summary.txt`
- `.dev-data/logs/launch-dev-20260408-000649.log`
- `.dev-data/logs/launch-dev-20260408-000722.log`

Setup:

- same debug build
- same clean-shell mode
- same `WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1` launch
- same automated terminal focus click
- same typed input sequence:
  - `date`
  - `ls`
  - `clear`

Result:

- normal toolbar:
  - `event_age_ms` median `60.81 ms`, max `897.08 ms`
  - `repo_click_to_focus` `3885.80 ms`
  - `launch_to_first_prompt` `5853.95 ms`
- minimal toolbar:
  - `event_age_ms` median `25.36 ms`, max `54.71 ms`
  - `repo_click_to_focus` `1220.58 ms`
  - `launch_to_first_prompt` `4480.47 ms`

Takeaway:

- removing toolbar content produced a strong quantitative improvement
- toolbar composition is a real contributor to the remaining app-wide slowness
- the next step should be a production-safe way to keep toolbar structure stable without removing important actions entirely

### EXP-0008: Replace dynamic toolbar item sets with a stable contextual actions control

Status: complete

Hypothesis:

- the toolbar cost is driven more by structural churn in SwiftUI toolbar items than by the mere presence of a toolbar
- replacing the changing item set with one stable contextual actions control should preserve functionality while keeping most of the performance win from minimal-toolbar mode

Change:

- introduced a stable single-item contextual actions menu experiment in the toolbar
- measured with a corrected post-prompt harness that waits for `launch_to_first_prompt` before sending input

Artifacts:

- `/tmp/workspaces-exp0008-postprompt-stable-summary.txt`
- `/tmp/workspaces-exp0008-postprompt-minimal-summary.txt`
- `.dev-data/logs/launch-dev-20260408-001254.log`
- `.dev-data/logs/launch-dev-20260408-001326.log`

Result:

- stable contextual toolbar item:
  - `event_age_ms` median `284.48 ms`, max `571.51 ms`
  - `repo_click_to_focus` `1402.38 ms`
  - `launch_to_first_prompt` `5231.20 ms`
- minimal toolbar:
  - `event_age_ms` median `11.10 ms`, max `46.10 ms`
  - `repo_click_to_focus` `1170.99 ms`
  - `launch_to_first_prompt` `4044.79 ms`

Takeaway:

- a stable replacement menu in the toolbar did not solve the problem
- the contextual actions item remains too expensive even when the item structure is simplified
- this experiment should not ship as the fix path

### EXP-0009: Remove the contextual toolbar item but keep the rest of the toolbar

Status: complete

Hypothesis:

- the contextual actions item itself, not the entire toolbar, is the dominant remaining contributor

Change:

- removed the `.automatic` contextual toolbar item from `ContentView`
- left the rest of the toolbar structure intact
- kept the `WORKSPACES_PERF_MINIMAL_TOOLBAR=1` full-removal flag for comparison

Artifacts:

- `/tmp/workspaces-exp0009-no-context-toolbar-summary.txt`
- `/tmp/workspaces-exp0008-postprompt-minimal-summary.txt`
- `.dev-data/logs/launch-dev-20260408-001558.log`

Result:

- no contextual toolbar item:
  - `event_age_ms` median `18.77 ms`, max `188.06 ms`
  - `repo_click_to_focus` `1158.80 ms`
  - `launch_to_first_prompt` `4512.09 ms`
- minimal toolbar reference:
  - `event_age_ms` median `11.10 ms`, max `46.10 ms`
  - `repo_click_to_focus` `1170.99 ms`
  - `launch_to_first_prompt` `4044.79 ms`

Takeaway:

- removing just the contextual toolbar item preserves most of the minimal-toolbar performance gain
- this is the strongest current production-safe direction
- the next work should focus on where to relocate those contextual actions, not on keeping them in the toolbar

### EXP-0010: Re-home lost contextual actions into app commands and verify current branch state

Status: complete

Hypothesis:

- moving the lost actions to the app menu should preserve usability without reintroducing toolbar cost

Change:

- kept the contextual toolbar item removed
- re-homed these actions into a `Selection` command menu via focused scene values:
  - open in browser
  - reload web source
  - open desktop
  - reveal in Finder
  - copy path
- added a short learnings summary at `docs/performance/2026-04-08-global-slowness-learnings.md`

Artifacts:

- `/tmp/workspaces-final-postprompt-summary.txt`
- `/tmp/workspaces-final-postprompt-summary-r2.txt`
- `.dev-data/logs/launch-dev-20260408-072019.log`
- `.dev-data/logs/launch-dev-20260408-072059.log`

Result:

- branch remains buildable and testable
- shortcut pass-through still works on the current branch
- repeated post-prompt reruns on the no-context-toolbar shape remained variable:
  - one earlier run measured `event_age_ms` median `18.77 ms`
  - later reruns measured about `309.87 ms` and `749.26 ms`

Takeaway:

- the toolbar fix is real enough to keep
- the app is still not fully solved
- the next iteration should target the remaining variable focus/input delay with fresh active-lag samples on this branch

### EXP-0011: Current-branch validation after command-menu re-home

Status: complete

Hypothesis:

- the current branch may already be good enough on median input latency, while still showing occasional app-side spikes under live interaction

Change:

- no code change for this experiment
- remeasured the current branch after the toolbar removal plus `Selection` command-menu re-home
- captured one corrected post-prompt input run and one fresh active-lag sample on the same no-context-toolbar build

Artifacts:

- `/tmp/workspaces-exp0011-postprompt/summary.txt`
- `.dev-data/logs/launch-dev-20260408-073545.log`
- `/tmp/workspaces-exp0011-active-lag/samples/summary.txt`
- `/tmp/workspaces-exp0011-active-lag/samples/sample-app-89332.txt`
- `/tmp/workspaces-exp0011-active-lag/samples/sample-child-89355.txt`
- `/tmp/workspaces-exp0011-active-lag/samples/sample-child-89472.txt`
- `.dev-data/logs/launch-dev-20260408-073357.log`

Result:

- corrected clean-shell post-prompt input run on the current branch:
  - `event_age_ms` min `0.95 ms`, median `3.40 ms`, max `476.70 ms`, mean `133.90 ms`
  - `handler_duration_ms` median `0.11 ms`
  - `repo_click_to_focus` `1031.94 ms`
  - `launch_to_first_prompt` `3621.46 ms`
- fresh active-lag sample on the same build:
  - shell remained blocked in `read`
  - app sample remained dominated by SwiftUI/AppKit layout and preference churn
  - strong sample signatures included:
    - `NSHostingView.layout`
    - `NSHostingView.preferencesDidChange`
    - `AppWindowsController.updateWindowFocus`
    - `ToolbarBridge.preferencesDidChange`
    - `RepoRow.body`

Takeaway:

- the current branch looks materially better on median input delivery than the earlier slow runs
- the remaining issue is now best described as intermittent app-side spikes, not consistently stale key delivery
- the next optimization target should stay in SwiftUI/AppKit preference and row rendering churn, not shell startup or Ghostty shortcut routing

### EXP-0012: Package Ghostty resources into the release app and set `GHOSTTY_RESOURCES_DIR` before runtime init

Status: complete

Hypothesis:

- the installed-app warnings about missing terminfo and disabled shell integration are caused by the release bundle not embedding Ghostty's `share` payload or telling libghostty where to find it

Change:

- added `GhosttyResourcesLocator.swift`
- updated `GhosttyAppManager.initializeIfNeeded()` to resolve bundled Ghostty resources and set `GHOSTTY_RESOURCES_DIR` before `ghostty_init`
- updated `scripts/build-release.sh` to copy Ghostty `zig-out/share` contents into `WorkspaceManager.app/Contents/Resources`

Artifacts:

- `/Users/fairchild/Downloads/workspaces-report-2026-04-08-204228.zip`
- local packaged app build output from `./scripts/build-release.sh --no-sign`
- packaged bundle path:
  - `build/WorkspaceManager.app/Contents/Resources/ghostty`
  - `build/WorkspaceManager.app/Contents/Resources/terminfo`

Result:

- the prior installed-build report implicated:
  - `ghostty terminfo not found`
  - `no resources dir set, shell integration disabled`
- the new release bundle now embeds the expected Ghostty resource layout and configures the runtime before initialization
- local unattended packaged-run validation did not surface the old terminfo / shell-integration warning signatures again, but log capture from this harness remained incomplete enough that a fresh manual diagnostic export is still the cleanest confirmation path

Takeaway:

- installed bundles must carry Ghostty resources explicitly
- the old installed-build Ghostty degradation was a real packaging/runtime issue, not just noise
- future installed-build perf reports should be checked to confirm those warnings stay gone

### EXP-0013: Remove app-command `FocusedValue` usage entirely after aggregation was insufficient

Status: complete

Hypothesis:

- the remaining `FocusedValue update tried to update multiple times per frame` warning is tied to the app-command routing mechanism itself, not merely the number of focused-scene keys

Change:

- first collapsed multiple focused scene values into one `MainWindowFocusedActions` payload
- after one packaged run still showed the SwiftUI focused-value warning, replaced app-command routing with `AppCommandState`
- removed `focusedSceneValue` usage from `ContentView` and `SidebarView`
- main app commands now read from shared observable command state instead of `@FocusedValue`

Artifacts:

- local packaged-run log inspection around the pre-refactor build showed:
  - `FocusedValue update tried to update multiple times per frame`
- `swift build`
- `swift test`

Result:

- the command-state refactor is buildable and test-clean
- it removes the direct app-command dependence on SwiftUI focused values
- a fresh manual diagnostic run is still needed to prove whether the runtime focused-value warning is fully eliminated in practice

Takeaway:

- reducing the number of focused values was not sufficient on its own
- if the warning still appears in the next manual report, the remaining source is elsewhere in SwiftUI focus/preference updates rather than app-command plumbing

### EXP-0014: Manual diagnostic report on April 8, 2026 shows sub-second first prompt and no recurrence of prior warning signatures

Status: complete

Artifacts:

- diagnostic bundle: `/Users/fairchild/Downloads/workspaces-report-2026-04-08-230216.zip`
- Ghostty crash envelope: `/Users/fairchild/.local/state/ghostty/crash/e3b21dee-c40d-47b3-70d2-9647f49a9155.ghosttycrash`

Result:

- `launch_to_first_prompt` improved to `795.65 ms`
- `repo_hydration` was `3.74 ms`
- first `terminal_first_output` and `first_prompt_ready` were both `676.99 ms`
- later terminal readiness events measured about `130.03 ms` and `142.15 ms`
- the report did not include the earlier `FocusedValue update tried to update multiple times per frame` warning
- the report did not include the earlier Ghostty `terminfo not found` / `no resources dir set` warnings

Crash-file inspection:

- the Ghostty crash artifact is a real Sentry Breakpad envelope, not a false-positive text log
- event timestamp: `2026-04-09T04:43:30.383615Z`
- session status: `crashed`
- session duration: `2765.47 s`
- release tag inside the envelope: `1.3.0-main+da10707f9`
- the envelope carries a `649280` byte `event.minidump` attachment
- the structured event payload does not include a decoded exception or symbolized stack inline
- this machine does not currently have a local Breakpad stackwalker, and `lldb` did not produce a usable backtrace from the extracted minidump

Takeaway:

- the recent performance fixes materially improved launch and terminal readiness
- the previously observed SwiftUI focused-value and Ghostty resource warnings appear resolved in this run
- one residual native Ghostty crash remains worth tracking separately as a stability issue, but it does not look like the main driver of the earlier performance regression
