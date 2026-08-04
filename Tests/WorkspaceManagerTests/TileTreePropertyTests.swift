// swift-format-ignore-file: NeverForceUnwrap
// Test fixtures/helpers force-unwrap known-good literals or generator output; a failure here is a loud test crash, not a user-facing risk.
//
//  TileTreePropertyTests.swift
//  WorkspaceManagerTests
//
//  Randomized operation-sequence tests: the reducer must keep every tree invariant after each
//  action, and `close` must remove exactly the closed leaf (the property that makes
//  `SurfaceStore.sync(activeLeafIDs:)` correct).
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("TileTreeProperty")
struct TileTreePropertyTests {
    /// Deterministic SplitMix64 so a failing seed reproduces exactly.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

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

    private func randomAction(
        for state: TileTreeState,
        using rng: inout SeededGenerator
    ) -> TileTreeAction {
        let leaves = state.leafIDs
        let splits = state.splitIDs
        let axes: [SplitAxis] = [.leadingTrailing, .topBottom]
        let directions: [TileFocusDirection] = [.up, .down, .left, .right]
        let deltas: [Double] = [-0.4, -0.05, 0.05, 0.4]

        switch Int.random(in: 0..<8, using: &rng) {
        case 0:
            return .split(
                parent: leaves.randomElement(using: &rng)!,
                axis: axes.randomElement(using: &rng)!,
                insertNewBefore: Bool.random(using: &rng)
            )
        case 1:
            return .close(leaves.randomElement(using: &rng)!)
        case 2:
            return .focusDirectional(
                from: leaves.randomElement(using: &rng)!,
                direction: directions.randomElement(using: &rng)!
            )
        case 3:
            return .focusRelative(
                from: leaves.randomElement(using: &rng)!,
                order: Bool.random(using: &rng) ? .next : .previous
            )
        case 4 where !splits.isEmpty:
            return .resize(split: splits.randomElement(using: &rng)!, ratioDelta: deltas.randomElement(using: &rng)!)
        case 5 where !splits.isEmpty:
            return .setRatio(
                split: splits.randomElement(using: &rng)!, ratio: Double.random(in: -0.5...1.5, using: &rng))
        case 6:
            return .equalize(subtreeRoot: splits.randomElement(using: &rng))
        default:
            return .setFocus(leaves.randomElement(using: &rng)!)
        }
    }

