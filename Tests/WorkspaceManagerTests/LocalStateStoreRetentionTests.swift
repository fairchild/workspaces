import Foundation
@preconcurrency import GRDB
import Testing

@testable import WorkspaceManagerCore

@Suite("LocalStateStoreRetention")
struct LocalStateStoreRetentionTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalStateStoreRetentionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStatus(
        hostSessionID: UUID,
        agentSessionID: String,
        at seconds: TimeInterval
    ) -> AgentSessionStatus {
        AgentSessionStatus(
            hostSessionID: hostSessionID,
            agentSessionID: agentSessionID,
            kind: .claudeCode,
            cwd: "/code/active",
            run: .runningTool(name: "Read", detail: "file.txt"),
            modelDisplayName: "Claude",
            lastEventAt: Date(timeIntervalSince1970: seconds),
            hookActive: true,
            createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("Retention prunes aged rows but preserves the previous run's restore set")
    func retentionPreservesRestoreSet() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = tempDir.appendingPathComponent("state.sqlite")

        // Previous run: one active session carrying two agent events (an older one
        // and the latest), an ended session, and a diagnostic — all old enough to
        // age out under a far-future retention pass.
        let prev = try LocalStateStore(
            databaseURL: db, runID: UUID(), runStartedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let activeID = UUID()
        try await prev.recordTerminalSession(
            HostTerminalSession(
                id: activeID, key: .repoPath("/code/active"),
                directory: URL(fileURLWithPath: "/code/active")),
            terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)

        try await prev.recordAgentEvents(
            [.toolStart(name: "Read", detail: "older.txt")],
            hostSessionID: activeID, origin: .hook,
            status: makeStatus(hostSessionID: activeID, agentSessionID: "resume-older", at: 1_700_000_100),
            occurredAt: Date(timeIntervalSince1970: 1_700_000_100))
        try await prev.recordAgentEvents(
            [.toolStart(name: "Bash", detail: "ls")],
            hostSessionID: activeID, origin: .hook,
            status: makeStatus(hostSessionID: activeID, agentSessionID: "resume-latest", at: 1_700_000_200),
            occurredAt: Date(timeIntervalSince1970: 1_700_000_200))

        let endedID = UUID()
        try await prev.recordTerminalSession(
            HostTerminalSession(
                id: endedID, key: .repoPath("/code/ended"),
                directory: URL(fileURLWithPath: "/code/ended")),
            terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)
        try await prev.markTerminalSessionEnded(hostSessionID: endedID)

        try await prev.recordDiagnosticEvent(
            metric: "launch_to_first_prompt", durationMs: 100, labels: [:],
            occurredAt: Date(timeIntervalSince1970: 1_700_000_050))

        // Current run makes `prev` the run cold-start restore offers.
        let current = try LocalStateStore(
            databaseURL: db, runID: UUID(), runStartedAt: Date(timeIntervalSince1970: 1_700_100_000))

        let before = try await current.fetchPreviousRunSessions()
        #expect(before.map(\.hostSessionID) == [activeID])
        #expect(before.first?.agentSessionID == "resume-latest")

        let outcome = try await current.runRetention(now: Date(timeIntervalSince1970: 2_000_000_000))

        // The restore path returns exactly what it did before retention.
        let after = try await current.fetchPreviousRunSessions()
        #expect(after == before)
        #expect(after.first?.agentSessionID == "resume-latest")

        // Aged, non-restore-critical rows were removed.
        #expect(outcome.deletedEndedSessions == 1)
        #expect(outcome.deletedAgentEvents == 1)
        #expect(outcome.deletedDiagnosticEvents == 1)
        #expect(outcome.integrityOK)

        // The active session keeps only its latest event; the ended session and its
        // (cascaded) rows are gone; diagnostics are cleared.
        let summary = try await current.summary()
        #expect(summary.tableCounts["terminal_sessions"] == 1)
        #expect(summary.tableCounts["agent_status_events"] == 1)
        #expect(summary.tableCounts["diagnostic_events"] == 0)
    }

    @Test("Retention keeps rows newer than the policy window")
    func retentionKeepsRecentRows() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = tempDir.appendingPathComponent("state.sqlite")

        let now = Date()
        let store = try LocalStateStore(databaseURL: db, runID: UUID(), runStartedAt: now)
        let sessionID = UUID()
        try await store.recordTerminalSession(
            HostTerminalSession(
                id: sessionID, key: .repoPath("/code/fresh"),
                directory: URL(fileURLWithPath: "/code/fresh")),
            terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)
        try await store.recordAgentEvents(
            [.toolStart(name: "Read", detail: "fresh.txt")],
            hostSessionID: sessionID, origin: .hook,
            status: makeStatus(hostSessionID: sessionID, agentSessionID: "fresh", at: now.timeIntervalSince1970),
            occurredAt: now)
        try await store.recordDiagnosticEvent(
            metric: "launch_to_first_prompt", durationMs: 100, labels: [:], occurredAt: now)

        let outcome = try await store.runRetention(now: now)

        #expect(outcome.deletedEndedSessions == 0)
        #expect(outcome.deletedAgentEvents == 0)
        #expect(outcome.deletedDiagnosticEvents == 0)
        #expect(outcome.integrityOK)
    }

    @Test("Integrity probe reports a healthy store and surfaces through the summary")
    func integrityProbeHealthyAndSurfaced() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = tempDir.appendingPathComponent("state.sqlite")

        let store = try LocalStateStore(databaseURL: db)
        #expect(try await store.checkIntegrity())

        // Before any retention pass the summary reports no health signal yet.
        let cold = try await store.summary()
        #expect(cold.lastRetentionAt == nil)
        #expect(cold.integrityOK == nil)

        let outcome = try await store.runRetention()
        #expect(outcome.integrityOK)

        let summary = try await store.summary()
        #expect(summary.integrityOK == true)
        #expect(summary.lastRetentionAt != nil)
    }
}
