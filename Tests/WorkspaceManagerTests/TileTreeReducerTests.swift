// swift-format-ignore-file: NeverForceUnwrap
// Test fixtures/helpers force-unwrap known-good literals or generator output; a failure here is a loud test crash, not a user-facing risk.
//
//  TileTreeReducerTests.swift
//  WorkspaceManagerTests
//
//  Deterministic per-action coverage for the pure tile-tree reducer, plus the depth-1 two-pane
//  cases that must stay identical to the legacy `splitFocusTarget` / split-fraction behavior.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("TileTreeReducer")
struct TileTreeReducerTests {
    // MARK: - Fixtures

    /// Mints sequential, deterministic IDs so failures are reproducible.
    private final class IDGen {
        private var tiles = 0
        private var splits = 0

        func tile() -> TileID {
            tiles += 1
            return TileID(UUID(uuidString: "10000000-0000-0000-0000-\(Self.tail(tiles))")!)
        }

        func split() -> SplitID {
            splits += 1
            return SplitID(UUID(uuidString: "20000000-0000-0000-0000-\(Self.tail(splits))")!)
        }

        private static func tail(_ n: Int) -> String { String(format: "%012d", n) }
    }

    private func makeReducer(_ gen: IDGen) -> TileTreeReducer {
        TileTreeReducer(makeTileID: gen.tile, makeSplitID: gen.split)
    }

    /// A depth-1 two-pane state: `first` = original tile, `second` = the split tile, focus on second.
    private func twoPane(
        axis: SplitAxis,
        insertNewBefore: Bool = false
    ) -> (state: TileTreeState, reducer: TileTreeReducer, original: TileID, added: TileID) {
        let gen = IDGen()
        let reducer = makeReducer(gen)
        let original = gen.tile()
        let initial = TileTreeState(singleTile: original)
        let state = reducer.reduce(
            initial,
            .split(parent: original, axis: axis, insertNewBefore: insertNewBefore)
        )
        return (state, reducer, original, state.focusedTileID)
    }

    // MARK: - Construction & split

    @Test("Single-tile state is well-formed")
    func singleTileValid() {
        let gen = IDGen()
        let t1 = gen.tile()
        let state = TileTreeState(singleTile: t1)
        #expect(state.leafIDs == [t1])
        #expect(state.focusedTileID == t1)
        #expect(TileTreeInvariants.isValid(state))
    }

    @Test("Split creates a two-pane tree and focuses the new tile")
    func splitCreatesTwoPane() {
        let (state, _, original, added) = twoPane(axis: .leadingTrailing)
        #expect(state.leafIDs == [original, added])
        #expect(state.focusedTileID == added)
        #expect(added != original)
        #expect(TileTreeInvariants.isValid(state))

        guard case .split(_, let axis, let ratio, .tile(let first), .tile(let second)) = state.root else {
            Issue.record("expected a single split with two tile children")
            return
        }
        #expect(axis == .leadingTrailing)
        #expect(ratio == TileTreeLayout.defaultRatio)
        #expect(first == original)
        #expect(second == added)
    }

    @Test("insertNewBefore places the new tile as the leading child")
    func splitInsertBefore() {
        let (state, _, original, added) = twoPane(axis: .leadingTrailing, insertNewBefore: true)
        guard case .split(_, _, _, .tile(let first), .tile(let second)) = state.root else {
            Issue.record("expected a single split")
            return
        }
        #expect(first == added)
        #expect(second == original)
    }

    @Test("Split on an unknown parent is a no-op")
    func splitUnknownParentNoOp() {
        let gen = IDGen()
        let reducer = makeReducer(gen)
        let t1 = gen.tile()
        let state = TileTreeState(singleTile: t1)
        let stranger = TileID()
        let next = reducer.reduce(state, .split(parent: stranger, axis: .topBottom, insertNewBefore: false))
        #expect(next == state)
    }

    @Test("Repeated splits build three-plus tiles at depth")
    func recursiveSplitsGrow() {
        let gen = IDGen()
        let reducer = makeReducer(gen)
        var state = TileTreeState(singleTile: gen.tile())

        for _ in 0..<4 {
            // Always split the currently focused leaf, mirroring Cmd+D on the active tile.
            state = reducer.reduce(
                state,
                .split(parent: state.focusedTileID, axis: .leadingTrailing, insertNewBefore: false)
            )
            #expect(TileTreeInvariants.isValid(state))
        }
        #expect(state.leafIDs.count == 5)
        #expect(Set(state.leafIDs).count == 5)
        #expect(state.root.splitIDs.count == 4)
    }

