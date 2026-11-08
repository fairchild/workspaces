//
//  GhosttySurfaceMailboxDeadlockTests.swift
//  WorkspaceManagerAppTests
//
//  Guards surface teardown against the app-mailbox deadlock (#1856). Every surface's `io`
//  threads push title and exit messages into one 64-slot app mailbox that only a main-thread
//  tick drains, and `ghostty_surface_free` joins those threads. Freeing behind a full mailbox
//  blocks the main thread for good, so a regression here hangs rather than fails: to see
//  where, run the suite under `scripts/watch-swift-test.sh`, which samples a stalled run.
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("GhosttySurface mailbox deadlock", .serialized)
@MainActor
final class GhosttySurfaceMailboxDeadlockTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    private static let mailboxCapacity = 64
    private static let maximumSurfaces = 96
    nonisolated private static let minimumSurfaces = min(
        max(environment["WORKSPACES_MAILBOX_DEADLOCK_SURFACES"].flatMap { Int($0) } ?? 24, 1), 96)
    private var wakeupsBefore = 0

    @Test("Freeing a surface whose shell is blocked on the full app mailbox returns")
    func freeWhileItsShellIsBlocked() async throws {
        let script = try Self.titleBurstScript(titles: Self.mailboxCapacity + 6)
        defer { try? FileManager.default.removeItem(at: script) }
        try await withWakeupTicksSuspended {
            // The shell sets 70 titles and idles. Its reader fills the mailbox with the first
            // 64 and blocks on the next one, so the free has to drain before it joins.
            var views = [GhosttySurfaceView(customCommand: script.path)]
            try await waitForFullMailbox()
            try #require(views[0].isSurfaceAlive, "the view needs a Ghostty surface to free")
            let released = WeakSurfaceView(views[0])
            autoreleasepool { views.removeAll() }
            try await waitForRetiredSurfacesToBeFreed()
            #expect(released.view == nil)
        }
    }

    @Test("Releasing surface views while the app mailbox is full and undrained frees every surface")
    func freeWhileMailboxIsFull() async throws {
        let log = DeadlockProgressLog(path: Self.environment["WORKSPACES_MAILBOX_DEADLOCK_PROGRESS"])
        try await withWakeupTicksSuspended {
            // Each shell's startup pushes a few messages; more surfaces join until 64 pushes
            // prove the mailbox filled.
            var views: [GhosttySurfaceView] = []
            addSurfaces(Self.minimumSurfaces, to: &views)
            try await waitForFullMailbox {
                if views.count < Self.maximumSurfaces {
                    addSurfaces(min(8, Self.maximumSurfaces - views.count), to: &views)
                }
            }
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
            try await waitForRetiredSurfacesToBeFreed()
            log.write("end")
            #expect(released.allSatisfy { $0.view == nil })
        }
    }

    /// Wakeups stop ticking for the duration, so nothing drains the mailbox until a free does,
    /// while the main thread stays free for other suites.
    private func withWakeupTicksSuspended(_ body: () async throws -> Void) async throws {
        wakeupsBefore = GhosttyAppManager.wakeupCount.withLock { $0 }
        GhosttyAppManager.shared.wakeupTicksSuspended = true
        defer { GhosttyAppManager.shared.wakeupTicksSuspended = false }
        try await body()
    }

    /// 64 wakeups with no tick in between prove the 64-slot mailbox filled.
    private func waitForFullMailbox(addingSurfaces addSurfaces: () -> Void = {}) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        var lastAdded = clock.now
        while !mailboxFilled, clock.now < deadline {
            if clock.now - lastAdded > .seconds(1) {
                addSurfaces()
                lastAdded = clock.now
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(mailboxFilled, "the app mailbox never filled, so the test would prove nothing")
    }

    private var mailboxFilled: Bool {
        GhosttyAppManager.wakeupCount.withLock { $0 } - wakeupsBefore >= Self.mailboxCapacity
    }

    /// A free that deadlocks never returns, so a regression hangs here rather than failing.
    private func waitForRetiredSurfacesToBeFreed() async throws {
        while GhosttyAppManager.shared.retiredSurfaceCount > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func addSurfaces(_ count: Int, to views: inout [GhosttySurfaceView]) {
        let directory = FileManager.default.temporaryDirectory
        autoreleasepool {
            views += (0..<count).map { _ in GhosttySurfaceView(workingDirectory: directory) }
        }
    }

    private static func titleBurstScript(titles: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-burst-\(UUID().uuidString).sh")
        let script = """
            #!/bin/sh
            i=0
            while [ $i -lt \(titles) ]; do i=$((i + 1)); printf '\\033]2;burst %d\\007' "$i"; done
            exec sleep 600

            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
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
