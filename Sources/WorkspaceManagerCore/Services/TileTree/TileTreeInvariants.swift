import Foundation

/// A structural invariant a `TileTreeState` must satisfy after every reducer action. Surfaced as a
/// value (not a trap) so tests can assert the exhaustive set and the reducer can `assert` in DEBUG.
public enum TileTreeInvariantViolation: Equatable, CustomStringConvertible {
    /// The same `TileID` appears on more than one leaf.
    case duplicateTileID(TileID)
    /// The same `SplitID` appears on more than one split node.
    case duplicateSplitID(SplitID)
    /// A split's `first`-child ratio is outside `[minimumRatio, maximumRatio]`.
    case ratioOutOfRange(SplitID, ratio: Double)
    /// A split's ratio is not finite (NaN / infinite).
    case ratioNotFinite(SplitID)
    /// `focusedTileID` does not reference any live leaf.
    case focusedTileMissing(TileID)

    public var description: String {
        switch self {
        case .duplicateTileID(let id): return "duplicate tile id \(id)"
        case .duplicateSplitID(let id): return "duplicate split id \(id)"
        case .ratioOutOfRange(let id, let ratio): return "ratio \(ratio) out of range for \(id)"
        case .ratioNotFinite(let id): return "non-finite ratio for \(id)"
        case .focusedTileMissing(let id): return "focused tile \(id) is not a live leaf"
        }
    }
}

public enum TileTreeInvariants {
    /// Every violation in `state`, in a stable order. Empty means the state is well-formed.
    ///
    /// Connectedness and acyclicity are guaranteed by the value-type structure (a `TileTree` is a
    /// finite tree by construction) and so are covered by the uniqueness checks rather than a
    /// separate graph walk. Likewise "every split has exactly two children" and "no empty tree" are
    /// enforced by the enum shape itself (`.split` always carries `first` and `second`; the root is
    /// always a `.tile` or `.split`).
    public static func violations(in state: TileTreeState) -> [TileTreeInvariantViolation] {
        var result: [TileTreeInvariantViolation] = []

        var seenTiles: Set<TileID> = []
        for leafID in state.root.leafIDs {
            if !seenTiles.insert(leafID).inserted {
                result.append(.duplicateTileID(leafID))
            }
        }

        var seenSplits: Set<SplitID> = []
        collectSplitViolations(state.root, seenSplits: &seenSplits, into: &result)

        if !seenTiles.contains(state.focusedTileID) {
            result.append(.focusedTileMissing(state.focusedTileID))
        }

        return result
    }

    /// Convenience: whether `state` satisfies every invariant.
    public static func isValid(_ state: TileTreeState) -> Bool {
        violations(in: state).isEmpty
    }

    private static func collectSplitViolations(
        _ node: TileTree,
        seenSplits: inout Set<SplitID>,
        into result: inout [TileTreeInvariantViolation]
    ) {
        guard case .split(let id, _, let ratio, let first, let second) = node else { return }

        if !seenSplits.insert(id).inserted {
            result.append(.duplicateSplitID(id))
        }
        if !ratio.isFinite {
            result.append(.ratioNotFinite(id))
        } else if ratio < TileTreeLayout.minimumRatio || ratio > TileTreeLayout.maximumRatio {
            result.append(.ratioOutOfRange(id, ratio: ratio))
        }

        collectSplitViolations(first, seenSplits: &seenSplits, into: &result)
        collectSplitViolations(second, seenSplits: &seenSplits, into: &result)
    }
}
