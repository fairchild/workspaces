//
//  AgentLaunchRecordWatcherTests.swift
//  WorkspaceManagerAppTests
//
//  Drives the watcher with the real store and real directory events, because what it depends
//  on is how the kernel reports an atomic rename, which a fake would only restate.
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("AgentLaunchRecordWatcher", .serialized, .timeLimit(.minutes(2)))
struct AgentLaunchRecordWatcherTests {
    private final class Passes {
        var count = 0
    }

    private func record(handle: String) -> AgentLaunchRecord {
        AgentLaunchRecord(
            handle: handle,
            workspacePath: "/tmp/\(handle)",
            socketLabel: "workspaces",
            launchedAt: Date(),
            identity: nil
        )
    }

    /// Waits on a budget of time the main actor was free to run the watcher. Everything between a save
    /// and a pass, the event source's handler and the coalescing task, runs on the main actor, and other
    /// suites in the process hold it for seconds at a time (a terminal surface freed on the main thread
    /// joins its threads there). A stretch the main actor spent elsewhere counts as one short tick, so a
    /// stall cannot spend the budget before the pass queued behind it gets to run. Repeated stalls can
    /// stretch that budget far past ten seconds of wall clock, so the suite's time limit is the hard bound.
    private func waitForPasses(_ passes: Passes, atLeast expected: Int) async throws {
        let clock = ContinuousClock()
        var free: Duration = .zero
        while passes.count < expected, free < .seconds(10) {
            let asleep = clock.now
            try await Task.sleep(for: .milliseconds(10))
            free += min(clock.now - asleep, .milliseconds(100))
        }
        try #require(
            passes.count >= expected,
            "expected \(expected) pass(es), saw \(passes.count) after 10 s of main-actor time"
        )
    }

    private func withWatcher(
        _ body: (AgentLaunchRecordStore, AgentLaunchRecordWatcher, Passes) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentLaunchRecordStore(directory: root)
        let passes = Passes()
        let watcher = AgentLaunchRecordWatcher(
            directory: store.directory(socketLabel: "workspaces"),
            coalescing: .milliseconds(50)
        ) { passes.count += 1 }
        watcher.start()
        defer { watcher.stop() }
        try await body(store, watcher, passes)
    }

    @Test("A saved record reaches the window, on a directory that did not exist before")
    func recordTriggersAPass() async throws {
        try await withWatcher { store, _, passes in
            try store.save(record(handle: "wm-a-1"))
            try await waitForPasses(passes, atLeast: 1)
            #expect(passes.count == 1)
        }
    }

    @Test("A burst of launches costs one pass")
    func burstsCoalesce() async throws {
        try await withWatcher { store, _, passes in
            for index in 0..<5 {
                try store.save(record(handle: "wm-a-\(index)"))
            }
            try await waitForPasses(passes, atLeast: 1)
            try await Task.sleep(for: .milliseconds(200))
            #expect(passes.count == 1)
        }
    }

    @Test("A directory removed from under it is watched again once it comes back")
    func survivesTheDirectoryGoing() async throws {
        try await withWatcher { store, _, passes in
            try store.save(record(handle: "wm-a-1"))
            try await waitForPasses(passes, atLeast: 1)
            let seen = passes.count

            try FileManager.default.removeItem(at: store.directory(socketLabel: "workspaces"))
            try await waitForPasses(passes, atLeast: seen + 1)
            let afterRemoval = passes.count

            try store.save(record(handle: "wm-b-2"))
            try await waitForPasses(passes, atLeast: afterRemoval + 1)
            #expect(passes.count > afterRemoval)
        }
    }

    @Test("Writes ten times a second with no pause still reach the window within the max wait")
    func continuousWritesStillPass() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentLaunchRecordStore(directory: root)
        let passes = Passes()
        let watcher = AgentLaunchRecordWatcher(directory: store.directory(socketLabel: "workspaces")) {
            passes.count += 1
        }
        watcher.start()
        defer { watcher.stop() }

        // Four seconds of writes at 10 Hz never leave the 300 ms quiet a pass waits for, so
        // only the 2 s bound can start one before they stop.
        for index in 0..<40 {
            try store.save(record(handle: "wm-a-\(index)"))
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(passes.count >= 1, "no pass ran during four seconds of continuous writes")
    }

    @Test("A watcher that makes the records directory makes it with the mode it was given")
    func watcherCreatesThePrivateDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("conversations", isDirectory: true)
        let watcher = AgentLaunchRecordWatcher(
            directory: directory,
            directoryPermissions: ConversationRecordStore.directoryPermissions
        ) {}
        watcher.start()
        defer { watcher.stop() }

        try ConversationRecordStore(directory: directory).record(
            ConversationObservation(
                conversationID: UUID().uuidString, observedAt: Date(), observedBy: .hook, lastSeenIn: nil))
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test("Passes requested faster than they run go one at a time, first pass first, none lost")
    func passesRunOneAtATime() async throws {
        actor Log {
            var running = 0
            var most = 0
            var order: [String] = []
            func enter(_ name: String) {
                running += 1
                most = max(most, running)
                order.append(name)
            }
            func leave() { running -= 1 }
        }
        let log = Log()
        let passes = SerialPasses(
            first: {
                await log.enter("first")
                try? await Task.sleep(for: .milliseconds(50))
                await log.leave()
            },
            then: {
                await log.enter("then")
                try? await Task.sleep(for: .milliseconds(50))
                await log.leave()
            }
        )
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { await passes.request() }
            }
        }
        await passes.request()
        let order = await log.order
        #expect(await log.most == 1)
        #expect(order.first == "first")
        #expect(order.count >= 2 && order.count <= 21)
        #expect(order.dropFirst().allSatisfy { $0 == "then" })
    }

    @Test("A stopped watcher stays quiet")
    func stopEndsThePasses() async throws {
        try await withWatcher { store, watcher, passes in
            watcher.stop()
            try store.save(record(handle: "wm-a-1"))
            try await Task.sleep(for: .milliseconds(200))
            #expect(passes.count == 0)
        }
    }
}
