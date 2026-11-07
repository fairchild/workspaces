//
//  GhosttySurfaceMailboxDeadlockTests.swift
//  WorkspaceManagerAppTests
//
//  Reproduces the surface-teardown deadlock from #1842. Every surface's `io-reader` pushes
//  title and exit messages into one 64-slot app mailbox that only the main thread drains.
//  When it is full, `ghostty_surface_free` on main joins `io`, which joins an `io-reader`
//  blocked on that push forever. Opt-in, because today it hangs: run it under
//  `scripts/watch-swift-test.sh`, where it passes once teardown drains or skips the mailbox.
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("GhosttySurface mailbox deadlock", .serialized)
@MainActor
struct GhosttySurfaceMailboxDeadlockTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    nonisolated private static let surfaceCount = environment["WORKSPACES_MAILBOX_DEADLOCK_SURFACES"].flatMap {
        Int($0)
    }

    @Test(
        "Freeing a surface while the app mailbox is full and undrained finishes",
        .enabled(if: surfaceCount != nil, "set WORKSPACES_MAILBOX_DEADLOCK_SURFACES to run; it hangs today")
    )
    func freeWhileMailboxIsFull() throws {
        let count = try #require(Self.surfaceCount)
        let log = DeadlockProgressLog(path: Self.environment["WORKSPACES_MAILBOX_DEADLOCK_PROGRESS"])
        let directory = FileManager.default.temporaryDirectory
        var views: [GhosttySurfaceView] = []
        autoreleasepool {
            views = (0..<count).map { _ in GhosttySurfaceView(workingDirectory: directory) }
        }

        // Each shell's startup sends about three messages; blocking main keeps the app from
        // ticking, so 24 or more surfaces fill the mailbox before the first free.
        log.write("created \(count) surfaces; blocking main for 3s")
        Thread.sleep(forTimeInterval: 3)

        for index in 0..<count {
            log.write("freeing \(index)")
            autoreleasepool { _ = views.removeFirst() }
        }
        log.write("end")
        #expect(views.isEmpty)
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
