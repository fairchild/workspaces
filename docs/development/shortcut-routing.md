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

Everything else routes to Ghostty unless an override is added.

## Code Map

- Policy definition:
  - `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/App/ShortcutRoutingPolicy.swift`
- Key-equivalent handling:
  - `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
- Runtime action bridge from Ghostty to SwiftUI state:
  - `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift`
  - `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Views/MainWindow/ContentView.swift`

## Event Flow

1. `performKeyEquivalent` receives key event in `GhosttySurfaceView`.
2. `ShortcutRoutingPolicy` decides route:
   - `appChrome` -> return `false` so AppKit/menu command path handles it.
   - `ghostty` -> continue with Ghostty binding checks.
3. Ghostty binding check uses `ghostty_surface_key_is_binding` with event text populated.
4. If binding exists, key is forwarded via `keyDown` into Ghostty.
5. If Ghostty emits split actions, runtime callback posts a typed split action notification.
6. `ContentView` updates split UI/focus state (`new_split`, `goto_split`).

## Split Navigation Scope

Current split UI model is two-pane horizontal:

- primary terminal + optional right split

`goto_split` behavior in this model:

- `previous` / `next`: toggles focus between primary and split.
- `left` / `right`: directional focus when target exists.
- `up` / `down`: no-op (no vertical split in current UI).

## Verification Checklist

1. Launch debug app via `./scripts/launch-dev.sh --no-build`
2. Confirm debug process path in `.build/.../WorkspaceManager`
3. Verify:
   - `Cmd+B` toggles sidebar
   - `Cmd+D` creates split
   - `Cmd+]` / `Cmd+[` move focus across split when both panes exist
4. Confirm logs include:
   - `[GhosttyAppManager] action=new_split ...`
   - `[GhosttyAppManager] action=goto_split ...`
