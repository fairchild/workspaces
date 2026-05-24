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
