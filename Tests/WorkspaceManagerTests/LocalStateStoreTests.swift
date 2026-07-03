import Foundation
@preconcurrency import GRDB
import Testing

@testable import WorkspaceManagerCore

@Suite("LocalStateStore")
struct LocalStateStoreTests {
    @Test("Records terminal, agent, and diagnostic state")
    func recordsStateHistory() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.cleanup() }
        let databaseURL = fixture.url.appendingPathComponent("state.sqlite")
        let store = try LocalStateStore(databaseURL: databaseURL)
        let sessionID = UUID(uuidString: "8A0F7340-6896-4CF3-BD94-2E10D02732F1")!
        let session = HostTerminalSession(
            id: sessionID,
            key: .repoPath("/tmp/workspaces/repo"),
            directory: URL(fileURLWithPath: "/tmp/workspaces/repo")
        )

        try await store.recordTerminalSession(
            session,
            terminalMode: "tmux_per_session",
            isActive: true,
            hooksSocketPath: "/tmp/workspaces-hooks.sock"
        )

        let status = AgentSessionStatus(
            hostSessionID: sessionID,
            agentSessionID: "claude-session-1",
            kind: .claudeCode,
            cwd: "/tmp/workspaces/repo",
            run: .runningTool(name: "Read", detail: "README.md"),
            modelDisplayName: "Claude",
            lastEventAt: Date(timeIntervalSince1970: 1_700_000_000),
            hookActive: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.recordAgentEvents(
            [.toolStart(name: "Bash", detail: "echo super-secret-token")],
            hostSessionID: sessionID,
            origin: .hook,
            status: status,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        try await store.recordDiagnosticEvent(
            metric: "launch_to_first_prompt",
            durationMs: 180.5,
            labels: ["surface": "repo_terminal"],
            occurredAt: Date(timeIntervalSince1970: 1_700_000_002)
        )

        let summary = try await store.summary()
        #expect(summary.schemaVersion == 1)
        #expect(summary.tableCounts["terminal_sessions"] == 1)
        #expect(summary.tableCounts["agent_status_events"] == 1)
        #expect(summary.tableCounts["diagnostic_events"] == 1)
        #expect(summary.latestEventTimes["agent_status_events"] == Date(timeIntervalSince1970: 1_700_000_001))
        #expect(summary.latestEventTimes["diagnostic_events"] == Date(timeIntervalSince1970: 1_700_000_002))

        let dbQueue = try DatabaseQueue(path: databaseURL.path)
        let targetKind = try await dbQueue.read {
            try String.fetchOne(
                $0,
                sql: "SELECT target_kind FROM terminal_sessions WHERE host_session_id = ?",
                arguments: [sessionID.uuidString]
            )
        }
        #expect(targetKind == "repo")

        let toolDetail = try await dbQueue.read {
            try String.fetchOne(
                $0,
                sql: "SELECT tool_detail FROM agent_status_events WHERE host_session_id = ?",
                arguments: [sessionID.uuidString]
            )
        }
        #expect(toolDetail == "command_present")

        let eventCwd = try await dbQueue.read {
            try String.fetchOne(
                $0,
                sql: "SELECT cwd FROM agent_status_events WHERE host_session_id = ?",
                arguments: [sessionID.uuidString]
            )
        }
        #expect(eventCwd == "/tmp/workspaces/repo")

        let rawDetailCount = try await dbQueue.read {
            try Int.fetchOne(
                $0,
                sql: "SELECT COUNT(*) FROM agent_status_events WHERE tool_detail = ?",
                arguments: ["echo super-secret-token"]
            )
        }
        #expect(rawDetailCount == 0)
    }

    @Test("Agent events create a placeholder terminal session when needed")
    func agentEventsCreatePlaceholderTerminalSession() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.cleanup() }
        let databaseURL = fixture.url.appendingPathComponent("state.sqlite")
        let store = try LocalStateStore(databaseURL: databaseURL)
        let sessionID = UUID(uuidString: "5D4AC4D8-967E-4C71-A37E-EBEB21082415")!
        let status = AgentSessionStatus(
            hostSessionID: sessionID,
            agentSessionID: "claude-session-2",
            kind: .claudeCode,
            cwd: "/tmp/workspaces/repo",
            run: .runningTool(name: "Read", detail: "/tmp/workspaces/repo/secret.txt"),
            modelDisplayName: "Claude",
            lastEventAt: Date(timeIntervalSince1970: 1_700_000_010),
            hookActive: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_010)
        )

        try await store.recordAgentEvents(
            [.toolStart(name: "Read", detail: "/tmp/workspaces/repo/secret.txt")],
            hostSessionID: sessionID,
            origin: .hook,
            status: status,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_011)
        )

        let summary = try await store.summary()
        #expect(summary.tableCounts["terminal_sessions"] == 1)
        #expect(summary.tableCounts["agent_status_events"] == 1)

        let dbQueue = try DatabaseQueue(path: databaseURL.path)
        let placeholderTargetKind = try await dbQueue.read {
            try String.fetchOne(
                $0,
                sql: "SELECT target_kind FROM terminal_sessions WHERE host_session_id = ?",
                arguments: [sessionID.uuidString]
            )
        }
        #expect(placeholderTargetKind == "host_path")

        let placeholderTargetPath = try await dbQueue.read {
            try String.fetchOne(
                $0,
                sql: "SELECT target_path FROM terminal_sessions WHERE host_session_id = ?",
                arguments: [sessionID.uuidString]
            )
        }
        #expect(placeholderTargetPath == "/tmp/workspaces/repo")

        let placeholderTerminalMode = try await dbQueue.read {
            try String.fetchOne(
                $0,
                sql: "SELECT terminal_mode FROM terminal_sessions WHERE host_session_id = ?",
                arguments: [sessionID.uuidString]
            )
        }
        #expect(placeholderTerminalMode == "unknown")

        let toolDetail = try await dbQueue.read {
            try String.fetchOne(
                $0,
                sql: "SELECT tool_detail FROM agent_status_events WHERE host_session_id = ?",
                arguments: [sessionID.uuidString]
            )
        }
        #expect(toolDetail == "file_path_present")
    }

    @Test("Continuity read model joins latest agent status per session")
    func continuityReadModelJoinsLatestAgentStatus() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.cleanup() }
        let databaseURL = fixture.url.appendingPathComponent("state.sqlite")
        let store = try LocalStateStore(databaseURL: databaseURL)

        let agentSessionID = UUID(uuidString: "1D14D5B0-38A5-4E6C-9C05-6E1C4E1B9A01")!
        let agentSession = HostTerminalSession(
            id: agentSessionID,
            key: .repoPath("/tmp/workspaces/repo"),
            directory: URL(fileURLWithPath: "/tmp/workspaces/repo")
        )
        try await store.recordTerminalSession(
            agentSession,
            terminalMode: "tmux_per_session",
            isActive: true,
            hooksSocketPath: nil
        )

        let endedSessionID = UUID(uuidString: "2D14D5B0-38A5-4E6C-9C05-6E1C4E1B9A02")!
        let endedSession = HostTerminalSession(
            id: endedSessionID,
            key: .hostPath("/tmp/workspaces/other"),
            directory: URL(fileURLWithPath: "/tmp/workspaces/other")
        )
        try await store.recordTerminalSession(
            endedSession,
            terminalMode: "ghostty_managed_splits",
            isActive: true,
            hooksSocketPath: nil
        )
        try await store.markTerminalSessionEnded(hostSessionID: endedSessionID)

        let earlierStatus = AgentSessionStatus(
            hostSessionID: agentSessionID,
            agentSessionID: "claude-session-old",
            kind: .claudeCode,
            cwd: "/tmp/workspaces/repo",
            run: .runningTool(name: "Read", detail: "README.md"),
            modelDisplayName: "Claude",
            lastEventAt: Date(timeIntervalSince1970: 1_700_000_000),
            hookActive: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.recordAgentEvents(
            [.toolStart(name: "Read", detail: "README.md")],
            hostSessionID: agentSessionID,
            origin: .hook,
            status: earlierStatus,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let latestStatus = AgentSessionStatus(
            hostSessionID: agentSessionID,
            agentSessionID: "claude-session-new",
            kind: .claudeCode,
            cwd: "/tmp/workspaces/repo",
            run: .runningTool(name: "Bash", detail: "swift test"),
            modelDisplayName: "Claude",
            lastEventAt: Date(timeIntervalSince1970: 1_700_000_100),
            hookActive: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.recordAgentEvents(
            [.toolStart(name: "Bash", detail: "swift test")],
            hostSessionID: agentSessionID,
            origin: .hook,
            status: latestStatus,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let allRows = try await store.fetchContinuitySessions()
        #expect(allRows.count == 2)

        let endedRow = try #require(allRows.first { $0.hostSessionID == endedSessionID })
        #expect(endedRow.isActive == false)
        #expect(endedRow.endedAt != nil)
        #expect(endedRow.agentSessionID == nil)
        #expect(endedRow.agentRunState == nil)

        let activeRows = try await store.fetchContinuitySessions(activeOnly: true)
        #expect(activeRows.count == 1)
        let activeRow = try #require(activeRows.first)
        #expect(activeRow.hostSessionID == agentSessionID)
        #expect(activeRow.directoryPath == "/tmp/workspaces/repo")
        #expect(activeRow.terminalMode == "tmux_per_session")
        #expect(activeRow.tmuxSessionName != nil)
        #expect(activeRow.agentSessionID == "claude-session-new")
        #expect(activeRow.agentRunState == "running_tool")
        #expect(activeRow.agentCwd == "/tmp/workspaces/repo")
        #expect(activeRow.agentEventAt == Date(timeIntervalSince1970: 1_700_000_100))
    }

    @Test("Latest layout snapshot returns newest capture with split panes")
    func latestLayoutSnapshotReturnsNewestCapture() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.cleanup() }
        let databaseURL = fixture.url.appendingPathComponent("state.sqlite")
        let store = try LocalStateStore(databaseURL: databaseURL)

        let emptyBefore = try await store.fetchLatestLayoutSnapshot()
        #expect(emptyBefore == nil)

        let primaryID = UUID(uuidString: "3D14D5B0-38A5-4E6C-9C05-6E1C4E1B9A03")!
        let splitID = UUID(uuidString: "4D14D5B0-38A5-4E6C-9C05-6E1C4E1B9A04")!
        for (sessionID, path) in [(primaryID, "/tmp/workspaces/repo"), (splitID, "/tmp/workspaces/other")] {
            let session = HostTerminalSession(
                id: sessionID,
                key: .hostPath(path),
                directory: URL(fileURLWithPath: path)
            )
            try await store.recordTerminalSession(
                session,
                terminalMode: "ghostty_managed_splits",
                isActive: true,
                hooksSocketPath: nil
            )
        }

        try await store.recordTerminalLayoutSnapshot(
            activeHostSessionID: primaryID,
            selectedSurfaceKind: "repository_terminal",
            selectedSurfaceID: primaryID.uuidString,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.recordTerminalLayoutSnapshot(
            activeHostSessionID: splitID,
            selectedSurfaceKind: "workspace_terminal",
            selectedSurfaceID: splitID.uuidString,
            splitPanes: [
                TerminalSplitSnapshotInput(
                    primaryHostSessionID: primaryID,
                    splitHostSessionID: splitID,
                    axis: "leading_trailing",
                    splitBeforePrimary: false,
                    splitFraction: 0.5
                )
            ],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let latestSnapshot = try await store.fetchLatestLayoutSnapshot()
        let snapshot = try #require(latestSnapshot)
        #expect(snapshot.capturedAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(snapshot.activeHostSessionID == splitID)
        #expect(snapshot.selectedSurfaceKind == "workspace_terminal")
        #expect(snapshot.splitPanes.count == 1)
        let pane = try #require(snapshot.splitPanes.first)
        #expect(pane.primaryHostSessionID == primaryID)
        #expect(pane.splitHostSessionID == splitID)
        #expect(pane.axis == "leading_trailing")
        #expect(pane.splitBeforePrimary == false)
        #expect(pane.splitFraction == 0.5)
    }

    @Test("docs/schema.sql loads as runnable SQLite")
    func schemaDocumentLoads() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.cleanup() }
        let databaseURL = fixture.url.appendingPathComponent("schema.sqlite")
        let schemaURL = repoRoot()
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("schema.sql", isDirectory: false)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            databaseURL.path,
            ".read \(schemaURL.path)",
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let dbQueue = try DatabaseQueue(path: databaseURL.path)
        let tableCount = try await dbQueue.read {
            try Int.fetchOne(
                $0,
                sql: """
                    SELECT COUNT(*)
                    FROM sqlite_master
                    WHERE type = 'table'
                      AND name IN (
                        'local_state_metadata',
                        'terminal_sessions',
                        'terminal_layout_snapshots',
                        'terminal_split_snapshots',
                        'agent_status_events',
                        'diagnostic_events',
                        'diagnostic_exports'
                      )
                    """
            )
        }
        #expect(tableCount == 7)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalStateStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}
