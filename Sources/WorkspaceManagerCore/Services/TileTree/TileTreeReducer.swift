import Foundation

/// Pure, payload-free reducer over `TileTreeState`.
///
/// Every action returns a fresh state; the reducer never mutates surfaces, sessions, or views. New
/// `TileID`s / `SplitID`s come from injectable generators so callers (and tests) control identity —
/// the defaults mint UUIDs. After `split`, the new tile becomes `focusedTileID`; after `close`, focus
/// moves into the surviving sibling. Callers drive `SurfaceStore.sync` by diffing `state.leafIDs`
/// before and after, so the reducer need not surface created/removed IDs explicitly.
public struct TileTreeReducer {
    private let makeTileID: () -> TileID
    private let makeSplitID: () -> SplitID

    public init(
        makeTileID: @escaping () -> TileID = { TileID() },
        makeSplitID: @escaping () -> SplitID = { SplitID() }
    ) {
        self.makeTileID = makeTileID
        self.makeSplitID = makeSplitID
    }

    public func reduce(_ state: TileTreeState, _ action: TileTreeAction) -> TileTreeState {
        let next: TileTreeState
        switch action {
        case .split(let parent, let axis, let insertNewBefore):
            next = applySplit(state, parent: parent, axis: axis, insertNewBefore: insertNewBefore)
        case .close(let tile):
            next = applyClose(state, target: tile)
        case .focusDirectional(let from, let direction):
            next = applyFocus(state, to: directionalTarget(from: from, direction: direction, in: state.root))
        case .focusRelative(let from, let order):
            next = applyFocus(state, to: relativeTarget(from: from, order: order, in: state.root))
        case .resize(let split, let ratioDelta):
            next = applyRatio(state, split: split) { $0 + ratioDelta }
        case .setRatio(let split, let ratio):
            next = applyRatio(state, split: split) { _ in ratio }
        case .equalize(let subtreeRoot):
            next = applyEqualize(state, subtreeRoot: subtreeRoot)
        case .setFocus(let tile):
            next = applyFocus(state, to: state.root.contains(tile) ? tile : nil)
        }

        assert(
            TileTreeInvariants.isValid(next),
            "TileTreeReducer produced an invalid state for \(action): "
                + "\(TileTreeInvariants.violations(in: next))"
        )
        return next
    }

    // MARK: - Split

    private func applySplit(
        _ state: TileTreeState,
        parent: TileID,
        axis: SplitAxis,
        insertNewBefore: Bool
    ) -> TileTreeState {
        guard state.root.contains(parent) else { return state }

        let newTile = makeTileID()
        let parentLeaf = TileTree.tile(parent)
        let newLeaf = TileTree.tile(newTile)
        let (first, second) = insertNewBefore ? (newLeaf, parentLeaf) : (parentLeaf, newLeaf)
        let replacement = TileTree.split(
            id: makeSplitID(),
            axis: axis,
            ratio: TileTreeLayout.defaultRatio,
            first: first,
            second: second
        )
        let newRoot = replacingLeaf(state.root, parent, with: replacement)
        return TileTreeState(root: newRoot, focusedTileID: newTile)
    }

    // MARK: - Close

    private func applyClose(_ state: TileTreeState, target: TileID) -> TileTreeState {
        // A single-tile tree: closing the only tile re-seeds a fresh one (the tree is never empty).
        if case .tile(let id) = state.root {
            guard id == target else { return state }
            return TileTreeState(singleTile: makeTileID())
        }

        guard state.root.contains(target), let newRoot = removingLeaf(state.root, target) else {
            return state
        }

        let newFocus: TileID
        if state.focusedTileID != target, newRoot.contains(state.focusedTileID) {
            newFocus = state.focusedTileID
        } else {
            newFocus = focusReplacement(forClosing: target, in: state.root) ?? newRoot.firstLeafID
        }
        return TileTreeState(root: newRoot, focusedTileID: newFocus)
    }

    // MARK: - Focus

    private func applyFocus(_ state: TileTreeState, to target: TileID?) -> TileTreeState {
        guard let target, target != state.focusedTileID else { return state }
        var next = state
        next.focusedTileID = target
        return next
    }

