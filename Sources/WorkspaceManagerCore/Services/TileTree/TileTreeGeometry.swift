import Foundation

/// Unit-square layout model for a tile tree: each leaf's rectangle inside [0,1]×[0,1], derived by
/// dividing every split's rect along its axis at its ratio. Directional focus resolves neighbors
/// against these frames, so "which pane is to the right" is geometry, not tree shape.
///
/// Adjacency comparisons use exact `Double` equality deliberately: a boundary coordinate is
/// computed once at its split and inherited unchanged by both subtrees, so leaves that share an
/// edge carry bit-identical values — and clamped ratios keep any *other* split line strictly
/// inside its own rect, so distinct lines can never collide. Divider thickness is a render
/// concern and does not exist in this model.
///
/// Deliberately ratio-tree geometry, not rendered geometry: the renderer's minimum-pane clamping
/// (`TileTreeView.constrainedFraction`) can visually distort extreme ratios in small windows, but
/// navigation resolves against the model so the same keystroke lands on the same pane regardless
/// of window size.
struct TileUnitRect: Equatable {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double

    static let unit = TileUnitRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
}

extension TileTree {
    /// Every leaf's unit-square frame, keyed by tile id.
    func unitLeafFrames() -> [TileID: TileUnitRect] {
        var frames: [TileID: TileUnitRect] = [:]
        collectLeafFrames(in: .unit, into: &frames)
        return frames
    }

    private func collectLeafFrames(in rect: TileUnitRect, into frames: inout [TileID: TileUnitRect]) {
        switch self {
        case .tile(let id):
            frames[id] = rect
        case .split(_, let axis, let ratio, let first, let second):
            switch axis {
            case .leadingTrailing:
                let mid = rect.minX + (rect.maxX - rect.minX) * ratio
                first.collectLeafFrames(
                    in: TileUnitRect(minX: rect.minX, maxX: mid, minY: rect.minY, maxY: rect.maxY),
                    into: &frames
                )
                second.collectLeafFrames(
                    in: TileUnitRect(minX: mid, maxX: rect.maxX, minY: rect.minY, maxY: rect.maxY),
                    into: &frames
                )
            case .topBottom:
                let mid = rect.minY + (rect.maxY - rect.minY) * ratio
                first.collectLeafFrames(
                    in: TileUnitRect(minX: rect.minX, maxX: rect.maxX, minY: rect.minY, maxY: mid),
                    into: &frames
                )
                second.collectLeafFrames(
                    in: TileUnitRect(minX: rect.minX, maxX: rect.maxX, minY: mid, maxY: rect.maxY),
                    into: &frames
                )
            }
        }
    }
}
