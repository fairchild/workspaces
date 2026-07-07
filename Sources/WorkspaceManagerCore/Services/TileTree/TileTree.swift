import Foundation

// MARK: - Identity

/// Layout identity for a leaf region (a *Tile*) in a `TileTree`.
///
/// Distinct from `HostTerminalSession.id`, which is the agent-domain identity used by the
/// session registry, OSC routing, command status, and local state. A terminal tile binds one
/// `TileID` to one `HostTerminalSession.id` in the app layer; keeping the types separate stops
/// the generic arrangement layer from leaking into the agent subsystems.
public struct TileID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { "Tile(\(rawValue.uuidString.prefix(8)))" }
}

/// Identity for an internal *Split* node dividing space between exactly two children.
public struct SplitID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { "Split(\(rawValue.uuidString.prefix(8)))" }
}

// MARK: - Axis

/// The axis along which a `Split` divides its space.
///
/// Mirrors the geometry of the legacy two-pane `SplitPaneLayout.Axis` so the depth-1 mapping
/// is a direct translation: `first` is the leading child (left / top), `second` the trailing.
public enum SplitAxis: String, Codable, Sendable {
    /// Children laid out left → right; `ratio` is the fraction of *width* given to `first`.
    case leadingTrailing
    /// Children laid out top → bottom; `ratio` is the fraction of *height* given to `first`.
    case topBottom
}

// MARK: - Tile tree

/// The recursive arrangement of Splits and Tiles filling the main column.
///
/// A pure topology value type: it carries only `TileID`s, `SplitID`s, axes, and ratios — never a
/// surface, session, or view. The `TileID ↔ Surface` binding lives in the app layer (`SurfaceStore`),
/// so the reducer and its tests stay free of SwiftUI, AppKit, and `HostTerminalSession`.
public indirect enum TileTree: Equatable, Codable, Sendable {
    /// A leaf region hosting exactly one Surface (identified in the app layer by `TileID`).
    case tile(TileID)
    /// An internal node dividing space between `first` and `second` along `axis`.
    /// `ratio` is `first`'s fraction of the split's length, clamped to
    /// `[TileTreeLayout.minimumRatio, TileTreeLayout.maximumRatio]`.
    case split(id: SplitID, axis: SplitAxis, ratio: Double, first: TileTree, second: TileTree)
}

extension TileTree {
    /// All tile IDs in depth-first, leading-before-trailing order. Drives relative focus cycling
    /// and the `SurfaceStore.sync` leaf-set diff.
    public var leafIDs: [TileID] {
        switch self {
        case .tile(let id):
            return [id]
        case .split(_, _, _, let first, let second):
            return first.leafIDs + second.leafIDs
        }
    }

    /// All split IDs anywhere in the subtree.
    public var splitIDs: [SplitID] {
        switch self {
        case .tile:
            return []
        case .split(let id, _, _, let first, let second):
            return [id] + first.splitIDs + second.splitIDs
        }
    }

    /// Whether `tileID` appears as a leaf anywhere in the subtree.
    public func contains(_ tileID: TileID) -> Bool {
        switch self {
        case .tile(let id):
            return id == tileID
        case .split(_, _, _, let first, let second):
            return first.contains(tileID) || second.contains(tileID)
        }
    }

    /// The first (leading-most) leaf of the subtree — used to resolve a focus target when a
    /// collapse removes the focused tile.
    public var firstLeafID: TileID {
        switch self {
        case .tile(let id):
            return id
        case .split(_, _, _, let first, _):
            return first.firstLeafID
        }
    }

    /// The last (trailing-most) leaf of the subtree.
    public var lastLeafID: TileID {
        switch self {
        case .tile(let id):
            return id
        case .split(_, _, _, _, let second):
            return second.lastLeafID
        }
    }

    /// The innermost split directly enclosing `tileID`, plus which side the tile sits on. `nil` for a
    /// bare tile or when the subtree does not contain `tileID`. Drives "resize the split around the
    /// focused pane" at any depth, without assuming the enclosing split is the root.
    public func enclosingSplit(of tileID: TileID) -> EnclosingSplit? {
        guard case .split(let id, let axis, _, let first, let second) = self else { return nil }
        if first.contains(tileID) {
            return first.enclosingSplit(of: tileID) ?? EnclosingSplit(id: id, axis: axis, leafIsFirst: true)
        }
        if second.contains(tileID) {
            return second.enclosingSplit(of: tileID) ?? EnclosingSplit(id: id, axis: axis, leafIsFirst: false)
        }
        return nil
    }
}

/// The split that directly encloses a tile, located by `TileTree.enclosingSplit(of:)`.
public struct EnclosingSplit: Equatable, Sendable {
    public let id: SplitID
    public let axis: SplitAxis
    /// Whether the located tile lives in this split's `first` (leading / top) child subtree.
    public let leafIsFirst: Bool

    public init(id: SplitID, axis: SplitAxis, leafIsFirst: Bool) {
        self.id = id
        self.axis = axis
        self.leafIsFirst = leafIsFirst
    }
}

// MARK: - State

/// A `TileTree` paired with the single focused tile. The reducer maintains the invariant that
/// `focusedTileID` always references a live leaf of `root`.
public struct TileTreeState: Equatable, Codable, Sendable {
    public var root: TileTree
    public var focusedTileID: TileID

    public init(root: TileTree, focusedTileID: TileID) {
        self.root = root
        self.focusedTileID = focusedTileID
    }

    /// A single-tile tree with that tile focused — the depth-0 starting shape (and the re-seed
    /// shape after the last tile closes).
    public init(singleTile tileID: TileID) {
        self.root = .tile(tileID)
        self.focusedTileID = tileID
    }

    public var leafIDs: [TileID] { root.leafIDs }
    public var splitIDs: [SplitID] { root.splitIDs }
}

// MARK: - Layout constants

/// Shared split-ratio constants. Mirrors the legacy `TileTreeStore` fractions so the
/// depth-1 two-pane case clamps and steps identically.
public enum TileTreeLayout {
    /// Smallest fraction a child may occupy. The complementary child is bounded by `maximumRatio`.
    public static let minimumRatio: Double = 0.2
    /// Default `first`-child fraction for a freshly created split (an even divide).
    public static let defaultRatio: Double = 0.5
    /// Largest fraction a child may occupy (`1 - minimumRatio`).
    public static var maximumRatio: Double { 1 - minimumRatio }
    /// Ratio delta applied per keyboard resize step.
    public static let resizeStep: Double = 0.05

    /// Clamp a proposed `first`-child ratio into `[minimumRatio, maximumRatio]`.
    public static func clampRatio(_ ratio: Double) -> Double {
        if ratio.isNaN {
            return defaultRatio
        }
        if ratio == .infinity {
            return maximumRatio
        }
        if ratio == -.infinity {
            return minimumRatio
        }
        return min(max(ratio, minimumRatio), maximumRatio)
    }
}
