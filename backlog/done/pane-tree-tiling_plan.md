---
status: pending
category: plan
---

# Pane-Tree Tiling for Main Terminal Panel

## Problem Statement

Workspaces currently models splits as a constrained structure centered on one active primary host session plus an optional split companion and layout metadata. This works for one split and basic navigation, but it does not match the intended terminal mental model: one tiled canvas where repeated split actions can recursively divide panes.

The product direction is now explicit: the main terminal panel should behave like a tiled terminal workspace. Example expectations include repeated `Cmd+D` creating additional vertical panes and `Cmd+Shift+D` splitting the focused pane horizontally. Delivering this robustly requires replacing ad hoc split/session state with a canonical pane-tree model.

## Why We Explored This

- Ghostty split actions already provide semantic intent (`new_split`, `goto_split`, directional payload), but current app state cannot represent deep layouts cleanly.
- Current structure increases branching and special-case logic as features expand (`resize_split`, `equalize_splits`, zoom, close/rebalance).
- User workflows prioritize terminal-native tiling behavior over fixed two-pane UI constraints.

## Why Deferred

- This is a structural refactor across state model, rendering, focus routing, and lifecycle management.
- Highest-quality result requires a deliberate design/reducer/testing phase rather than incremental patching in view code.
- Existing implementation remains serviceable for basic split workflows while this larger redesign is planned.

## What We Learned

- Current split state is map-based and constrained:
  - `splitSessionsByPrimaryID` + `splitLayoutsByPrimaryID` in `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift`.
- Render path is still "single pane or one split pair", not recursive pane composition.
- Ghostty action bridge is in place and should remain:
  - `Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift`
- `resize_split` and `equalize_splits` now work within the current two-pane model, which confirms progress but does not remove the deeper model mismatch:
  - `Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift`
- Surface retention policy is currently unbounded and keyed by session UUID:
  - `Sources/WorkspaceManager/Views/Components/TerminalView.swift`
  - This needs deterministic pane-leaf synchronization in the new model to avoid latent memory growth.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Input/routing model | Keep Ghostty action-driven routing | Preserves terminal parity and avoids command-string hardcoding |
| Layout model | Introduce canonical pane-tree data model | Supports unlimited recursive splits with clear invariants |
| State ownership | Move pane-tree reducer into core coordinator layer | Keeps view/store thin and maximizes testability |
| Rendering | Recursive SwiftUI render from pane-tree snapshot | Matches model exactly and removes special-case UI branches |
| Focus/navigation | Geometry/tree-based directional traversal | Supports robust `goto_split` behavior in deep layouts |
| Lifecycle/memory | Surface store synchronized to active leaf IDs | Prevents stale `GhosttySurfaceView` retention |
| Rollout strategy | Feature-flagged migration with compatibility adapter | Limits regression risk and supports staged validation |

## Implementation Options Considered

| Option | Summary | Pros | Cons | Recommendation |
|--------|---------|------|------|----------------|
| A | Extend current split maps in `HostTerminalStateStore` | Fastest initial coding | Logic complexity grows non-linearly; hard to prove correctness | Reject |
| B | Add `PaneTreeCoordinator` reducer in core, keep Ghostty action bridge | Best maintainability/testability/performance tradeoff | Moderate refactor scope | **Chosen** |
| C | Actor-backed pane engine with async projection | Strong isolation | Higher complexity for UI/focus timing | Not needed initially |

## Architecture

```text
GhosttySurfaceView
  -> GhosttyAppManager.action(new_split/goto_split/resize/equalize)
      -> PaneActionMapper
          -> PaneTreeCoordinator (pure reducer + invariants)
              -> PaneTreeSnapshot
                  -> HostTerminalStateStore (UI projection only)
                      -> Recursive PaneTreeView (HSplitView / VSplitView)
                          -> HostTerminalSurfaceStore.sync(activeLeafIDs)
```

### Target Data Model (Core)

```text
PaneNode
├─ leaf(id: PaneID, session: HostTerminalSession)
└─ split(id: SplitID, axis: vertical|horizontal, ratio: Double, first: PaneNode, second: PaneNode)

PaneTreeState
├─ root: PaneNode
├─ focusedPaneID: PaneID
├─ zoomedPaneID: PaneID?
└─ index caches (pane->path, neighbors) derived or memoized
```

## Quality and Reliability Constraints (non-negotiable)

1. Tree invariants are enforced after every reducer action:
   - unique pane IDs
   - connected acyclic tree
   - valid split ratios and children
   - exactly one focused pane
2. No business logic in SwiftUI view body; views render snapshots only.
3. Surface lifecycle is deterministic:
   - retain only surfaces for leaf panes present in snapshot
   - evict on pane close/rebalance immediately
4. All reducer operations are unit-tested, plus randomized operation-sequence tests.
5. No shortcut command-string hardcoding for split semantics.
6. Focus operations must be O(tree depth) or better for normal actions.

## Research Artifacts

### Current split-model pattern (code excerpt)

```swift
@Published private(set) var splitSessionsByPrimaryID: [UUID: HostTerminalSession] = [:]
@Published private(set) var splitLayoutsByPrimaryID: [UUID: SplitPaneLayout] = [:]
```

Location: `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift`

### Current deferred Ghostty actions