    // MARK: - Close

    @Test("Closing the trailing tile collapses to the leading sibling and focuses it")
    func closeTrailingCollapses() {
        let (state, reducer, original, added) = twoPane(axis: .leadingTrailing)
        let next = reducer.reduce(state, .close(added))
        #expect(next.root == .tile(original))
        #expect(next.focusedTileID == original)
        #expect(TileTreeInvariants.isValid(next))
    }

    @Test("Closing the leading tile collapses to the trailing sibling and focuses it")
    func closeLeadingCollapses() {
        let (state, reducer, original, added) = twoPane(axis: .leadingTrailing)
        let next = reducer.reduce(state, .close(original))
        #expect(next.root == .tile(added))
        #expect(next.focusedTileID == added)
    }

    @Test("Closing a non-focused tile preserves the existing focus")
    func closeNonFocusedKeepsFocus() {
        // Build three tiles, focus the first, close the last.
        let gen = IDGen()
        let reducer = makeReducer(gen)
        let t1 = gen.tile()
        var state = TileTreeState(singleTile: t1)
        state = reducer.reduce(state, .split(parent: t1, axis: .leadingTrailing, insertNewBefore: false))
        let t2 = state.focusedTileID
        state = reducer.reduce(state, .split(parent: t2, axis: .leadingTrailing, insertNewBefore: false))
        let t3 = state.focusedTileID
        state = reducer.reduce(state, .setFocus(t1))
        #expect(state.focusedTileID == t1)

        let next = reducer.reduce(state, .close(t3))
        #expect(next.focusedTileID == t1)
        #expect(Set(next.leafIDs) == [t1, t2])
    }

    @Test("Closing the last remaining tile re-seeds a fresh tile")
    func closeLastReseeds() {
        let gen = IDGen()
        let reducer = makeReducer(gen)
        let t1 = gen.tile()
        let state = TileTreeState(singleTile: t1)
        let next = reducer.reduce(state, .close(t1))
        #expect(next.leafIDs.count == 1)
        #expect(next.leafIDs.first != t1)
        #expect(next.focusedTileID == next.leafIDs.first)
        #expect(TileTreeInvariants.isValid(next))
    }

    @Test("Closing an unknown tile is a no-op")
    func closeUnknownNoOp() {
        let (state, reducer, _, _) = twoPane(axis: .leadingTrailing)
        let next = reducer.reduce(state, .close(TileID()))
        #expect(next == state)
    }

    @Test("Closing the only tile with a mismatched target is a no-op")
    func closeSingleMismatchedTargetNoOp() {
        let gen = IDGen()
        let reducer = makeReducer(gen)
        let t1 = gen.tile()
        let state = TileTreeState(singleTile: t1)
        let next = reducer.reduce(state, .close(TileID()))
        #expect(next == state)
    }

    @Test("Closing the focused tile in a deeper tree moves focus to the adjacent survivor")
    func closeFocusedReassignsToNeighbor() {
        // tree = split(t1, split(t2, t3)); focus the nested middle leaf t2 and close it.
        let gen = IDGen()
        let reducer = makeReducer(gen)
        let t1 = gen.tile()
        var state = TileTreeState(singleTile: t1)
        state = reducer.reduce(state, .split(parent: t1, axis: .leadingTrailing, insertNewBefore: false))
        let t2 = state.focusedTileID
        state = reducer.reduce(state, .split(parent: t2, axis: .leadingTrailing, insertNewBefore: false))
        let t3 = state.focusedTileID
        state = reducer.reduce(state, .setFocus(t2))

        let next = reducer.reduce(state, .close(t2))
        // The survivor across the collapsing split is t3 (the leaf t2 sat next to).
        #expect(next.focusedTileID == t3)
        #expect(Set(next.leafIDs) == [t1, t3])
        #expect(TileTreeInvariants.isValid(next))
    }

    // MARK: - Directional focus (depth-1 parity with splitFocusTarget)

