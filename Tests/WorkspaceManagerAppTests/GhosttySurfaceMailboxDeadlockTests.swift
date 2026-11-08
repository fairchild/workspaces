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
    nonisolated private static let surfaceCount =
        environment["WORKSPACES_MAILBOX_DEADLOCK_SURFACES"].flatMap { Int($0) } ?? 24

    @Test("Releasing surface views while the app mailbox is full and undrained frees every surface")
    func freeWhileMailboxIsFull() async throws {
        let count = Self.surfaceCount
        try #require(
            count >= 24, "fewer than 24 surfaces do not fill the 64-slot mailbox, so the test would prove nothing")
        let log = DeadlockProgressLog(path: Self.environment["WORKSPACES_MAILBOX_DEADLOCK_PROGRESS"])
        let directory = FileManager.default.temporaryDirectory
        var views: [GhosttySurfaceView] = []
        autoreleasepool {
            views = (0..<count).map { _ in GhosttySurfaceView(workingDirectory: directory) }
        }
        let everyViewHasSurface = views.allSatisfy { $0.isSurfaceAlive }
        try #require(everyViewHasSurface, "every view needs a Ghostty surface for the test to free")
        let released = views.map { WeakSurfaceView($0) }

        // Each shell's startup sends about three messages; blocking main keeps the app from
        // ticking, so 24 or more surfaces fill the mailbox before the first view goes. Without
        // the block the frees race the shells' startup and the mailbox never fills.
        log.write("created \(count) surfaces; blocking main for 3s")
        Thread.sleep(forTimeInterval: 3)

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
