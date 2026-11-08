//
//  GhosttySurfaceMailboxDeadlockTests.swift
//  WorkspaceManagerAppTests
//
//  Guards surface teardown against the app-mailbox deadlock (#1856). Every surface's `io`
//  threads push title and exit messages into one 64-slot app mailbox that only the main
//  thread drains, and `ghostty_surface_free` joins those threads. Freeing behind a full
//  mailbox hangs for good, so a regression here hangs rather than fails: to see where, run
//  the suite under `scripts/watch-swift-test.sh`, which samples and stops a stalled run.
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("GhosttySurface mailbox deadlock", .serialized)
@MainActor
struct GhosttySurfaceMailboxDeadlockTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    private static let mailboxCapacity = 64
    private static let maximumSurfaces = 96
    nonisolated private static let minimumSurfaces = min(
        max(environment["WORKSPACES_MAILBOX_DEADLOCK_SURFACES"].flatMap { Int($0) } ?? 24, 1), 96)

    @Test("Releasing surface views while the app mailbox is full and undrained frees every surface")
    func freeWhileMailboxIsFull() async throws {
        let log = DeadlockProgressLog(path: Self.environment["WORKSPACES_MAILBOX_DEADLOCK_PROGRESS"])
        var views: [GhosttySurfaceView] = []

        // The main thread stays blocked from here to the last release, so the app never ticks
        // and nothing drains the mailbox. Each shell's startup pushes a few messages; more
        // surfaces join until 64 pushes prove the mailbox filled.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        let wakeupsBefore = GhosttyAppManager.wakeupCount.withLock { $0 }
        var mailboxFilled: Bool {
            GhosttyAppManager.wakeupCount.withLock { $0 } - wakeupsBefore >= Self.mailboxCapacity
        }
        addSurfaces(Self.minimumSurfaces, to: &views)
        var lastAdded = clock.now
        while !mailboxFilled, clock.now < deadline {
            if clock.now - lastAdded > .seconds(1), views.count < Self.maximumSurfaces {
                addSurfaces(min(8, Self.maximumSurfaces - views.count), to: &views)
                lastAdded = clock.now
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(mailboxFilled, "the app mailbox never filled, so the test would prove nothing")
        let everyViewHasSurface = views.allSatisfy { $0.isSurfaceAlive }
        try #require(everyViewHasSurface, "every view needs a Ghostty surface for the test to free")
        let count = views.count
        let released = views.map { WeakSurfaceView($0) }
        log.write("mailbox full with \(count) surfaces")

        for index in 0..<count {
            log.write("releasing \(index)")
            autoreleasepool { _ = views.removeFirst() }
        }
        log.write("released \(count) views; waiting for their surfaces to be freed")
        #expect(GhosttyAppManager.shared.retiredSurfaceCount >= count)
        while GhosttyAppManager.shared.retiredSurfaceCount > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        log.write("end")
        #expect(released.allSatisfy { $0.view == nil })
    }

    private func addSurfaces(_ count: Int, to views: inout [GhosttySurfaceView]) {
        let directory = FileManager.default.temporaryDirectory
        autoreleasepool {
            views += (0..<count).map { _ in GhosttySurfaceView(workingDirectory: directory) }
        }
    }
}

private struct WeakSurfaceView {
    weak var view: GhosttySurfaceView?

    init(_ view: GhosttySurfaceView) {
        self.view = view
    }
}

/// One flushed line per step, so a watchdog sees the free that never returned.
private struct DeadlockProgressLog {
    private let handle: FileHandle?

    init(path: String?) {
        guard let path else {
            handle = nil
            return
        }
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func write(_ line: String) {
        guard let handle else { return }
        handle.write(Data("\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)\n".utf8))
        try? handle.synchronize()
    }
}