    @Test("Directional focus across a leading/trailing split")
    func directionalLeadingTrailing() {
        let (state, reducer, left, right) = twoPane(axis: .leadingTrailing)
        // Focus the left tile first.
        var s = reducer.reduce(state, .setFocus(left))

        s = reducer.reduce(s, .focusDirectional(from: left, direction: .right))
        #expect(s.focusedTileID == right)

        s = reducer.reduce(s, .focusDirectional(from: right, direction: .left))
        #expect(s.focusedTileID == left)

        // No vertical neighbor on a leading/trailing split.
        let blocked = reducer.reduce(s, .focusDirectional(from: left, direction: .up))
        #expect(blocked.focusedTileID == left)
        let blocked2 = reducer.reduce(s, .focusDirectional(from: left, direction: .down))
        #expect(blocked2.focusedTileID == left)
    }

    @Test("Directional focus across a top/bottom split")
    func directionalTopBottom() {
        let (state, reducer, top, bottom) = twoPane(axis: .topBottom)
        var s = reducer.reduce(state, .setFocus(top))

        s = reducer.reduce(s, .focusDirectional(from: top, direction: .down))
        #expect(s.focusedTileID == bottom)

        s = reducer.reduce(s, .focusDirectional(from: bottom, direction: .up))
        #expect(s.focusedTileID == top)

        let blocked = reducer.reduce(s, .focusDirectional(from: top, direction: .left))
        #expect(blocked.focusedTileID == top)
    }

    @Test("Directional focus reproduces splitBeforePrimary=true (new tile leads)")
    func directionalInsertBefore() {
        // splitBeforePrimary == true: the new tile is leading (left), original is trailing (right).
        let (state, reducer, original, added) = twoPane(axis: .leadingTrailing, insertNewBefore: true)
        var s = reducer.reduce(state, .setFocus(original))

        // From the right (original) moving left lands on the new leading tile.
        s = reducer.reduce(s, .focusDirectional(from: original, direction: .left))
        #expect(s.focusedTileID == added)

        // From the leftmost tile there is nothing further left.
        let blocked = reducer.reduce(s, .focusDirectional(from: added, direction: .left))
        #expect(blocked.focusedTileID == added)
    }

    // MARK: - Directional focus (depth ≥ 2, cross-axis)
    //
    // Depth-1 directional focus is depth-1 parity above; depth ≥ 2 resolves against unit-square
    // geometry (edge adjacency + max perpendicular overlap, ties toward top/left — #690). These pin
    // the cross-axis cases, the 2×2 grid the pre-geometric ancestor walk got wrong, overlap
    // selection, and true-edge blocking.

    /// Focus `from`, then navigate `direction`; returns the resulting focused tile (== `from` when the
    /// move is blocked, since the reducer leaves focus put when there is no neighbor).
    private func directional(
        _ state: TileTreeState,
        reducer: TileTreeReducer,
        from: TileID,
        _ direction: TileFocusDirection
    ) -> TileID {
        let focused = reducer.reduce(state, .setFocus(from))
        return reducer.reduce(focused, .focusDirectional(from: from, direction: direction)).focusedTileID
    }

    @Test("Directional focus crosses a leading/trailing root into a nested top/bottom column")
    func directionalNestedColumn() {
        // a | (b over c):  left column = a, right column = b (top) / c (bottom).
        let reducer = TileTreeReducer()
        let a = TileID()
        let b = TileID()
        let c = TileID()
        let state = TileTreeState(
            root: .split(
                id: SplitID(),
                axis: .leadingTrailing,
                ratio: 0.5,
                first: .tile(a),
                second: .split(id: SplitID(), axis: .topBottom, ratio: 0.5, first: .tile(b), second: .tile(c))
            ),
            focusedTileID: a
        )

        // Left from either nested pane lands on the single left column.
        #expect(directional(state, reducer: reducer, from: b, .left) == a)
        #expect(directional(state, reducer: reducer, from: c, .left) == a)
        // Right from the left column enters the nested column at its leading (top) edge.
        #expect(directional(state, reducer: reducer, from: a, .right) == b)
        // Vertical moves stay inside the nested top/bottom split.
        #expect(directional(state, reducer: reducer, from: b, .down) == c)
        #expect(directional(state, reducer: reducer, from: c, .up) == b)
        // Blocked edges: no pane above b, none below c, nothing right of the nested column, none above a.
        #expect(directional(state, reducer: reducer, from: b, .up) == b)
        #expect(directional(state, reducer: reducer, from: c, .down) == c)
        #expect(directional(state, reducer: reducer, from: b, .right) == b)
        #expect(directional(state, reducer: reducer, from: a, .up) == a)
    }

