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
@Suite("AgentLaunchRecordWatcher", .serialized)
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

    private func waitForPasses(_ passes: Passes, atLeast expected: Int) async throws {
        let deadline = Date().addingTimeInterval(10)
        while passes.count < expected, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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
