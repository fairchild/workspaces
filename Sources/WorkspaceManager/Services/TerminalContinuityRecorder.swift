//
//  TerminalContinuityRecorder.swift
//  WorkspaceManager
//
//  Ordered, bounded pipeline for terminal continuity writes (#1239). Enqueues on
//  the main actor in call order and executes on a single consumer task, so a
//  close (ended) can never be overtaken by an earlier in-flight upsert; upserts
//  whose row state is unchanged since the last write are dropped, so a snapshot
//  touching N sessions costs O(changed) writes. Failures are logged, not silent.
//

import Foundation
import WorkspaceManagerCore
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "TerminalContinuityRecorder")

/// The continuity slice of `LocalStateStore` the recorder writes through.
/// Narrowed to a protocol so tests can bind ordering and write counts against
/// an in-memory sink instead of a real SQLite store.
protocol TerminalContinuityWriting: Sendable {
    func recordTerminalSession(
        _ session: HostTerminalSession,
        terminalMode: String,
        isActive: Bool,
        hooksSocketPath: String?
    ) async throws
    func markTerminalSessionEnded(hostSessionID: UUID, endedAt: Date) async throws
}

extension LocalStateStore: TerminalContinuityWriting {}

@MainActor
final class TerminalContinuityRecorder {
    /// Everything `recordTerminalSession` persists for a row, so equality here
    /// means the write would be a byte-identical upsert (modulo `last_seen_at`).
    private struct RecordedState: Equatable {
        let session: HostTerminalSession
        let terminalMode: String
        let isActive: Bool
        let hooksSocketPath: String?
    }

    private let sink: any TerminalContinuityWriting
    private var lastWrittenBySessionID: [UUID: RecordedState] = [:]
    private let operations: AsyncStream<@Sendable () async -> Void>.Continuation

    init(sink: any TerminalContinuityWriting) {
        self.sink = sink
        let (stream, continuation) = AsyncStream.makeStream(
            of: (@Sendable () async -> Void).self
        )
        operations = continuation
        Task.detached {
            for await operation in stream {
                await operation()
            }
        }
    }

    deinit {
        operations.finish()
    }

    /// Upserts the session's continuity row iff its persisted state changed since
    /// the last write this recorder issued for it.
    func record(
        _ session: HostTerminalSession,
        terminalMode: String,
        isActive: Bool,
        hooksSocketPath: String?
    ) {
        let state = RecordedState(
            session: session,
            terminalMode: terminalMode,
            isActive: isActive,
            hooksSocketPath: hooksSocketPath
        )
        guard lastWrittenBySessionID[session.id] != state else { return }
        lastWrittenBySessionID[session.id] = state
        let sink = sink
        operations.yield {
            do {
                try await sink.recordTerminalSession(
                    session,
                    terminalMode: terminalMode,
                    isActive: isActive,
                    hooksSocketPath: hooksSocketPath
                )
            } catch {
                log.error(
                    "[TerminalContinuityRecorder] session upsert failed for \(session.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Ends the session's continuity row. The close moment is captured here, at
    /// enqueue, so a backed-up queue cannot shift the recorded close time.
    func recordEnded(_ sessionID: UUID) {
        lastWrittenBySessionID.removeValue(forKey: sessionID)
        let endedAt = Date()
        let sink = sink
        operations.yield {
            do {
                try await sink.markTerminalSessionEnded(hostSessionID: sessionID, endedAt: endedAt)
            } catch {
                log.error(
                    "[TerminalContinuityRecorder] session end failed for \(sessionID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Resumes once every write enqueued before this call has executed — the
    /// deterministic wait tests use instead of sleeping on the pipeline.
    func waitUntilDrained() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            operations.yield { continuation.resume() }
        }
    }
}