    @Test("Directional focus crosses a top/bottom root into a nested leading/trailing row")
    func directionalNestedRow() {
        // a over (b | c):  top row = a, bottom row = b (left) / c (right).
        let reducer = TileTreeReducer()
        let a = TileID()
        let b = TileID()
        let c = TileID()
        let state = TileTreeState(
            root: .split(
                id: SplitID(),
                axis: .topBottom,
                ratio: 0.5,
                first: .tile(a),
                second: .split(id: SplitID(), axis: .leadingTrailing, ratio: 0.5, first: .tile(b), second: .tile(c))
            ),
            focusedTileID: a
        )

        // Up from either nested pane lands on the single top row.
        #expect(directional(state, reducer: reducer, from: b, .up) == a)
        #expect(directional(state, reducer: reducer, from: c, .up) == a)
        // Down from the top row enters the nested row at its leading (left) edge.
        #expect(directional(state, reducer: reducer, from: a, .down) == b)
        // Horizontal moves stay inside the nested leading/trailing split.
        #expect(directional(state, reducer: reducer, from: b, .right) == c)
        #expect(directional(state, reducer: reducer, from: c, .left) == b)
        // Blocked edges: nothing left of b, nothing below the nested row, no horizontal neighbor for a.
        #expect(directional(state, reducer: reducer, from: b, .left) == b)
        #expect(directional(state, reducer: reducer, from: c, .down) == c)
        #expect(directional(state, reducer: reducer, from: a, .left) == a)
    }

    @Test("Directional focus in a 2×2 grid respects perpendicular position")
    func directionalGridRespectsPosition() {
        // (a | b) over (c | d): a top-left, b top-right, c bottom-left, d bottom-right.
        let reducer = TileTreeReducer()
        let a = TileID()
        let b = TileID()
        let c = TileID()
        let d = TileID()
        let state = TileTreeState(
            root: .split(
                id: SplitID(),
                axis: .topBottom,
                ratio: 0.5,
                first: .split(id: SplitID(), axis: .leadingTrailing, ratio: 0.5, first: .tile(a), second: .tile(b)),
                second: .split(id: SplitID(), axis: .leadingTrailing, ratio: 0.5, first: .tile(c), second: .tile(d))
            ),
            focusedTileID: a
        )

        // Vertical moves land in the same column — the case the pre-geometric walk got wrong
        // (down from b used to land on c, the first leaf of the bottom subtree).
        #expect(directional(state, reducer: reducer, from: b, .down) == d)
        #expect(directional(state, reducer: reducer, from: a, .down) == c)
        #expect(directional(state, reducer: reducer, from: d, .up) == b)
        #expect(directional(state, reducer: reducer, from: c, .up) == a)
        // Horizontal moves stay in the same row.
        #expect(directional(state, reducer: reducer, from: a, .right) == b)
        #expect(directional(state, reducer: reducer, from: d, .left) == c)
        // True edges are blocked in all four corners.
        #expect(directional(state, reducer: reducer, from: a, .left) == a)
        #expect(directional(state, reducer: reducer, from: b, .up) == b)
        #expect(directional(state, reducer: reducer, from: c, .down) == c)
        #expect(directional(state, reducer: reducer, from: d, .right) == d)
    }

    @Test("Directional focus picks the neighbor with the largest perpendicular overlap")
    func directionalMaxOverlap() {
        // a over (c | d) with the bottom split off-center at 0.3: a spans the full width, so both
        // bottom panes face it — d overlaps 0.7 vs c's 0.3 and must win.
        let reducer = TileTreeReducer()
        let a = TileID()
        let c = TileID()
        let d = TileID()
        let state = TileTreeState(
            root: .split(
                id: SplitID(),
                axis: .topBottom,
                ratio: 0.5,
                first: .tile(a),
                second: .split(id: SplitID(), axis: .leadingTrailing, ratio: 0.3, first: .tile(c), second: .tile(d))
            ),
            focusedTileID: a
        )

        #expect(directional(state, reducer: reducer, from: a, .down) == d)
        // Ties (equal overlap) break toward the top/left: both bottom panes reach a going up.
        #expect(directional(state, reducer: reducer, from: c, .up) == a)
        #expect(directional(state, reducer: reducer, from: d, .up) == a)
    }

