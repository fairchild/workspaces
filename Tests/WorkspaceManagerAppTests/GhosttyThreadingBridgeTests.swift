//
//  GhosttyThreadingBridgeTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("GhosttyThreadingBridge")
struct GhosttyThreadingBridgeTests {
    @Test("runOnMainSync returns the operation's value when already on the main thread")
    @MainActor
    func runOnMainSyncReturnsValueOnMain() {
        let value = GhosttyThreadingBridge.runOnMainSync { 42 }
        #expect(value == 42)
    }

    @Test("runOnMainSync hops to main from a background thread and returns the operation's value")
    func runOnMainSyncHopsFromBackground() async {
        let value = await Task.detached {
            GhosttyThreadingBridge.runOnMainSync { "hello" }
        }.value
        #expect(value == "hello")
    }

    @Test("runOnMainSync executes its operation on the main thread when hopped from a background caller")
    func runOnMainSyncExecutesOnMainThreadFromBackground() async {
        let ranOnMain = await Task.detached {
            GhosttyThreadingBridge.runOnMainSync { Thread.isMainThread }
        }.value
        #expect(ranOnMain)
    }
}
