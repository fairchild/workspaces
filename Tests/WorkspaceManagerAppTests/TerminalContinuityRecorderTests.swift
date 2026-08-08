//
//  TerminalContinuityRecorderTests.swift
//  WorkspaceManagerAppTests
//
//  Binds the #1239 continuity write pipeline: FIFO execution order, dropped
//  no-op upserts, resilience to sink failures, and the resurrect-race
//  acceptance against a real LocalStateStore.
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

enum ContinuityWriteOperation: Equatable, Hashable {
    case record(UUID, isActive: Bool)
    case ended(UUID)
}

/// In-memory `TerminalContinuityWriting` sink recording the exact order writes
/// execute in. Shared by the recorder tests and the TileTreeStore write-count
/// tests.
actor ContinuityWriteLog: TerminalContinuityWriting {
    struct WriteFailure: Error {}

    private(set) var operations: [ContinuityWriteOperation] = []
    private var failingSessionIDs: Set<UUID> = []

    func failRecords(for sessionID: UUID) {
        failingSessionIDs.insert(sessionID)
    }

    func recordTerminalSession(
        _ session: HostTerminalSession,
        terminalMode: String,
        isActive: Bool,
        hooksSocketPath: String?
    ) async throws {
        guard !failingSessionIDs.contains(session.id) else { throw WriteFailure() }
        operations.append(.record(session.id, isActive: isActive))
    }

    func markTerminalSessionEnded(hostSessionID: UUID, endedAt: Date) async throws {
        operations.append(.ended(hostSessionID))
    }
}

@MainActor
@Suite("TerminalContinuityRecorder")
struct TerminalContinuityRecorderTests {
    private func makeSession(path: String) -> HostTerminalSession {
        HostTerminalSession(key: .repoPath(path), directory: URL(fileURLWithPath: path))
    }

    @Test("Writes execute in enqueue order")
    func writesExecuteInEnqueueOrder() async throws {
        let sink = ContinuityWriteLog()
        let recorder = TerminalContinuityRecorder(sink: sink)

        var expected: [ContinuityWriteOperation] = []
        for index in 0..<100 {
            let session = makeSession(path: "/tmp/workspaces/repo-\(index)")
            recorder.record(session, terminalMode: "shell", isActive: true, hooksSocketPath: nil)
            expected.append(.record(session.id, isActive: true))
            if index.isMultiple(of: 3) {
                recorder.recordEnded(session.id)
                expected.append(.ended(session.id))
            }
        }
        await recorder.waitUntilDrained()

        #expect(await sink.operations == expected)
    }

    @Test("Unchanged upserts are dropped; changed state writes")
    func unchangedUpsertsAreDropped() async throws {
        let sink = ContinuityWriteLog()
        let recorder = TerminalContinuityRecorder(sink: sink)
        let session = makeSession(path: "/tmp/workspaces/repo")

        recorder.record(session, terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)
        recorder.record(session, terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)
        recorder.record(session, terminalMode: "tmux_per_session", isActive: false, hooksSocketPath: nil)
        recorder.record(
            session, terminalMode: "tmux_per_session", isActive: false, hooksSocketPath: "/tmp/hooks.sock")
        await recorder.waitUntilDrained()

        #expect(
            await sink.operations == [
                .record(session.id, isActive: true),
                .record(session.id, isActive: false),
                .record(session.id, isActive: false),
            ])
    }

    @Test("A failed write is logged and the pipeline keeps going")
    func failedWriteDoesNotStallPipeline() async throws {
        let sink = ContinuityWriteLog()
        let recorder = TerminalContinuityRecorder(sink: sink)
        let failing = makeSession(path: "/tmp/workspaces/failing")
        let healthy = makeSession(path: "/tmp/workspaces/healthy")
        await sink.failRecords(for: failing.id)

        recorder.record(failing, terminalMode: "shell", isActive: true, hooksSocketPath: nil)
        recorder.record(healthy, terminalMode: "shell", isActive: true, hooksSocketPath: nil)
        recorder.recordEnded(healthy.id)
        await recorder.waitUntilDrained()

        #expect(
            await sink.operations == [
                .record(healthy.id, isActive: true),
                .ended(healthy.id),
            ])
    }

    /// The #1239 race acceptance: a close in the middle of a snapshot storm —
    /// including a stale upsert enqueued after the close — leaves the row ended,
    /// across 100 iterations against a real store. FIFO enqueue order plus the
    /// store's ended-wins upsert guard is what makes this deterministic.
    @Test("Close during a snapshot storm leaves every row ended across 100 iterations")
    func closeDuringSnapshotStormStaysEnded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStateStore(databaseURL: directory.appendingPathComponent("state.sqlite"))
        let recorder = TerminalContinuityRecorder(sink: store)

        for iteration in 0..<100 {
            let session = makeSession(path: "/tmp/workspaces/repo-\(iteration)")
            // Snapshot storm: state-changing upserts in flight around the close.
            recorder.record(session, terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)
            recorder.record(session, terminalMode: "tmux_per_session", isActive: false, hooksSocketPath: nil)
            recorder.record(session, terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)
            recorder.recordEnded(session.id)
            // Stale upsert after the close — the store's guard must reject it.
            recorder.record(session, terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)
        }
        await recorder.waitUntilDrained()

        #expect(try await store.fetchContinuitySessions(activeOnly: true, limit: 200).isEmpty)
        let rows = try await store.fetchContinuitySessions(limit: 200)
        #expect(rows.count == 100)
        #expect(rows.allSatisfy { $0.endedAt != nil && !$0.isActive })
    }
}
