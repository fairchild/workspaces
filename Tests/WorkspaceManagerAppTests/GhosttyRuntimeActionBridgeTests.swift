//
//  GhosttyRuntimeActionBridgeTests.swift
//  WorkspaceManagerAppTests
//
//  Terminal attention fallback: confirms the runtime bridge recognizes the
//  desktop-notification and bell action tags and routes them through
//  `runOnMainAsync` to a resolved surface view. The full end-to-end registry
//  integration is covered by OSCDedupIntegrationTests in WorkspaceManagerTests.
//

import Foundation
import GhosttyKit
import Testing

@testable import WorkspaceManager

@Suite("GhosttyRuntimeActionBridge — terminal attention dispatch")
struct GhosttyRuntimeActionBridgeTests {

    @Test("DESKTOP_NOTIFICATION returns true and schedules main-thread work")
    func desktopNotificationDispatches() async throws {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_DESKTOP_NOTIFICATION
        // Leave title/body as null cstrings — the bridge tolerates nil and the
        // resolver below short-circuits before we'd dereference them.
        let target = ghostty_target_s()
        let scheduledCount = LockedCounter()
        let handled = GhosttyRuntimeActionBridge.handle(
            target: target,
            action: action,
            resolveSurfaceAddress: { _ in 0xDEAD_BEEF },
            resolveSurfaceView: { _ in nil },
            runOnMainAsync: { closure in
                scheduledCount.increment()
                _ = closure  // Don't actually run; we only assert it was queued.
            }
        )
        #expect(handled == true)
        #expect(scheduledCount.value == 1)
    }

    @Test("RING_BELL returns true and schedules main-thread work")
    func ringBellDispatches() async throws {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RING_BELL
        let target = ghostty_target_s()
        let scheduledCount = LockedCounter()
        let handled = GhosttyRuntimeActionBridge.handle(
            target: target,
            action: action,
            resolveSurfaceAddress: { _ in 0x1 },
            resolveSurfaceView: { _ in nil },
            runOnMainAsync: { closure in
                scheduledCount.increment()
                _ = closure
            }
        )
        #expect(handled == true)
        #expect(scheduledCount.value == 1)
    }

    @Test("Unrecognized action tag still returns false (default fall-through)")
    func unknownActionStillFallsThrough() async {
        var action = ghostty_action_s()
        // SCROLLBAR is not handled by the bridge; verify the default branch.
        action.tag = GHOSTTY_ACTION_SCROLLBAR
        let target = ghostty_target_s()
        let handled = GhosttyRuntimeActionBridge.handle(
            target: target,
            action: action,
            resolveSurfaceAddress: { _ in 0x1 },
            resolveSurfaceView: { _ in nil },
            runOnMainAsync: { _ in }
        )
        #expect(handled == false)
    }

    @Test("Bridge skips entirely when surface address resolution fails")
    func unresolvedSurfaceAddressShortCircuits() async {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_DESKTOP_NOTIFICATION
        let target = ghostty_target_s()
        let handled = GhosttyRuntimeActionBridge.handle(
            target: target,
            action: action,
            resolveSurfaceAddress: { _ in nil },
            resolveSurfaceView: { _ in nil },
            runOnMainAsync: { _ in
                Issue.record("runOnMainAsync should not be invoked when address is nil")
            }
        )
        #expect(handled == false)
    }
}

/// Tiny thread-safe counter so the captured `runOnMainAsync` callbacks can record
/// invocations without crossing actor boundaries.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}
