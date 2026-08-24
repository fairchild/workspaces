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

    @MainActor
    private final class Flag {
        var value = false
    }

    @Test("enqueueOnMain defers the operation even when called on the main thread")
    @MainActor
    func enqueueOnMainDefersOnMain() async {
        let ran = Flag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            GhosttyThreadingBridge.enqueueOnMain {
                ran.value = true
                continuation.resume()
            }
            #expect(!ran.value, "the wakeup tick must never run inline — see #1251")
        }
        #expect(ran.value)
    }

    @Test("enqueueOnMain executes its operation on the main thread from a background caller")
    func enqueueOnMainExecutesOnMainThreadFromBackground() async {
        let ranOnMain = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task.detached {
                GhosttyThreadingBridge.enqueueOnMain {
                    continuation.resume(returning: Thread.isMainThread)
                }
            }
        }
        #expect(ranOnMain)
    }
}
