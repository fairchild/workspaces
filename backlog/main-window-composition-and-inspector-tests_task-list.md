---
status: pending
category: followup
pr: null
branch: null
score: null
retro_summary: null
completed: null
---

# Main Window Composition + Inspector Tests

## Problem Statement

Release prep surfaced two deferred quality items:

1. `ContentView` currently owns too many concerns (selection routing, terminal focus orchestration, split action routing, preview state, and inspector state pruning) in one file, increasing regression risk and slowing iteration.
2. The new inspector state behavior (preserve tree expansion/tab state across hide/show) has no dedicated app-level tests, so future refactors can silently break expected UI continuity.

Both items were explored during release hardening, but deferred to keep scope controlled while shipping stability fixes.

## Why Deferred

- Immediate priority was lifecycle correctness and release readiness.
- Refactoring `ContentView` and adding broader UI-state coverage are medium-scope tasks better done in a focused pass.

## What We Learned

- `ContentView` has become the main integration point for unrelated behaviors (`Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:13`).
- Inspector persistence now relies on `RightPaneStateStore` and pruning via target snapshots (`Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift:23`, `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:76`).
- Existing shortcut routing tests are good examples of deterministic input-policy tests we can mirror for inspector state behavior (`Tests/WorkspaceManagerAppTests/ShortcutRoutingPolicyTests.swift:41`).

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Refactor scope | Extract coordinator/state units without changing visible behavior | Reduces risk while improving maintainability |
| Test level | Add app-level unit tests for inspector state and right-pane pruning | Catches regressions in integration logic, not just leaf views |
| Migration strategy | Preserve current shortcuts and routing contracts during refactor | Avoids regressions in production keyboard workflows |

## Architecture

```text
Before:
  ContentView
    ├─ selection + deep links
    ├─ focus orchestration
    ├─ split routing
    ├─ code preview behavior
    └─ inspector state lifecycle

After:
  ContentView
    ├─ MainSelectionCoordinator
    ├─ TerminalFocusCoordinator
    ├─ SplitRoutingController
    └─ InspectorStateController (+ tests)
```

## Implementation Phases

### Phase 1: Decompose `ContentView` Responsibilities

**Files to modify:**
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` - remove orchestration-heavy private methods and delegate to extracted components.

**Files to create:**
- `Sources/WorkspaceManager/Views/MainWindow/MainSelectionCoordinator.swift` - own repo/workspace/default-host selection behavior.
- `Sources/WorkspaceManager/Views/MainWindow/TerminalFocusCoordinator.swift` - own terminal focus activation/retry behavior.
- `Sources/WorkspaceManager/Views/MainWindow/SplitRoutingController.swift` - own Ghostty split action handling and layout mapping.
- `Sources/WorkspaceManager/Views/MainWindow/InspectorStateController.swift` - own inspector visibility + prune lifecycle hooks.

**Acceptance criteria:**
- [ ] `ContentView` is materially smaller and primarily declarative.
- [ ] Existing sidebar/inspector/split/preview behavior remains unchanged.
- [ ] No shortcut routing regressions for `Cmd+B`, `Cmd+Shift+B`, `Cmd+D`.

### Phase 2: Add Inspector State + Pruning Tests

**Files to create:**
- `Tests/WorkspaceManagerAppTests/InspectorStateControllerTests.swift` - verifies visibility toggling, guard behavior with no target, and target-pruning behavior.
- `Tests/WorkspaceManagerAppTests/RightPaneStateStoreTests.swift` - verifies per-target persistence and stale-state pruning.

**Files to modify:**
- `Tests/WorkspaceManagerAppTests/ShortcutRoutingPolicyTests.swift` - optionally add focused assertions ensuring inspector shortcut remains app-owned after refactor.

**Acceptance criteria:**
- [ ] Tests assert hide/show preserves expanded directory state for same target.
- [ ] Tests assert stale target states are pruned when repos/workspaces are removed.
- [ ] Tests assert inspector toggle is ignored when no inspector target exists.

### Phase 3: Stabilization and Polish

**Files to modify:**
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` - tighten comments and remove duplicate path normalization where possible.
- `Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift` - keep state container minimal and well-documented.

**Acceptance criteria:**
- [ ] No new warnings in build output.
- [ ] Code owners can trace each concern to a single component.

## Verification Commands

```bash
swift build
swift test --filter ShortcutRoutingPolicyTests
swift test --filter InspectorStateControllerTests
swift test --filter RightPaneStateStoreTests
swift test
```

## Rollback Plan

1. Revert coordinator extraction commits and restore previous `ContentView` implementation.
2. Keep new tests disabled or removed if they require intermediate-only APIs.
3. Re-run `swift test` to confirm baseline behavior remains green.

## Research Artifacts

Current inspector pruning hook:

```swift
.onChange(of: inspectorTargetIDsSnapshot) { _, _ in
    pruneRightPaneState()
}
```

Current store behavior baseline:

```swift
func prune(keeping validTargetIDs: Set<String>) {
    guard !states.isEmpty else { return }
    states = states.filter { validTargetIDs.contains($0.key) }
}
```

## References

- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:13`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:76`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift:145`
- `Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift:23`
- `Sources/WorkspaceManager/Views/MainWindow/RightPaneView.swift:43`
- `Tests/WorkspaceManagerAppTests/ShortcutRoutingPolicyTests.swift:41`
