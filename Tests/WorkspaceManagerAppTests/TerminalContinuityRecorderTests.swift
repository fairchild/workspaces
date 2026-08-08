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
    private var remainingFailuresBySessionID: [UUID: Int] = [:]

    /// Throw on the next `times` upserts for this session. The default fails
    /// every one; a finite count models a transient failure the sink recovers
    /// from, without a mid-flight mutation racing the pipeline.
    func failRecords(for sessionID: UUID, times: Int = .max) {
        remainingFailuresBySessionID[sessionID] = times
    }

    func recordTerminalSession(
        _ session: HostTerminalSession,
        terminalMode: String,
        isActive: Bool,
        hooksSocketPath: String?
    ) async throws {
        if let remaining = remainingFailuresBySessionID[session.id], remaining > 0 {
            remainingFailuresBySessionID[session.id] = remaining - 1
            throw WriteFailure()
        }
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

    /// The dedup entry is committed at enqueue, so a write that throws must give
    /// it back — otherwise one transient sink failure suppresses that state's
    /// row for as long as it stays unchanged.
    @Test("A sink failure releases its dedup entry; the next identical snapshot writes")
    func failedWriteIsRetriedByNextIdenticalSnapshot() async throws {
        let sink = ContinuityWriteLog()
        let recorder = TerminalContinuityRecorder(sink: sink)
        let session = makeSession(path: "/tmp/workspaces/transient")
        await sink.failRecords(for: session.id, times: 1)

        recorder.record(session, terminalMode: "shell", isActive: true, hooksSocketPath: nil)
        await recorder.waitUntilDrained()
        #expect(await sink.operations.isEmpty)

        // Byte-identical to the failed snapshot: dedup alone would drop it.
        recorder.record(session, terminalMode: "shell", isActive: true, hooksSocketPath: nil)
        await recorder.waitUntilDrained()

        #expect(await sink.operations == [.record(session.id, isActive: true)])
    }

    /// A newer state enqueued after a failure keeps its own dedup entry: the
    /// failed write is stale, and re-offering the newer state is a no-op.
    @Test("A failure behind a newer state does not re-open the newer state's dedup entry")
    func failureBehindNewerStateKeepsNewerDedupEntry() async throws {
        let sink = ContinuityWriteLog()
        let recorder = TerminalContinuityRecorder(sink: sink)
        let session = makeSession(path: "/tmp/workspaces/superseded")
        await sink.failRecords(for: session.id, times: 1)

        recorder.record(session, terminalMode: "shell", isActive: true, hooksSocketPath: nil)
        recorder.record(session, terminalMode: "shell", isActive: false, hooksSocketPath: nil)
        await recorder.waitUntilDrained()
        recorder.record(session, terminalMode: "shell", isActive: false, hooksSocketPath: nil)
        await recorder.waitUntilDrained()

        #expect(await sink.operations == [.record(session.id, isActive: false)])
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