```swift
case GHOSTTY_ACTION_RESIZE_SPLIT:
    NSLog("[GhosttyAppManager] action=resize_split (defer)")
    return false

case GHOSTTY_ACTION_EQUALIZE_SPLITS:
    NSLog("[GhosttyAppManager] action=equalize_splits (defer)")
    return false
```

Location: `Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift`

### Current surface-retention risk point

```swift
private var surfaces: [UUID: GhosttySurfaceView] = [:]
```

Location: `Sources/WorkspaceManager/Views/Components/TerminalView.swift`

## Implementation Phases

### Phase 0: Design Lock and Contracts

**Files to create:**
- `Sources/WorkspaceManagerCore/Services/PaneTree/PaneTreeTypes.swift` - node/state/action definitions
- `Sources/WorkspaceManagerCore/Services/PaneTree/PaneTreeInvariants.swift` - invariant validation helpers
- `Sources/WorkspaceManagerCore/Services/PaneTree/PaneTreeReducer.swift` - pure reducer

**Files to modify:**
- `docs/development/shortcut-routing.md` - update split model section to reference pane-tree
- `docs/development/libghostty-integration.md` - update split contract scope

**Acceptance criteria:**
- [ ] Pane-tree contracts and invariants are documented and agreed.
- [ ] Reducer interface is stable before UI migration starts.

### Phase 1: Core PaneTree Reducer + Tests

**Files to create:**
- `Tests/WorkspaceManagerTests/PaneTreeReducerTests.swift`
- `Tests/WorkspaceManagerTests/PaneTreePropertyTests.swift`

**Files to modify:**
- `Sources/WorkspaceManagerCore/Services/HostTerminalSessionCoordinator.swift` - add pane-root session bootstrapping helpers if needed

**Acceptance criteria:**
- [ ] Reducer supports: split, close pane, directional focus, resize, equalize, zoom toggle.
- [ ] Invariants hold for deterministic and randomized action sequences.
- [ ] No SwiftUI dependency in reducer tests.

### Phase 2: App State Integration (Compatibility Layer)

**Files to modify:**
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` - replace split maps with pane-tree snapshot projection
- `Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift` - map all split actions to pane-tree actions
- `Sources/WorkspaceManager/Views/Components/TerminalView.swift` - add `sync(activeLeafIDs:)` for surface lifecycle control

**Files to create:**
- `Sources/WorkspaceManager/Terminal/PaneActionMapper.swift` - Ghostty action -> reducer action mapping

**Acceptance criteria:**
- [ ] App no longer depends on `splitSessionsByPrimaryID` / `splitLayoutsByPrimaryID`.
- [ ] Recursive pane behavior goes beyond the current two-pane `resize_split` and `equalize_splits` support.
- [ ] Legacy two-pane behavior is representable as a pane-tree subset.

### Phase 3: Recursive Pane Rendering

**Files to modify:**
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` - introduce recursive pane renderer view

**Files to create:**
- `Sources/WorkspaceManager/Views/MainWindow/PaneTreeView.swift` - recursive split-node renderer

**Acceptance criteria:**
- [ ] Repeated vertical splits (`Cmd+D`) create 3+ columns as expected.
- [ ] Horizontal split on focused pane (`Cmd+Shift+D`) works at any depth.
- [ ] Focus transitions follow geometric neighbors in mixed layouts.

### Phase 4: Lifecycle + Memory Hardening

**Files to modify:**
- `Sources/WorkspaceManager/Views/Components/TerminalView.swift`
- `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift`

**Files to create:**
- `Tests/WorkspaceManagerAppTests/PaneLifecycleIntegrationTests.swift`

**Acceptance criteria:**
- [ ] Closing/exiting a pane rebalances tree and preserves focus invariants.
- [ ] Surface count tracks active leaf count with zero stale survivors after close storms.
- [ ] No growth trend in retained surfaces during stress test (`split/close` loops).

### Phase 5: Verification and Rollout

**Files to modify:**
- `scripts/shortcut-pass-through-smoke.sh` - include deeper split sequences
- `maskfile.md` - add pane-tree verification task(s)

**Acceptance criteria:**
- [ ] Required verification loop is documented and green.
- [ ] Shortcut matrix includes deep layouts and mixed axes.
- [ ] Docs reflect pane-tree product model, not two-pane wording.

## Verification Commands

```bash
cd .

# Core build/test loop
./scripts/build-ghosttykit.sh
swift build
swift test

# Required debug verification loop
./scripts/launch-dev.sh --no-build --no-activate
ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'
./scripts/capture-window.sh

# Existing smoke
mask verify-shortcuts

# Future pane-tree smoke (to add in Phase 5)
mask verify-pane-tree
```

## Rollback Plan

1. Keep migration behind a feature flag (`paneTreeTilingEnabled`) until parity is proven.
2. Preserve compatibility adapter for old split state during migration window.
3. If regressions emerge:
   - disable feature flag
   - restore old render path and split handlers
   - keep reducer tests and docs for next attempt
4. Revert commits in reverse order by phase boundary to isolate fault domain quickly.

## References

- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift`
- `Sources/WorkspaceManager/Views/Components/TerminalView.swift`
- `Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift`
- `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
- `Sources/WorkspaceManagerCore/Services/HostTerminalSessionCoordinator.swift`
- `docs/development/shortcut-routing.md`
- `docs/development/libghostty-integration.md`
- `ARCHITECTURE.md`
