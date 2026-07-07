//
//  WorkspaceStatusAggregationCoalescer.swift
//  WorkspaceManager
//
//  Coalesces high-frequency sidebar status-aggregation requests into one
//  trailing-edge pass per window. Agent status events arrive several times a
//  second during active sessions, and each aggregation is an
//  O(repos × workspaces × sessions) rebuild, so collapsing a burst into a single
//  pass bounds the work under sustained load. The last request in a window always
//  runs, so the sidebar never settles on stale status.
//

import Foundation

@MainActor
final class WorkspaceStatusAggregationCoalescer {
    private let window: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private var pendingWork: (@MainActor () -> Void)?
    private var flushTask: Task<Void, Never>?

    init(
        window: Duration = .milliseconds(100),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.window = window
        self.sleep = sleep
    }

    /// Requests an aggregation pass. Rapid calls within the window collapse to a
    /// single trailing-edge execution of the most recently supplied `work`.
    func schedule(_ work: @escaping @MainActor () -> Void) {
        pendingWork = work
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(self.window)
            self.flushTask = nil
            let pending = self.pendingWork
            self.pendingWork = nil
            pending?()
        }
    }

    /// Drops any queued pass without running it. Used on teardown so a parked
    /// window can't fire against a torn-down view.
    func cancel() {
        flushTask?.cancel()
        flushTask = nil
        pendingWork = nil
    }
}
