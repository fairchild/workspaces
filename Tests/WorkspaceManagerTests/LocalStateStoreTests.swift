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
            [.toolStart(name: "Read", detail: "README.md")],
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

        let dbQueue = try DatabaseQueue(path: databaseURL.path)
        let targetKind = try await dbQueue.read {
            try String.fetchOne(
                $0,
                sql: "SELECT target_kind FROM terminal_sessions WHERE host_session_id = ?",
                arguments: [sessionID.uuidString]
            )
        }
        #expect(targetKind == "repo")
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