    @Test("Directional focus at depth 3 crosses only true shared edges")
    func directionalDepthThree() {
        // a | (b over (c | d)): a is a full-height column; the right column stacks b over a
        // nested row of c | d. d does not touch a, so d ← must land on c, not skip to a.
        let reducer = TileTreeReducer()
        let a = TileID()
        let b = TileID()
        let c = TileID()
        let d = TileID()
        let state = TileTreeState(
            root: .split(
                id: SplitID(),
                axis: .leadingTrailing,
                ratio: 0.5,
                first: .tile(a),
                second: .split(
                    id: SplitID(),
                    axis: .topBottom,
                    ratio: 0.5,
                    first: .tile(b),
                    second: .split(
                        id: SplitID(), axis: .leadingTrailing, ratio: 0.5, first: .tile(c), second: .tile(d))
                )
            ),
            focusedTileID: a
        )

        #expect(directional(state, reducer: reducer, from: d, .left) == c)
        #expect(directional(state, reducer: reducer, from: c, .left) == a)
        #expect(directional(state, reducer: reducer, from: d, .up) == b)
        #expect(directional(state, reducer: reducer, from: c, .up) == b)
        // From a, both b (0.5 overlap) and c (0.5 overlap) face right; tie breaks to the top: b.
        #expect(directional(state, reducer: reducer, from: a, .right) == b)
        // b spans the full right column width; moving down, c and d tie — top/left wins: c.
        #expect(directional(state, reducer: reducer, from: b, .down) == c)
    }

    // MARK: - Relative focus

    @Test("Relative focus toggles between two leaves and wraps")
    func relativeFocusTwoLeaves() {
        let (state, reducer, first, second) = twoPane(axis: .leadingTrailing)
        var s = reducer.reduce(state, .setFocus(first))

        s = reducer.reduce(s, .focusRelative(from: first, order: .next))
        #expect(s.focusedTileID == second)

        s = reducer.reduce(s, .focusRelative(from: second, order: .next))
        #expect(s.focusedTileID == first)  // wraps

        s = reducer.reduce(s, .focusRelative(from: first, order: .previous))
        #expect(s.focusedTileID == second)  // wraps backward
    }

    @Test("Relative focus on a single tile is a no-op")
    func relativeFocusSingle() {
        let gen = IDGen()
        let reducer = makeReducer(gen)
        let t1 = gen.tile()
        let state = TileTreeState(singleTile: t1)
        let next = reducer.reduce(state, .focusRelative(from: t1, order: .next))
        #expect(next == state)
    }

    // MARK: - Resize / equalize

    @Test("Resize adds the delta and clamps to the legal range")
    func resizeClamps() {
        let (state, reducer, _, _) = twoPane(axis: .leadingTrailing)
        guard case .split(let splitID, _, _, _, _) = state.root else {
            Issue.record("expected a split")
            return
        }

        var s = reducer.reduce(state, .resize(split: splitID, ratioDelta: 0.05))
        #expect(ratio(of: s.root) == 0.55)

        // Push well past the maximum; it should clamp.
        s = reducer.reduce(s, .resize(split: splitID, ratioDelta: 1.0))
        #expect(ratio(of: s.root) == TileTreeLayout.maximumRatio)

        // Push well below the minimum; it should clamp.
        s = reducer.reduce(s, .resize(split: splitID, ratioDelta: -1.0))
        #expect(ratio(of: s.root) == TileTreeLayout.minimumRatio)
    }

    @Test("setRatio clamps to the legal range")
    func setRatioClamps() {
        let (state, reducer, _, _) = twoPane(axis: .leadingTrailing)
        guard case .split(let splitID, _, _, _, _) = state.root else {
            Issue.record("expected a split")
            return
        }
        let high = reducer.reduce(state, .setRatio(split: splitID, ratio: 0.95))
        #expect(ratio(of: high.root) == TileTreeLayout.maximumRatio)
        let low = reducer.reduce(state, .setRatio(split: splitID, ratio: 0.01))
        #expect(ratio(of: low.root) == TileTreeLayout.minimumRatio)
    }

