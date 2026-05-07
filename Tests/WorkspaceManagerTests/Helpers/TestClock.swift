//
//  TestClock.swift
//  WorkspaceManagerTests
//
//  Thread-safe controllable clock for tests that need to inject deterministic
//  time progression into `@Sendable () -> Date` closures (e.g. the registry's
//  OSC dedup window). Capturing a mutable local from a Sendable closure is a
//  Swift 6 concurrency error; this helper holds the mutable date behind an
//  unfair lock so the closure remains genuinely Sendable.
//

import Foundation

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) {
        self.current = start
    }

    /// Returns a `@Sendable` closure suitable for `AgentSessionRegistry(clock:)`.
    var now: @Sendable () -> Date {
        { [self] in
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.current
        }
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }

    func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }
}
