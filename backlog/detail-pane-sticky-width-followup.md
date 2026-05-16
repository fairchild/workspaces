---
topic: runtime-diagnostics
priority: 2
description: Preserve the user's preferred Detail Pane width across tab changes, including the wider Diagnostics tab.
---

# Sticky Detail Pane Width Across Tabs

## Problem Statement

The Diagnostics Detail Pane currently widens when selected and returns to the older narrow maximum on other tabs. User review found the default Diagnostics width good, but the max-width transition feels awkward when moving between tabs.

The follow-up should make the Detail Pane remember the last width the user actually used and preserve that width across Files, Changes, Activity, and Diagnostics. Tab changes should not create a visible snap unless the current width is outside a hard safety bound for the selected Surface.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Width ownership | Store per-target Detail Pane width in right-pane state | Width is part of the Detail Pane session, like selected tab and expansion state. |
| Default width | Keep the current Diagnostics default | User feedback says the default width is good. |
| Cross-tab behavior | Prefer sticky width over per-tab max-width snapping | The awkwardness comes from changing constraints as tabs switch. |
| Persistence | Start with in-memory state; consider durable persistence only after interaction review | Avoid adding storage/migration work before the behavior feels right. |

## Architecture

Current width selection lives in:

- `Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift` - `RightPaneWidthPolicy` and `rightPaneWidth(for:)`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` - applies the width modifier around `RightPaneView`

The follow-up should replace the tab-only width policy with state that can represent:

```text
RightPaneSessionState
  selectedTab
  preferredWidth
  lastUserAdjustedWidth
```

The view should still provide sensible defaults when no measured/user width exists.

## Implementation Phases

### Phase 1: Capture And Preserve Width

**Files to modify:**

- `Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift` - add width state and a policy that clamps only to broad safety bounds.
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` - replace fixed tab-derived frame constraints with sticky width handling.
- `Tests/WorkspaceManagerAppTests/RightPaneTabPolicyTests.swift` - update or split width policy tests for sticky behavior.

**Acceptance criteria:**

- [ ] Selecting Diagnostics uses the current wider default when no prior width exists.
- [ ] Manually resizing the Detail Pane and switching tabs preserves the selected width.
- [ ] Switching away from Diagnostics does not snap back to a 400 px max width.
- [ ] Width remains bounded enough that compact file/change tabs do not break layout.

### Phase 2: Interaction Polish

**Files to modify:**

- `Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift`

**Acceptance criteria:**

- [ ] Width transitions do not animate awkwardly during tab changes.
- [ ] The pane remains usable after changing selection between Workspace and Repository Detail Pane targets.
- [ ] If durable persistence is added, it is keyed by stable target identity and does not require SwiftData migration.

## Verification Commands

```bash
swift-format lint --strict --recursive Sources/ Tests/
swift test --filter RightPaneTabPolicy
swift test
swift build
./scripts/launch-dev.sh --no-build --fixture --clean-data --trust-mise --env WORKSPACES_UI_FIXTURE_OPEN_DIAGNOSTICS=1 --window-timeout 15
```

## Rollback Plan

Restore the current `RightPaneWidthPolicy` behavior and fixed tab-derived constraints. This is isolated to the Detail Pane view layer.

## References

- PR #482: Runtime Diagnostics Detail Pane
- `Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift`
