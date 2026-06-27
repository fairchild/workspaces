# Shortcut Routing Architecture

This document defines how keyboard shortcuts are routed between:

- Workspaces app chrome (sidebar, wrapper UI)
- Embedded Ghostty terminal surfaces

The design goal is **Ghostty-first behavior** with a minimal, explicit app-owned shortcut set.

## Core Policy

1. Default route is `Ghostty`.
2. App chrome owns only explicitly reserved, non-overlapping shortcuts.
3. Routing is policy-driven (not ad-hoc per-shortcut conditionals).
4. User overrides are supported by design (`App` vs `Ghostty`) and can be wired to settings later.

## Current Ownership

Current app-owned default shortcuts:

- `Cmd+B`: toggle left sidebar
- `Cmd+Shift+T`: new workspace sheet/action

Everything else routes to Ghostty unless an override is added.

## Code Map

- Policy definition:
  - `Sources/WorkspaceManager/App/ShortcutRoutingPolicy.swift`
- Key-equivalent handling:
  - `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
- Runtime action bridge from Ghostty to SwiftUI state:
  - `Sources/WorkspaceManager/Terminal/GhosttyRuntimeActionBridge.swift`
  - `Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift`
  - `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift`
  - `Sources/WorkspaceManager/Views/MainWindow/SplitRoutingController.swift`

## Event Flow

1. `performKeyEquivalent` receives key event in `GhosttySurfaceView`.
2. `ShortcutRoutingPolicy` decides route:
   - `appChrome` -> return `false` so AppKit/menu command path handles it.
   - `ghostty` -> continue with Ghostty binding checks.
3. Ghostty binding check uses `ghostty_surface_key_is_binding` with event text populated.
4. If binding exists, key is forwarded via `keyDown` into Ghostty.
5. If Ghostty emits split actions, `GhosttyRuntimeActionBridge` posts a typed split action notification.
6. `ContentView` hands the notification to `SplitRoutingController`, which updates split UI/focus state (`new_split`, `goto_split`, `resize_split`, `equalize_splits`).

## Split Navigation Scope

Current split UI model is a two-pane stack:

- primary terminal + optional split terminal
- first split direction determines the active axis (`left/right` => horizontal, `up/down` => vertical)
- divider position is session-scoped and can be resized/equalized without persisting across launches

`goto_split` behavior in this model:

- `previous` / `next`: toggles focus between primary and split.
- `left` / `right`: directional focus when target exists for horizontal stacks.
- `up` / `down`: directional focus when target exists for vertical stacks.
- Orthogonal directions remain no-ops when they do not match the active split axis.

The [Automation API Reference](./automation-api.md) exposes the same directional
focus and split vocabulary for trusted processes running inside terminal tiles.
Do not broaden those commands here without updating the API docs and tests.

## Verification Checklist

1. Launch debug app via `./scripts/launch-dev.sh --no-build`
   - shared-desktop-safe capture path: `./scripts/launch-dev.sh --no-build --no-activate`
2. Confirm debug process path in `.build/.../WorkspaceManager`
3. If you used `--no-activate`, pause your own input, run `./scripts/capture-window.sh`, then resume.
4. Verify:
   - `Cmd+B` toggles sidebar
   - `Cmd+D` creates split
   - optional: configured Ghostty resize binding moves the divider by 5% steps and clamps at 20%/80%
   - optional: configured Ghostty equalize binding resets divider to 50/50
   - `Cmd+Shift+O` opens selected repo/file in editor when target is available
   - `Cmd+]` / `Cmd+[` move focus across split when both panes exist
   - or run `mask verify-shortcuts` for scripted smoke evidence
   - and run `mask verify-open-shortcut` for Open-in-Editor shortcut coverage
5. Confirm logs include:
   - `[GhosttyAppManager] action=new_split ...`
   - `[GhosttyAppManager] action=goto_split ...`
   - `[GhosttyAppManager] action=resize_split ...`
   - `[GhosttyAppManager] action=equalize_splits ...`
   - `[Perf] metric=open_in_editor_launch ... outcome=success|failure`

`./scripts/shortcut-pass-through-smoke.sh` is a separate activation-driving smoke:
- it requires Accessibility + Automation permissions
- it requires `Terminal Multiplexing Mode = Ghostty Splits`
- it exits early when the app is in `tmux` mode because Workspaces is not expected to materialize Ghostty-managed split actions there
- it is not shared-desktop-safe; use Tart/Lume or a separate macOS user/session when you need input-driving automation without foreground focus