    @Test("Non-finite ratios resolve to valid split fractions")
    func nonFiniteRatiosStayValid() {
        let (state, reducer, _, _) = twoPane(axis: .leadingTrailing)
        guard case .split(let splitID, _, _, _, _) = state.root else {
            Issue.record("expected a split")
            return
        }

        let nan = reducer.reduce(state, .setRatio(split: splitID, ratio: .nan))
        #expect(ratio(of: nan.root) == TileTreeLayout.defaultRatio)
        #expect(TileTreeInvariants.isValid(nan))

        let high = reducer.reduce(state, .setRatio(split: splitID, ratio: .infinity))
        #expect(ratio(of: high.root) == TileTreeLayout.maximumRatio)
        #expect(TileTreeInvariants.isValid(high))

        let low = reducer.reduce(state, .resize(split: splitID, ratioDelta: -.infinity))
        #expect(ratio(of: low.root) == TileTreeLayout.minimumRatio)
        #expect(TileTreeInvariants.isValid(low))
    }

    @Test("Resize on an unknown split is a no-op")
    func resizeUnknownNoOp() {
        let (state, reducer, _, _) = twoPane(axis: .leadingTrailing)
        let next = reducer.reduce(state, .resize(split: SplitID(), ratioDelta: 0.1))
        #expect(next == state)
    }

    @Test("Equalize resets every split ratio to the default")
    func equalizeWholeTree() {
        let gen = IDGen()
        let reducer = makeReducer(gen)
        var state = TileTreeState(singleTile: gen.tile())
        // Build two nested splits and skew their ratios.
        state = reducer.reduce(
            state, .split(parent: state.focusedTileID, axis: .leadingTrailing, insertNewBefore: false))
        state = reducer.reduce(state, .split(parent: state.focusedTileID, axis: .topBottom, insertNewBefore: false))
        for splitID in state.root.splitIDs {
            state = reducer.reduce(state, .setRatio(split: splitID, ratio: 0.75))
        }
        #expect(allRatios(state.root).allSatisfy { $0 == 0.75 })

        let equalized = reducer.reduce(state, .equalize(subtreeRoot: nil))
        #expect(allRatios(equalized.root).allSatisfy { $0 == TileTreeLayout.defaultRatio })
    }

    @Test("Equalize with a subtree root only touches that subtree")
    func equalizeSubtree() {
        let gen = IDGen()
        let reducer = makeReducer(gen)
        var state = TileTreeState(singleTile: gen.tile())
        state = reducer.reduce(
            state, .split(parent: state.focusedTileID, axis: .leadingTrailing, insertNewBefore: false))
        let outerSplit = state.root.splitIDs[0]
        state = reducer.reduce(state, .split(parent: state.focusedTileID, axis: .topBottom, insertNewBefore: false))
        let innerSplit = state.root.splitIDs.first { $0 != outerSplit }!

        state = reducer.reduce(state, .setRatio(split: outerSplit, ratio: 0.7))
        state = reducer.reduce(state, .setRatio(split: innerSplit, ratio: 0.7))

        let equalized = reducer.reduce(state, .equalize(subtreeRoot: innerSplit))
        #expect(ratioOfSplit(equalized.root, outerSplit) == 0.7)  // untouched
        #expect(ratioOfSplit(equalized.root, innerSplit) == TileTreeLayout.defaultRatio)
    }

    // MARK: - setFocus

    @Test("setFocus moves focus to a live leaf and ignores unknown tiles")
    func setFocusBehavior() {
        let (state, reducer, original, added) = twoPane(axis: .leadingTrailing)
        let focused = reducer.reduce(state, .setFocus(original))
        #expect(focused.focusedTileID == original)

        let ignored = reducer.reduce(focused, .setFocus(TileID()))
        #expect(ignored.focusedTileID == original)
        _ = added
    }

    // MARK: - Helpers

    private func ratio(of node: TileTree) -> Double? {
        guard case .split(_, _, let ratio, _, _) = node else { return nil }
        return ratio
    }

    private func allRatios(_ node: TileTree) -> [Double] {
        switch node {
        case .tile: return []
        case .split(_, _, let ratio, let first, let second):
            return [ratio] + allRatios(first) + allRatios(second)
        }
    }

    private func ratioOfSplit(_ node: TileTree, _ target: SplitID) -> Double? {
        switch node {
        case .tile: return nil
        case .split(let id, _, let ratio, let first, let second):
            if id == target { return ratio }
            return ratioOfSplit(first, target) ?? ratioOfSplit(second, target)
        }
    }
}
