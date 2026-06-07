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

    /// Recursive ancestor walk: rise from `from` to the root and take the first split whose axis
    /// matches `direction` and where `from` sits on the side you can move away from, then descend
    /// into the other child toward the entering edge. Reproduces the legacy two-pane `splitFocusTarget`
    /// exactly at depth 1; the deeper-than-1 traversal is a deliberate not-hardened fallback.
    private func directionalTarget(
        from: TileID,
        direction: TileFocusDirection,
        in root: TileTree
    ) -> TileID? {
        guard let frames = ancestors(of: from, in: root) else { return nil }

        let requiredAxis: SplitAxis
        let requiredSide: ChildSide
        let descendToLastLeaf: Bool
        switch direction {
        case .right:
            (requiredAxis, requiredSide, descendToLastLeaf) = (.leadingTrailing, .first, false)
        case .left:
            (requiredAxis, requiredSide, descendToLastLeaf) = (.leadingTrailing, .second, true)
        case .down:
            (requiredAxis, requiredSide, descendToLastLeaf) = (.topBottom, .first, false)
        case .up:
            (requiredAxis, requiredSide, descendToLastLeaf) = (.topBottom, .second, true)
        }

        for frame in frames.reversed() where frame.axis == requiredAxis && frame.side == requiredSide {
            let otherChild = requiredSide == .first ? frame.second : frame.first
            return descendToLastLeaf ? otherChild.lastLeafID : otherChild.firstLeafID
        }
        return nil
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

    // MARK: - Ancestor path

    private enum ChildSide: Equatable {
        case first
        case second
    }

    private struct AncestorFrame {
        let axis: SplitAxis
        let first: TileTree
        let second: TileTree
        let side: ChildSide
    }

    /// Ancestors of `target` from the root down to its parent split, or `nil` if `target` is absent.
    private func ancestors(of target: TileID, in node: TileTree) -> [AncestorFrame]? {
        switch node {
        case .tile(let id):
            return id == target ? [] : nil
        case .split(_, let axis, _, let first, let second):
            if let deeper = ancestors(of: target, in: first) {
                return [AncestorFrame(axis: axis, first: first, second: second, side: .first)] + deeper
            }
            if let deeper = ancestors(of: target, in: second) {
                return [AncestorFrame(axis: axis, first: first, second: second, side: .second)] + deeper
            }
            return nil
        }
    }
}