    @Test("Invariants hold and IDs stay unique across randomized sequences", arguments: 0..<64)
    func invariantsUnderRandomSequences(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed) &+ 1)
        let gen = IDGen()
        let reducer = TileTreeReducer(makeTileID: gen.tile, makeSplitID: gen.split)
        var state = TileTreeState(singleTile: gen.tile())

        for step in 0..<80 {
            let action = randomAction(for: state, using: &rng)
            let leavesBefore = state.leafIDs
            state = reducer.reduce(state, action)

            let violations = TileTreeInvariants.violations(in: state)
            #expect(violations.isEmpty, "seed=\(seed) step=\(step) action=\(action) violations=\(violations)")
            #expect(Set(state.leafIDs).count == state.leafIDs.count)
            #expect(Set(state.splitIDs).count == state.splitIDs.count)
            #expect(state.leafIDs.contains(state.focusedTileID))

            // close on a multi-leaf tree removes exactly the target leaf.
            if case .close(let target) = action, leavesBefore.count > 1, leavesBefore.contains(target) {
                #expect(Set(state.leafIDs) == Set(leavesBefore).subtracting([target]))
            }
        }
    }

    @Test("Directional focus is a true geometric neighbor — or a true edge", arguments: 0..<48)
    func directionalFocusIsGeometric(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed) &+ 5000)
        let gen = IDGen()
        let reducer = TileTreeReducer(makeTileID: gen.tile, makeSplitID: gen.split)
        var state = TileTreeState(singleTile: gen.tile())

        // Grow a random tree (splits/resizes only, biased deep), then probe every leaf × direction.
        for _ in 0..<10 {
            let action = randomAction(for: state, using: &rng)
            switch action {
            case .split, .resize, .setRatio:
                state = reducer.reduce(state, action)
            default:
                break
            }
        }

        let frames = state.root.unitLeafFrames()
        let directions: [TileFocusDirection] = [.up, .down, .left, .right]
        for from in state.leafIDs {
            let origin = frames[from]!
            for direction in directions {
                let next = reducer.reduce(
                    reducer.reduce(state, .setFocus(from)),
                    .focusDirectional(from: from, direction: direction)
                )
                let target = next.focusedTileID == from ? nil : next.focusedTileID

                // Independently derive the facing candidates (with overlap and perpendicular
                // position) from the frames.
                let candidates: [(id: TileID, overlap: Double, position: Double)] = frames.compactMap {
                    id, rect in
                    guard id != from else { return nil }
                    let facing: Bool
                    let overlap: Double
                    let position: Double
                    switch direction {
                    case .right:
                        facing = rect.minX == origin.maxX
                        overlap = min(rect.maxY, origin.maxY) - max(rect.minY, origin.minY)
                        position = rect.minY
                    case .left:
                        facing = rect.maxX == origin.minX
                        overlap = min(rect.maxY, origin.maxY) - max(rect.minY, origin.minY)
                        position = rect.minY
                    case .down:
                        facing = rect.minY == origin.maxY
                        overlap = min(rect.maxX, origin.maxX) - max(rect.minX, origin.minX)
                        position = rect.minX
                    case .up:
                        facing = rect.maxY == origin.minY
                        overlap = min(rect.maxX, origin.maxX) - max(rect.minX, origin.minX)
                        position = rect.minX
                    }
                    guard facing, overlap > 0 else { return nil }
                    return (id, overlap, position)
                }

                if let target {
                    let chosen = candidates.first { $0.id == target }
                    #expect(
                        chosen != nil,
                        "seed=\(seed) \(direction): target \(target) is not a facing neighbor of \(from)"
                    )
                    // The winner must be overlap-optimal, ties broken toward the top/left.
                    if let chosen {
                        let beaten = candidates.allSatisfy { candidate in
                            candidate.overlap < chosen.overlap
                                || (candidate.overlap == chosen.overlap && candidate.position >= chosen.position)
                        }
                        #expect(
                            beaten,
                            "seed=\(seed) \(direction): \(target) is not the max-overlap/top-left candidate"
                        )
                    }
                } else {
                    #expect(
                        candidates.isEmpty,
                        "seed=\(seed) \(direction): move from \(from) was blocked despite facing neighbors \(candidates.map(\.id))"
                    )
                }
            }
        }
    }

    @Test("Split grows the leaf set by exactly one and focuses the new tile", arguments: 0..<32)
    func splitAddsOneLeaf(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed) &+ 1000)
        let gen = IDGen()
        let reducer = TileTreeReducer(makeTileID: gen.tile, makeSplitID: gen.split)
        var state = TileTreeState(singleTile: gen.tile())

        // Grow to a few leaves with random splits, checking the +1 property each time.
        for _ in 0..<12 {
            let leavesBefore = Set(state.leafIDs)
            let parent = state.leafIDs.randomElement(using: &rng)!
            state = reducer.reduce(
                state,
                .split(
                    parent: parent,
                    axis: [SplitAxis.leadingTrailing, .topBottom].randomElement(using: &rng)!,
                    insertNewBefore: Bool.random(using: &rng)
                )
            )
            let leavesAfter = Set(state.leafIDs)
            #expect(leavesAfter.count == leavesBefore.count + 1)
            #expect(leavesBefore.isSubset(of: leavesAfter))
            let added = leavesAfter.subtracting(leavesBefore)
            #expect(added.count == 1)
            #expect(state.focusedTileID == added.first)
        }
    }

    @Test("Codable round-trips preserve the tree and focus")
    func codableRoundTrip() {
        let gen = IDGen()
        let reducer = TileTreeReducer(makeTileID: gen.tile, makeSplitID: gen.split)
        var state = TileTreeState(singleTile: gen.tile())
        state = reducer.reduce(
            state, .split(parent: state.focusedTileID, axis: .leadingTrailing, insertNewBefore: false))
        state = reducer.reduce(state, .split(parent: state.focusedTileID, axis: .topBottom, insertNewBefore: true))

        let data = try! JSONEncoder().encode(state)
        let decoded = try! JSONDecoder().decode(TileTreeState.self, from: data)
        #expect(decoded == state)
    }
}