    /// Geometric neighbor resolution over the unit-square layout (`unitLeafFrames`): the target is
    /// the leaf that (1) faces `from` across the crossed edge — its opposite edge lies exactly on
    /// `from`'s edge in `direction` — and (2) overlaps `from` the most along the perpendicular
    /// axis, ties breaking toward the top/left. No adjacent overlapping leaf ⇒ a true edge ⇒ `nil`.
    ///
    /// Depth-1 behavior is unchanged. This replaces the ancestor-walk descent that ignored
    /// perpendicular position — in a 2×2 grid, moving down from the top-right pane used to land
    /// bottom-left (#690). Exact edge equality is sound because shared boundaries are computed
    /// once and inherited (see `TileTreeGeometry.swift`).
    private func directionalTarget(
        from: TileID,
        direction: TileFocusDirection,
        in root: TileTree
    ) -> TileID? {
        let frames = root.unitLeafFrames()
        guard let origin = frames[from] else { return nil }

        let crossedEdge: Double
        let facingEdge: (TileUnitRect) -> Double
        let perpendicularSpan: (TileUnitRect) -> (lo: Double, hi: Double)
        switch direction {
        case .right:
            crossedEdge = origin.maxX
            facingEdge = { $0.minX }
            perpendicularSpan = { ($0.minY, $0.maxY) }
        case .left:
            crossedEdge = origin.minX
            facingEdge = { $0.maxX }
            perpendicularSpan = { ($0.minY, $0.maxY) }
        case .down:
            crossedEdge = origin.maxY
            facingEdge = { $0.minY }
            perpendicularSpan = { ($0.minX, $0.maxX) }
        case .up:
            crossedEdge = origin.minY
            facingEdge = { $0.maxY }
            perpendicularSpan = { ($0.minX, $0.maxX) }
        }

        let originSpan = perpendicularSpan(origin)
        var best: (id: TileID, overlap: Double, position: Double)?
        for (id, rect) in frames where id != from {
            guard facingEdge(rect) == crossedEdge else { continue }
            let span = perpendicularSpan(rect)
            let overlap = min(span.hi, originSpan.hi) - max(span.lo, originSpan.lo)
            guard overlap > 0 else { continue }
            // Two facing candidates can never share both overlap and position (they would occupy
            // the same region), so this ordering is deterministic despite dictionary iteration.
            if let current = best,
                !(overlap > current.overlap
                    || (overlap == current.overlap && span.lo < current.position))
            {
                continue
            }
            best = (id, overlap, span.lo)
        }
        return best?.id
    }

    private func relativeTarget(
        from: TileID,
        order: TileFocusOrder,
        in root: TileTree
    ) -> TileID? {
        let leaves = root.leafIDs
        guard leaves.count > 1, let index = leaves.firstIndex(of: from) else { return nil }
        let count = leaves.count
        let target = order == .next ? (index + 1) % count : (index - 1 + count) % count
        return leaves[target]
    }

    // MARK: - Ratio

    private func applyRatio(
        _ state: TileTreeState,
        split: SplitID,
        transform: (Double) -> Double
    ) -> TileTreeState {
        var next = state
        next.root = updatingSplit(state.root, split, transform: transform)
        return next
    }

    private func applyEqualize(_ state: TileTreeState, subtreeRoot: SplitID?) -> TileTreeState {
        var next = state
        if let subtreeRoot {
            next.root = equalizingSubtree(state.root, root: subtreeRoot)
        } else {
            next.root = equalizingAll(state.root)
        }
        return next
    }

    // MARK: - Tree transforms

    private func replacingLeaf(_ node: TileTree, _ target: TileID, with replacement: TileTree) -> TileTree {
        switch node {
        case .tile(let id):
            return id == target ? replacement : node
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(
                id: id,
                axis: axis,
                ratio: ratio,
                first: replacingLeaf(first, target, with: replacement),
                second: replacingLeaf(second, target, with: replacement)
            )
        }
    }

    private func removingLeaf(_ node: TileTree, _ target: TileID) -> TileTree? {
        guard case .split(let id, let axis, let ratio, let first, let second) = node else {
            return nil
        }
        if first == .tile(target) { return second }
        if second == .tile(target) { return first }
        if first.contains(target), let newFirst = removingLeaf(first, target) {
            return .split(id: id, axis: axis, ratio: ratio, first: newFirst, second: second)
        }
        if second.contains(target), let newSecond = removingLeaf(second, target) {
            return .split(id: id, axis: axis, ratio: ratio, first: first, second: newSecond)
        }
        return nil
    }

    /// The leaf to focus when `target` is removed: the neighbor across the collapsing split, biased
    /// to the side nearest where `target` sat.
    private func focusReplacement(forClosing target: TileID, in node: TileTree) -> TileID? {
        guard case .split(_, _, _, let first, let second) = node else { return nil }
        if first == .tile(target) { return second.firstLeafID }
        if second == .tile(target) { return first.lastLeafID }
        if first.contains(target) { return focusReplacement(forClosing: target, in: first) }
        if second.contains(target) { return focusReplacement(forClosing: target, in: second) }
        return nil
    }

    private func updatingSplit(
        _ node: TileTree,
        _ target: SplitID,
        transform: (Double) -> Double
    ) -> TileTree {
        switch node {
        case .tile:
            return node
        case .split(let id, let axis, let ratio, let first, let second):
            if id == target {
                return .split(
                    id: id,
                    axis: axis,
                    ratio: TileTreeLayout.clampRatio(transform(ratio)),
                    first: first,
                    second: second
                )
            }
            return .split(
                id: id,
                axis: axis,
                ratio: ratio,
                first: updatingSplit(first, target, transform: transform),
                second: updatingSplit(second, target, transform: transform)
            )
        }
    }

    private func equalizingAll(_ node: TileTree) -> TileTree {
        switch node {
        case .tile:
            return node
        case .split(let id, let axis, _, let first, let second):
            return .split(
                id: id,
                axis: axis,
                ratio: TileTreeLayout.defaultRatio,
                first: equalizingAll(first),
                second: equalizingAll(second)
            )
        }
    }

    private func equalizingSubtree(_ node: TileTree, root target: SplitID) -> TileTree {
        switch node {
        case .tile:
            return node
        case .split(let id, let axis, let ratio, let first, let second):
            if id == target {
                return equalizingAll(node)
            }
            return .split(
                id: id,
                axis: axis,
                ratio: ratio,
                first: equalizingSubtree(first, root: target),
                second: equalizingSubtree(second, root: target)
            )
        }
    }

}
