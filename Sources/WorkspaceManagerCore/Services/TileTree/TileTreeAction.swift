import Foundation

/// Geometric focus directions for `goto_split`-style navigation.
public enum TileFocusDirection: Sendable, Equatable {
    case up
    case down
    case left
    case right
}

/// Order-based focus navigation (cycles the depth-first leaf order, wrapping at the ends).
public enum TileFocusOrder: Sendable, Equatable {
    case previous
    case next
}

/// The closed set of mutations the `TileTreeReducer` understands.
///
/// Every action is payload-free: it moves `TileID`s / `SplitID`s and split ratios only. The
/// `TileID ↔ Surface` binding lives entirely in the app layer.
public enum TileTreeAction: Sendable, Equatable {
    /// Split the leaf `parent` along `axis`, inserting a fresh tile before or after it. The new
    /// tile becomes focused. No-op if `parent` is not a live leaf.
    case split(parent: TileID, axis: SplitAxis, insertNewBefore: Bool)

    /// Close the leaf `tile`, collapsing its parent split into the surviving sibling. Closing the
    /// last remaining tile re-seeds a fresh single tile (the tree is never empty). If the closed
    /// tile held focus, focus moves into the surviving sibling subtree.
    case close(TileID)

    /// Move focus geometrically from `from` toward `direction`. No-op when there is no neighbor.
    case focusDirectional(from: TileID, direction: TileFocusDirection)

    /// Move focus to the previous/next leaf in depth-first order, wrapping at the ends.
    case focusRelative(from: TileID, order: TileFocusOrder)

    /// Add `ratioDelta` to `split`'s `first`-child ratio, clamped to the legal range.
    case resize(split: SplitID, ratioDelta: Double)

    /// Set `split`'s `first`-child ratio to `ratio`, clamped to the legal range.
    case setRatio(split: SplitID, ratio: Double)

    /// Reset every split ratio to `TileTreeLayout.defaultRatio`. `subtreeRoot == nil` equalizes the
    /// whole tree (matching Ghostty's `equalize_splits`); a `SplitID` equalizes only that subtree.
    case equalize(subtreeRoot: SplitID?)

    /// Focus `tile` directly. No-op if it is not a live leaf.
    case setFocus(TileID)
}
