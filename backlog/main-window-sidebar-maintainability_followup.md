---
status: in-progress
category: followup
issue: 81
milestone: 1
pr: 36
branch: codex/apple-native-main-window-redesign-backlog
retro_summary: Main-window state, navigation transitions, launch-surface resolution, and remote-workspace selection now have dedicated controller seams; sidebar sorting also moved into a small pure controller. Ghostty boundary cleanup remains.
---

# Main Window + Sidebar Maintainability Pass

## Problem

The recent refinement work made behavior materially safer, but the main integration files are still too large and mixed-purpose for comfortable iteration:

- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` remains the main app-level orchestration surface.
- `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift` still mixes view composition with repo/workspace/web-source lifecycle actions.
- `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift` and `Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift` remain dense AppKit/C-interop surfaces.

The codebase is stable (`swift test` and `swift build -Xswiftc -warn-concurrency` are green), so the highest-value next quality move is maintainability rather than more feature breadth.

## Goal

Reduce coupling and file-level complexity without changing user-visible behavior.

## Scope

- Prioritize extraction of action/orchestration logic out of oversized SwiftUI integration files.
- Prefer new test seams and behavior-preserving refactors over new product surface.
- Keep the current shortcut, split, workspace-creation, and inspector behavior unchanged.

## Implementation Phases

### Phase 1: Sidebar action extraction

- Move repo/workspace/web-source lifecycle helpers out of `SidebarView.swift` into focused support types or extensions.
- Separate workspace creation/deletion/remote-sandbox lifecycle logic from row rendering and list composition.
- Keep existing behavior-level tests green and add tests for any newly extracted pure helpers.

Status:
- Completed on `codex/maintainability-quality-pass` via `SidebarWorkspaceController`, with the workspace lifecycle/persistence path extracted out of `SidebarView.swift`.

### Phase 2: Main-window orchestration cleanup

- Continue shrinking `ContentView.swift` by extracting lifecycle and selection orchestration that is still mixed into the root view.
- Prefer coordinator/controller seams that can be tested without driving the full view tree.
- Keep the root file primarily declarative: queries, bindings, layout, and high-level wiring.

Status:
- In progress on `codex/sidebar-content-maintainability`.
- `MainWindowViewState`, `MainWindowPresentationController`, and `MainWindowBootstrapController` now hold root-view state, inspector/sidebar derivation, and deep-link/fixture bootstrap decisions.
- Added focused tests for the new controller seams to keep the refactor behavior-preserving.
- `MainWindowNavigationStateController`, `MainWindowSurfaceResolutionController`, and `MainWindowRemoteWorkspaceStateController` now centralize previously ad hoc selection and lifecycle behavior.
- Selection state now stores stable IDs/lightweight structs instead of live SwiftData objects to avoid stale-object hazards after deletion or async completion.
- `SidebarRepoSortController` now holds stable repository sorting rules instead of burying sort policy in `SidebarView`.

### Phase 3: Ghostty boundary cleanup

- Isolate callback bridging, lifecycle helpers, and AppKit interop hotspots in the Ghostty layer.
- Preserve the current `@MainActor`/strict-concurrency guarantees while improving readability and testability.
- Add tests only where the new seam is deterministic and does not require fragile UI automation.

Status:
- Started with a dedicated `GhosttyRuntimeConfigFactory` seam so raw `ghostty_runtime_config_s` callback wiring no longer lives inline in `GhosttyAppManager.initializeIfNeeded()`.

## Acceptance Criteria

- `ContentView.swift` and `SidebarView.swift` are materially smaller or more clearly partitioned by concern.
- No behavior regressions in session routing, inspector state, workspace creation, or split handling.
- `swift build -Xswiftc -warn-concurrency` stays clean.
- `swift test` remains green.

## Verification

```bash
swift build -Xswiftc -warn-concurrency
swift test
```

## Notes

- Refinement-gate closure work is already on `main`; this follow-up is about quality of the implementation, not missing shipped behavior.
- Shared-desktop verification determinism remains a related but separate track in `backlog/shared-desktop-focus-contention-followup.md`.
- Current local validation after the additional extraction pass is green at 270 tests across 45 suites.
