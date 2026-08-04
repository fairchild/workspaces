# Global Slowness Learnings

Date: 2026-04-08
Branch: `codex/workspaces-perf-optimization`
Status: active reference

This file is the short reference for the current Workspaces performance investigation.

Use it together with:

- [investigation-2026-04-07-global-slowness-and-input-latency.md](investigation-2026-04-07-global-slowness-and-input-latency.md)
- [investigation-2026-04-07-global-slowness-and-input-latency-log.md](investigation-2026-04-07-global-slowness-and-input-latency-log.md)

## Current Best Read

The dominant local slowness is not shell startup and not Ghostty key handling itself.

The strongest contributors found so far are:

1. sidebar row hover/menu/help churn in `SidebarRows.swift`
2. the contextual toolbar item in `ContentView.swift`
3. focus/window timing that still leaves some events stale before they reach the terminal handler
4. residual SwiftUI preference and toolbar bridge churn after the contextual toolbar item is removed
5. installed-build Ghostty resources were previously missing, which degraded shell integration and terminfo setup

Shortcut pass-through is working. In the latest shortcut-specific run, Ghostty actions fired for split and pane navigation. The delay remained upstream of the key handler.

## What Actually Improved Performance

### Repo row cleanup

The repo row optimization in `SidebarRows.swift` was a real win.

Key effects:

- removed hover animation
- stopped building hidden quick-action menus
- reduced repeated row-label/accessibility recomputation

Representative improvement:

- `input event_age_ms` dropped from about `1198.85 ms` median to about `17.47 ms`

### Removing the contextual toolbar item

The toolbar itself is not the whole problem. The expensive part is the contextual toolbar item.

Post-prompt automated measurements on the same clean-shell interaction pattern:

- normal toolbar:
  - `event_age_ms` median `60.81 ms`
  - `repo_click_to_focus` `3885.80 ms`
- full minimal toolbar:
  - `event_age_ms` median `11.10 ms`
  - `repo_click_to_focus` `1170.99 ms`
- toolbar kept, contextual toolbar item removed:
  - `event_age_ms` median `18.77 ms`
  - `repo_click_to_focus` `1158.80 ms`

Conclusion:

- removing just the contextual toolbar item preserves most of the performance gain
- that is the current best product-safe direction
- repeated post-prompt reruns are still variable, which means there is at least one more residual source of stale input beyond the toolbar fix

## Fresh Branch Validation

The current branch was remeasured after the command-menu re-home.

Corrected clean-shell post-prompt run on the current branch:

- `event_age_ms` min `0.95 ms`, median `3.40 ms`, max `476.70 ms`, mean `133.90 ms`
- `handler_duration_ms` median `0.11 ms`
- `repo_click_to_focus` `1031.94 ms`
- `launch_to_first_prompt` `3621.46 ms`

Interpretation:

- most key events now reach the app quickly once the terminal is actually ready
- the key handler itself remains cheap
- there are still intermittent spikes, which means the issue is not fully closed

Fresh active-lag sample on the same no-context-toolbar build:

- shell remained blocked in `read`
- the app sample still concentrated on:
  - `NSHostingView.layout`
  - `NSHostingView.preferencesDidChange`
  - `AppWindowsController.updateWindowFocus`
  - `ToolbarBridge.preferencesDidChange`
  - `RepoRow.body`

Interpretation:

- the current remaining hotspot is still app-side view and preference churn
- the next work should not go back to shell-startup or Ghostty shortcut-routing theories

## New Follow-up Learnings

### Installed builds need explicit Ghostty resources

The installed-build report that looked much better overall still exposed a real packaging problem:

- `ghostty terminfo not found`
- `no resources dir set, shell integration disabled`

That is now addressed in code by:

- embedding Ghostty `share` resources into the release app bundle
- setting `GHOSTTY_RESOURCES_DIR` before `ghostty_init`

This should improve installed-build terminal readiness and keep shell integration available.

### App commands no longer depend on `FocusedValue`

The initial command-menu recovery used focused scene values. A later installed-build report still showed:

- `FocusedValue update tried to update multiple times per frame`

Collapsing many focused values into one payload was not enough, so app-command routing now uses an observable `AppCommandState` instead of `FocusedValue`.

What remains open:

- we still need one fresh manual diagnostic run on the new packaged build to confirm whether that SwiftUI warning is actually gone in practice

## Product Direction From Current Evidence

Keep:

- the sidebar row optimization
- the rest of the toolbar
- the minimal-toolbar experiment flag for future A/B work

Avoid:

- putting dynamic contextual actions back into the toolbar path

Instead:

- re-home those actions into cheaper UI surfaces, such as the app menu or inspector-side UI

## Current Mergeable Shape

The current branch keeps the contextual toolbar item out of the toolbar and restores the missing actions through the app menu `Selection` command group.

Recovered outside the toolbar:

- Open in Browser
- Reload Web Source
- Open Desktop
- Reveal in Finder
- Copy Path

`Open in...` was already available through the existing app command path and did not need to be restored through the toolbar.

## Remaining Open Question

After the toolbar change, some residual stale input remains. The next investigation step should be:

1. reduce the remaining sidebar and preference churn that still shows up in `RepoRow.body`, `View.help`, and `ToolbarBridge`
2. separate toolbar bridge churn from focused-scene-value churn so command-menu recovery work does not mask the real bottleneck
3. remeasure the same clean-shell post-prompt interaction after the next SwiftUI-side reduction

Recent repeated reruns on the no-context-toolbar build showed this variability directly:

- one post-prompt run measured `event_age_ms` median around `18.77 ms`
- later reruns measured around `309.87 ms` and `749.26 ms`
- the latest corrected post-prompt run measured `event_age_ms` median `3.40 ms`, but still saw a `476.70 ms` max spike

That means the toolbar fix is real, but not sufficient to fully close the issue.
