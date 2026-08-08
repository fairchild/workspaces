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
        #expect(summary.schemaVersion == 2)
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

    /// The continuity row records the session's *chosen* tmux name, not a directory
    /// re-derivation: a split pane's disambiguated name must round-trip so restore
    /// probes and reattaches the pane's own session (#1232).
    @Test("Continuity rows carry the session's chosen tmux name")
    func continuityRowsCarryChosenTmuxName() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.cleanup() }
        let databaseURL = fixture.url.appendingPathComponent("state.sqlite")
        let store = try LocalStateStore(databaseURL: databaseURL)
        let directory = URL(fileURLWithPath: "/tmp/workspaces/repo")
        let primary = HostTerminalSession(key: .repoPath(directory.path), directory: directory)
        let splitID = UUID()
        let split = HostTerminalSession(
            id: splitID,
            key: .repoPath(directory.path),
            directory: directory,
            tmuxSessionNameOverride: TmuxSessionNaming.splitPaneName(for: directory, paneSessionID: splitID)
        )

        for session in [primary, split] {
            try await store.recordTerminalSession(
                session,
                terminalMode: "tmux_per_session",
                isActive: true,
                hooksSocketPath: nil
            )
        }

        let rows = try await store.fetchContinuitySessions()
        let primaryRow = try #require(rows.first { $0.hostSessionID == primary.id })
        let splitRow = try #require(rows.first { $0.hostSessionID == split.id })
        #expect(primaryRow.tmuxSessionName == TmuxSessionNaming.defaultName(for: directory))
        #expect(splitRow.tmuxSessionName == split.tmuxSessionNameOverride)
        #expect(primaryRow.tmuxSessionName != splitRow.tmuxSessionName)
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

        // Schema doc must carry the v2 run-epoch columns (issue #783 #2) so a DB
        // built from docs/schema.sql matches a migrated store.
        let runColumns = try await dbQueue.read {
            try Int.fetchOne(
                $0,
                sql: """
                    SELECT COUNT(*) FROM pragma_table_info('terminal_sessions')
                    WHERE name IN ('run_id', 'run_started_at')
                    """
            )
        }
        #expect(runColumns == 2)
    }

    @Test("fetchPreviousRunSessions returns only the immediately-prior run's active sessions")
    func previousRunSessionsBoundToPriorRun() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.cleanup() }
        let db = fixture.url.appendingPathComponent("state.sqlite")

        let run1 = try LocalStateStore(
            databaseURL: db, runID: UUID(), runStartedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let staleID = UUID()
        try await run1.recordTerminalSession(
            HostTerminalSession(id: staleID, key: .repoPath("/code/old"), directory: URL(fileURLWithPath: "/code/old")),
            terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)

        let run2 = try LocalStateStore(
            databaseURL: db, runID: UUID(), runStartedAt: Date(timeIntervalSince1970: 1_700_100_000))
        let prevID = UUID()
        try await run2.recordTerminalSession(
            HostTerminalSession(
                id: prevID, key: .repoPath("/code/prev"), directory: URL(fileURLWithPath: "/code/prev")),
            terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)

        let current = try LocalStateStore(
            databaseURL: db, runID: UUID(), runStartedAt: Date(timeIntervalSince1970: 1_700_200_000))

        let rows = try await current.fetchPreviousRunSessions(limit: 100)
        #expect(rows.map(\.hostSessionID) == [prevID])

        // The old broad query still sees BOTH stale runs — the bug being fixed.
        let broad = try await current.fetchContinuitySessions(activeOnly: true, limit: 100)
        #expect(Set(broad.map(\.hostSessionID)) == [staleID, prevID])
    }

    @Test("fetchPreviousRunSessions excludes ended prior-run rows and current-run rows")
    func previousRunExcludesEndedAndCurrent() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.cleanup() }
        let db = fixture.url.appendingPathComponent("state.sqlite")

        let prev = try LocalStateStore(
            databaseURL: db, runID: UUID(), runStartedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let keptID = UUID()
        let endedID = UUID()
        for (id, path) in [(keptID, "/code/kept"), (endedID, "/code/ended")] {
            try await prev.recordTerminalSession(
                HostTerminalSession(id: id, key: .repoPath(path), directory: URL(fileURLWithPath: path)),
                terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)
        }
        try await prev.markTerminalSessionEnded(hostSessionID: endedID)

        let current = try LocalStateStore(
            databaseURL: db, runID: UUID(), runStartedAt: Date(timeIntervalSince1970: 1_700_100_000))
        try await current.recordTerminalSession(
            HostTerminalSession(id: UUID(), key: .repoPath("/code/now"), directory: URL(fileURLWithPath: "/code/now")),
            terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)

        let rows = try await current.fetchPreviousRunSessions()
        #expect(rows.map(\.hostSessionID) == [keptID])
    }

    @Test("fetchPreviousRunSessions is empty with no prior run and ignores pre-v2 rows")
    func previousRunEmptyWhenNoPriorRun() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.cleanup() }
        let db = fixture.url.appendingPathComponent("state.sqlite")

        let current = try LocalStateStore(
            databaseURL: db, runID: UUID(), runStartedAt: Date(timeIntervalSince1970: 1_700_100_000))
        #expect(try await current.fetchPreviousRunSessions().isEmpty)  // first launch

        // Simulate a row written by schema v1 (run_id / run_started_at NULL).
        let dbQueue = try DatabaseQueue(path: db.path)
        try await dbQueue.write {
            try $0.execute(
                sql: """
                    INSERT INTO terminal_sessions
                      (host_session_id, session_key, target_kind, target_path, directory_path,
                       terminal_mode, is_active, created_at, last_seen_at)
                    VALUES (?, 'legacy', 'host_path', '/code/legacy', '/code/legacy',
                       'tmux_per_session', 1, '2020-01-01T00:00:00.000Z', '2020-01-01T00:00:00.000Z')
                    """,
                arguments: [UUID().uuidString])
        }
        #expect(try await current.fetchPreviousRunSessions().isEmpty)  // NULL run excluded
    }

    @Test("fetchPreviousRunID identifies the same run fetchPreviousRunSessions scopes to")
    func previousRunIDMatchesPreviousRunScope() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.cleanup() }
        let db = fixture.url.appendingPathComponent("state.sqlite")

        let current0 = try LocalStateStore(
            databaseURL: db, runID: UUID(), runStartedAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try await current0.fetchPreviousRunID() == nil)  // first launch

        let priorRunID = UUID()
        let prior = try LocalStateStore(
            databaseURL: db, runID: priorRunID, runStartedAt: Date(timeIntervalSince1970: 1_700_100_000))
        try await prior.recordTerminalSession(
            HostTerminalSession(
                id: UUID(), key: .repoPath("/code/prev"), directory: URL(fileURLWithPath: "/code/prev")),
            terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)

        let current = try LocalStateStore(
            databaseURL: db, runID: UUID(), runStartedAt: Date(timeIntervalSince1970: 1_700_200_000))
        try await current.recordTerminalSession(
            HostTerminalSession(id: UUID(), key: .repoPath("/code/now"), directory: URL(fileURLWithPath: "/code/now")),
            terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)

        #expect(try await current.fetchPreviousRunID() == priorRunID.uuidString)
    }

    /// The #1239 resurrect race, at the store seam: a stale in-flight upsert that
    /// lands after close must be a complete no-op — the row stays ended and keeps
    /// every field it closed with, so restore never offers a deliberately closed
    /// tile.
    @Test("A late upsert cannot resurrect an ended session row")
    func lateUpsertCannotResurrectEndedRow() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.cleanup() }
        let store = try LocalStateStore(databaseURL: fixture.url.appendingPathComponent("state.sqlite"))
        let sessionID = UUID()
        let session = HostTerminalSession(
            id: sessionID,
            key: .repoPath("/tmp/workspaces/repo"),
            directory: URL(fileURLWithPath: "/tmp/workspaces/repo")
        )

        try await store.recordTerminalSession(
            session, terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)
        let recordedDirectory = try #require(
            try await store.fetchContinuitySessions().first { $0.hostSessionID == sessionID }
        ).directoryPath
        try await store.markTerminalSessionEnded(
            hostSessionID: sessionID, endedAt: Date(timeIntervalSince1970: 1_700_000_100))

        // The stale write carries different field values; none may land.
        try await store.recordTerminalSession(
            HostTerminalSession(
                id: sessionID,
                key: .repoPath("/tmp/workspaces/elsewhere"),
                directory: URL(fileURLWithPath: "/tmp/workspaces/elsewhere")
            ),
            terminalMode: "shell",
            isActive: true,
            hooksSocketPath: "/tmp/late.sock"
        )

        let row = try #require(
            try await store.fetchContinuitySessions().first { $0.hostSessionID == sessionID })
        #expect(row.endedAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(!row.isActive)
        #expect(row.directoryPath == recordedDirectory)
        #expect(row.terminalMode == "tmux_per_session")
        #expect(try await store.fetchContinuitySessions(activeOnly: true).isEmpty)
    }

    @Test("Repeated close keeps the first ended_at")
    func repeatedCloseKeepsFirstEndedAt() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.cleanup() }
        let store = try LocalStateStore(databaseURL: fixture.url.appendingPathComponent("state.sqlite"))
        let sessionID = UUID()
        try await store.recordTerminalSession(
            HostTerminalSession(
                id: sessionID,
                key: .repoPath("/tmp/workspaces/repo"),
                directory: URL(fileURLWithPath: "/tmp/workspaces/repo")
            ),
            terminalMode: "tmux_per_session", isActive: true, hooksSocketPath: nil)

        try await store.markTerminalSessionEnded(
            hostSessionID: sessionID, endedAt: Date(timeIntervalSince1970: 1_700_000_100))
        try await store.markTerminalSessionEnded(
            hostSessionID: sessionID, endedAt: Date(timeIntervalSince1970: 1_700_000_200))

        let row = try #require(
            try await store.fetchContinuitySessions().first { $0.hostSessionID == sessionID })
        #expect(row.endedAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(row.lastSeenAt == Date(timeIntervalSince1970: 1_700_000_100))
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
