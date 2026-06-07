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

    // MARK: - Relative focus

    @Test("Relative focus toggles between two leaves and wraps")
    func relativeFocusTwoLeaves() {
        let (state, reducer, first, second) = twoPane(axis: .leadingTrailing)
        var s = reducer.reduce(state, .setFocus(first))

        s = reducer.reduce(s, .focusRelative(from: first, order: .next))
        #expect(s.focusedTileID == second)

        s = reducer.reduce(s, .focusRelative(from: second, order: .next))
        #expect(s.focusedTileID == first) // wraps

        s = reducer.reduce(s, .focusRelative(from: first, order: .previous))
        #expect(s.focusedTileID == second) // wraps backward
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
        state = reducer.reduce(state, .split(parent: state.focusedTileID, axis: .leadingTrailing, insertNewBefore: false))
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
        state = reducer.reduce(state, .split(parent: state.focusedTileID, axis: .leadingTrailing, insertNewBefore: false))
        let outerSplit = state.root.splitIDs[0]
        state = reducer.reduce(state, .split(parent: state.focusedTileID, axis: .topBottom, insertNewBefore: false))
        let innerSplit = state.root.splitIDs.first { $0 != outerSplit }!

        state = reducer.reduce(state, .setRatio(split: outerSplit, ratio: 0.7))
        state = reducer.reduce(state, .setRatio(split: innerSplit, ratio: 0.7))

        let equalized = reducer.reduce(state, .equalize(subtreeRoot: innerSplit))
        #expect(ratioOfSplit(equalized.root, outerSplit) == 0.7) // untouched
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
