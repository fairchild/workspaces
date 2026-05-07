//
//  WaitUntil.swift
//  WorkspaceManagerTests
//
//  Polling helper for tests that observe an asynchronous side effect crossing
//  actor boundaries. Replaces fixed `Task.sleep` waits whose duration races on
//  slower CI runners.
//

import Foundation

/// Poll `condition` until it returns true or `timeout` elapses. Returns whether
/// the condition was met. Use a small `pollInterval` so we don't busy-spin.
@discardableResult
func waitUntil(
    timeout: TimeInterval = 2.0,
    pollInterval: TimeInterval = 0.025,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        let nanos = UInt64(pollInterval * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }
    return await condition()
}
