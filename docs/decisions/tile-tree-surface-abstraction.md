---
status: decided
date: 2026-06-27
decision: tile-tree-recursive-with-surface-seam
supersedes:
  - docs/decisions/terminal-multiplexing.md
related:
  - docs/development/shortcut-routing.md
  - docs/development/libghostty-integration.md
  - .context/plans/tile-tree-surface-abstraction.md
---

# Recursive Tile Tree with a Surface abstraction

## Decision

**The main terminal column arranges its content as a recursive **Tile Tree**, and
a tile's content is any `protocol Surface` conformer — not always a Ghostty
terminal.** A **Tile** is a leaf hosting exactly one Surface; a **Split** is an
internal node dividing space between two children along an axis; the **Tile Tree**
is the recursive arrangement filling the column. This replaces the constrained
two-pane model (one primary `HostTerminalSession` plus an optional companion,
tracked by three parallel `*ByPrimaryID` maps with two-pane special-case logic),
re-expressing today's two-pane layout as a depth-1 tree with zero regression.

The model is shipped, not deferred: Phases 0–4 are merged via **#625** (Core
types + reducer + invariants), **#633** (the `Surface` seam and web conformer),
**#645** (tree becomes the source of truth), and **#658** (recursive renderer +
N-way tiling). `Cmd+D` / `Cmd+Shift+D` now make 3+ terminal tiles at any depth
through the already-wired Ghostty split actions.

The Tile Tree models the arrangement *within one tab*. Tabs remain owned by
`HostTerminalSessionCoordinator`; the tab strip renders as a sibling of the tree
root, and the store holds one `TileTreeState` per tab.

## Why we reversed `terminal-multiplexing.md`

The 2026-04-23 record chose **tmux-primary** and deferred the pane-tree on
cost-vs-value: continuity was the daily-driver need, and owning a recursive split
tree in SwiftUI was high-cost over the riskiest desktop file boundary. Two things
changed the calculus.

The product direction moved toward **terminal-native recursive tiling** — dividing
space at any depth with `Cmd+*` muscle memory the app owns, rather than layering a
tmux prefix model on top of a fixed two-pane shell. And we now need tiles to host
**non-Ghostty surfaces** — a web view first — which the terminal-welded two-pane
model has no seam for. Tmux can neither tile a WKWebView nor give us an app-owned
layout the rest of WorkSpaces can reason about. Reaching both cleanly requires the
two structural changes the old model could not absorb incrementally: a recursive
tree and a content abstraction. So the decision was deliberately revisited; this
record is the reversal.

The two-pane abstraction's seam stress (`splitSessionsByPrimaryID` /
`splitLayoutsByPrimaryID` / `splitFractionsByPrimaryID` plus `ensureSplit`,
`splitFocusTarget`, `resizeDelta`, `removeSplitState`) — cited in the prior ADR as
a reason to *stop* investing — is exactly what the tree pays down.

## Topology / payload split

The tree is **pure topology**. `TileTreeReducer` (in `WorkspaceManagerCore`) moves
only `TileID`s and split ratios; it has no SwiftUI, no `HostTerminalSession`, no
`GhosttySurfaceView` dependency, so it is unit-tested in Core with deterministic and
randomized action sequences. The reducer is payload-free by construction.

The `TileID ↔ Surface` binding lives in the **app layer**. `SurfaceStore` is a
`[TileID: any Surface]` owner; `TerminalSurface` wraps one `GhosttySurfaceView` bound
to a `HostTerminalSession` and carries the agent-registry / OSC / command-status /
`LocalStateStore` coupling, while `WebSurface` wraps a `WKWebView` with none of it —
that asymmetry is what validates the seam. `HostTerminalSession.id` stays the
agent-domain identity; `TileID` is layout identity. They are distinct types bound 1:1
for terminal tiles, so the generic tree never leaks into the agent subsystems.

The `Surface` protocol vends an `NSView` (both leaves are AppKit, wrapped in
`NSViewRepresentable`), and keeps `requestClose()` (user intent, honoring terminal
close confirmation) distinct from `tearDown()` (store eviction). The decided eviction
model makes `SurfaceStore.sync` the single eviction authority — retaining only the tiles
in the live leaf set, each conformer freeing per its policy (a terminal frees its
libghostty handle on `deinit`; the web release policy, immediate vs deferred, is a
Phase 6 decision). Phase 5 adopts `SurfaceStore` and that authority for the terminal
render path; web adoption remains Phase 6 (see *Shipped vs remaining*).

## Invariants

`TileTreeInvariants` validates after every reducer action:

- IDs are unique across the tree.
- The tree is connected and acyclic; every split has exactly two children, with
  ratios clamped to `[min, 1 - min]`.
- Exactly one `focusedTileID`, and it references a live leaf.
- The tree is never empty — closing the last tile re-seeds a default tile (mirroring
  the legacy `handleProcessExitAndResolveFocusTarget`).
- The leaf set after a close equals the leaf set before minus the closed tile, which
  is what drives `SurfaceStore.sync` correctness.

## Consequences

- Repeated splits divide space at any depth; the depth-1 two-pane case is identical
  to prior behavior and proven against the existing tests.
- The three `*ByPrimaryID` maps and their two-pane special-case logic are gone; the
  reducer is the source of truth and the store is a UI projection.
- A second `Surface` kind exists today (`WebSurface` conforms), so the seam is real
  rather than single-implementation. The terminal render path now adopts `SurfaceStore`
  as the live owner; routing the web main-content path through the seam remains Phase 6.
- Directional focus is exact for depth-1 (reproducing `splitFocusTarget`); deep-mixed
  traversal (depth ≥ 2) ships as a tree-walk fallback and is explicitly *not* claimed
  zero-regression, since no baseline exists.
- tmux is no longer the planned primary multiplexing model. `Ctrl+B` tmux-in-sandbox
  on web/sandbox is unaffected; this record governs the macOS app's main column.

## Shipped vs remaining

This record fixes the decided architecture; the implementation is partway there, and the
distinction matters so this ADR does not itself drift.

- **Shipped (Phases 0–5):** the Core tile-tree types + pure `TileTreeReducer` + invariants
  (#625), the `Surface` / `SurfaceStore` / `TerminalSurface` / `WebSurface` seam *types*
  (#633), `TileTreeState` as the layout source of truth (#645), and the recursive
  `TileTreeView` with N-way tiling (#658). Phase 5 adopts `SurfaceStore` in the render
  path and makes `sync(activeLeafIDs:)` the single eviction authority, replacing the
  scattered session-keyed `invalidate` calls.
- **Remaining:** **P6** — route the web main-content path through the seam; **P7** — finalize renames
  (`HostTerminalStateStore` → `TileTreeStore`) — landed with the P7 sweep (#627).

## Deferred (explicitly out of scope)

- **Web-tileable as a feature** — splitting a web Surface into a tile. The conformer
  exists; routing a tree `.close`/split for a web tile is not wired.
- **Per-tile tab groups** — tabs stay scope-owned by `HostTerminalSessionCoordinator`,
  one tree per tab.
- **Pane zoom** — temporarily maximizing the focused tile.
- **Directional-focus keybindings** — no new app-owned keybindings; `Cmd+D` /
  `Cmd+Shift+D` drive splits through existing Ghostty actions.
- **The socket API / Shell Control (issue #628)** — external control of the tree over
  `control.sock` is a separate epic, not part of this decision.
