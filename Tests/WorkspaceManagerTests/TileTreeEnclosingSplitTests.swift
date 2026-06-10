//
//  TileTreeEnclosingSplitTests.swift
//  WorkspaceManagerTests
//
//  Covers `TileTree.enclosingSplit(of:)` — the lookup that lets resize target the split around the
//  focused pane at any depth rather than assuming the root.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("TileTree.enclosingSplit")
struct TileTreeEnclosingSplitTests {
    private let primary = TileID()
    private let a = TileID()
    private let b = TileID()
    private let root = SplitID()
    private let inner = SplitID()

    /// `primary | (a / b)` — a left/right root whose trailing child is a top/bottom split.
    private var tree: TileTree {
        .split(
            id: root,
            axis: .leadingTrailing,
            ratio: 0.5,
            first: .tile(primary),
            second: .split(id: inner, axis: .topBottom, ratio: 0.5, first: .tile(a), second: .tile(b))
        )
    }

    @Test("A tile directly under the root reports the root split and its side")
    func tileUnderRoot() throws {
        let enclosing = try #require(tree.enclosingSplit(of: primary))
        #expect(enclosing.id == root)
        #expect(enclosing.axis == .leadingTrailing)
        #expect(enclosing.leafIsFirst)
    }

    @Test("A nested tile reports its innermost split, not the root")
    func nestedTileReportsInnermostSplit() throws {
        let topPane = try #require(tree.enclosingSplit(of: a))
        #expect(topPane.id == inner)
        #expect(topPane.axis == .topBottom)
        #expect(topPane.leafIsFirst)

        let bottomPane = try #require(tree.enclosingSplit(of: b))
        #expect(bottomPane.id == inner)
        #expect(!bottomPane.leafIsFirst)
    }

    @Test("A bare tile and an absent tile have no enclosing split")
    func bareAndAbsentTilesHaveNoEnclosingSplit() {
        #expect(TileTree.tile(primary).enclosingSplit(of: primary) == nil)
        #expect(tree.enclosingSplit(of: TileID()) == nil)
    }
}
