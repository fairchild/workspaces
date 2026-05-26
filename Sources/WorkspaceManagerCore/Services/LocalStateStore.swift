//
//  LocalStateStore.swift
//  WorkspaceManagerCore
//
//  Durable local SQLite sidecar for WorkSpaces state history. SwiftData remains
//  the canonical owner of Repository, Workspace, and Web Source rows; this store
//  records queryable state history for continuity, diagnostics, and export.
//

import Foundation
@preconcurrency import GRDB

public enum LocalStateStoreMode: Codable, Equatable, Sendable {
    case persistent(path: String)
    case disabled(reason: String)
    case unavailable

    public var path: String? {
        switch self {
        case .persistent(let path):
            return path
        case .disabled, .unavailable:
            return nil
        }
    }

    public var label: String {
        switch self {
        case .persistent:
            return "Persistent"
        case .disabled:
            return "Disabled"
        case .unavailable:
            return "Unavailable"
        }
    }
}

public struct LocalStateStoreBootstrapResult: Sendable {
    public let store: LocalStateStore?
    public let mode: LocalStateStoreMode
    public let bootstrapErrors: [String]
}

public struct LocalStateStoreStatusSnapshot: Codable, Equatable, Sendable {
    public let mode: LocalStateStoreMode
    public let bootstrapErrors: [String]

    public init(mode: LocalStateStoreMode, bootstrapErrors: [String]) {
        self.mode = mode
        self.bootstrapErrors = bootstrapErrors
    }
}

@MainActor
public final class LocalStateStoreController {
    public static let shared = LocalStateStoreController()

    public private(set) var store: LocalStateStore?
    public private(set) var mode: LocalStateStoreMode = .unavailable
    public private(set) var bootstrapErrors: [String] = []

    public var snapshot: LocalStateStoreStatusSnapshot {
        LocalStateStoreStatusSnapshot(mode: mode, bootstrapErrors: bootstrapErrors)
    }

    public func apply(_ result: LocalStateStoreBootstrapResult) {
        store = result.store
        mode = result.mode
        bootstrapErrors = result.bootstrapErrors
    }
}

public enum LocalStateStoreBootstrapper {
    public static let databaseFileName = "local-state.sqlite"

    public static func bootstrap(
        launchEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> LocalStateStoreBootstrapResult {
        if launchEnvironment["WORKSPACES_UI_FIXTURE"] == "1",
            explicitStoreDirectory(from: launchEnvironment) == nil
        {
            return LocalStateStoreBootstrapResult(
                store: nil,
                mode: .disabled(reason: "WORKSPACES_UI_FIXTURE without an explicit state directory"),
                bootstrapErrors: []
            )
        }

        do {
            let databaseURL = try defaultDatabaseURL(
                launchEnvironment: launchEnvironment,
                fileManager: fileManager
            )
            let store = try LocalStateStore(databaseURL: databaseURL)
            return LocalStateStoreBootstrapResult(
                store: store,
                mode: .persistent(path: databaseURL.path),
                bootstrapErrors: []
            )
        } catch {
            let message = "Failed to open local state store: \(String(describing: error))"
            NSLog("[LocalStateStore] %@", message)
            return LocalStateStoreBootstrapResult(
                store: nil,
                mode: .unavailable,
                bootstrapErrors: [message]
            )
        }
    }

    public static func defaultDatabaseURL(
        launchEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory: URL
        if let explicitDirectory = explicitStoreDirectory(from: launchEnvironment) {
            directory = explicitDirectory
        } else {
            let appSupportDirectory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            directory = appSupportDirectory.appendingPathComponent("WorkspaceManager", isDirectory: true)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(databaseFileName, isDirectory: false)
    }

    private static func explicitStoreDirectory(from environment: [String: String]) -> URL? {
        let rawValue =
            environment["WORKSPACES_LOCAL_STATE_DIR"]
            ?? environment["WORKSPACES_DATA_DIR"]
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty
        else {
            return nil
        }

        let expandedPath = (rawValue as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath, isDirectory: true)
    }
}

public struct LocalStateStoreSummary: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let databasePath: String
    public let generatedAt: Date
    public let tableCounts: [String: Int]
    public let latestEventTimes: [String: Date]

    public init(
        schemaVersion: Int,
        databasePath: String,
        generatedAt: Date,
        tableCounts: [String: Int],
        latestEventTimes: [String: Date] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.databasePath = databasePath
        self.generatedAt = generatedAt
        self.tableCounts = tableCounts
        self.latestEventTimes = latestEventTimes
    }
}

public actor LocalStateStore {
    public static let schemaVersion = 1
    public let databaseURL: URL

    private let dbPool: DatabasePool

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL

        var configuration = Configuration()
        configuration.label = "WorkSpaces local state"
        configuration.busyMode = .timeout(5.0)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        dbPool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try Self.migrator.migrate(dbPool)
        try Self.writeMetadata(in: dbPool)
    }

    public func recordTerminalSession(
        _ session: HostTerminalSession,
        terminalMode: String,
        isActive: Bool,
        hooksSocketPath: String?
    ) async throws {
        let now = Self.isoString(Date())
        let target = Self.targetFields(for: session.key)
        let customCommandPresent = session.customCommand == nil ? 0 : 1
        let activeValue = isActive ? 1 : 0
        let tmuxSessionName = Self.tmuxSessionName(for: session.directoryURL, terminalMode: terminalMode)

        try await dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO terminal_sessions (
                        host_session_id,
                        session_key,
                        target_kind,
                        target_id,
                        target_path,
                        backend_identifier,
                        backend_instance_id,
                        directory_path,
                        terminal_mode,
                        tmux_session_name,
                        custom_command_present,
                        hooks_socket_path,
                        is_active,
                        created_at,
                        last_seen_at,
                        ended_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    ON CONFLICT(host_session_id) DO UPDATE SET
                        session_key = excluded.session_key,
                        target_kind = excluded.target_kind,
                        target_id = excluded.target_id,
                        target_path = excluded.target_path,
                        backend_identifier = excluded.backend_identifier,
                        backend_instance_id = excluded.backend_instance_id,
                        directory_path = excluded.directory_path,
                        terminal_mode = excluded.terminal_mode,
                        tmux_session_name = excluded.tmux_session_name,
                        custom_command_present = excluded.custom_command_present,
                        hooks_socket_path = excluded.hooks_socket_path,
                        is_active = excluded.is_active,
                        last_seen_at = excluded.last_seen_at,
                        ended_at = NULL
                    """,
                arguments: [
                    session.id.uuidString,
                    session.key.debugDescription,
                    target.kind,
                    target.id,
                    target.path,
                    target.backendIdentifier,
                    target.backendInstanceID,
                    session.directoryPath,
                    terminalMode,
                    tmuxSessionName,
                    customCommandPresent,
                    hooksSocketPath,
                    activeValue,
                    now,
                    now,
                ])
        }
    }

    public func markTerminalSessionEnded(hostSessionID: UUID) async throws {
        let now = Self.isoString(Date())
        try await dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE terminal_sessions
                    SET ended_at = ?, is_active = 0, last_seen_at = ?
                    WHERE host_session_id = ?
                    """,
                arguments: [now, now, hostSessionID.uuidString])
        }
    }

    public func recordTerminalLayoutSnapshot(
        activeHostSessionID: UUID?,
        selectedSurfaceKind: String?,
        selectedSurfaceID: String?,
        splitPanes: [TerminalSplitSnapshotInput] = []
    ) async throws {
        let snapshotID = UUID().uuidString
        let now = Self.isoString(Date())
        try await dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO terminal_layout_snapshots (
                        id, captured_at, active_host_session_id, selected_surface_kind, selected_surface_id
                    )
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    snapshotID,
                    now,
                    activeHostSessionID?.uuidString,
                    selectedSurfaceKind,
                    selectedSurfaceID,
                ])

            for splitPane in splitPanes {
                try db.execute(
                    sql: """
                        INSERT INTO terminal_split_snapshots (
                            snapshot_id,
                            primary_host_session_id,
                            split_host_session_id,
                            axis,
                            split_before_primary,
                            split_fraction
                        )
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        snapshotID,
                        splitPane.primaryHostSessionID.uuidString,
                        splitPane.splitHostSessionID.uuidString,
                        splitPane.axis,
                        splitPane.splitBeforePrimary ? 1 : 0,
                        splitPane.splitFraction,
                    ])
            }
        }
    }

    public func recordAgentEvents(
        _ events: [AgentEvent],
        hostSessionID: UUID,
        origin: AgentEventOrigin,
        status: AgentSessionStatus,
        occurredAt: Date = Date()
    ) async throws {
        guard !events.isEmpty else { return }
        let now = Self.isoString(occurredAt)
        let originFields = Self.originFields(origin)
        let runState = Self.runStateName(status.run)

        try await dbPool.write { db in
            try Self.ensureTerminalSessionRow(
                db,
                hostSessionID: hostSessionID,
                cwd: status.cwd,
                now: now
            )

            for event in events {
                let eventFields = Self.eventFields(event)
                try db.execute(
                    sql: """
                        INSERT INTO agent_status_events (
                            id,
                            host_session_id,
                            agent_session_id,
                            agent_kind,
                            origin,
                            origin_detail,
                            event_name,
                            run_state,
                            cwd,
                            tool_name,
                            tool_detail,
                            awaiting_reason,
                            error_category,
                            error_message,
                            prompt_present,
                            model_display_name,
                            context_used_percent,
                            five_hour_limit_used_percent,
                            five_hour_limit_resets_at,
                            cost_usd,
                            event_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString,
                        hostSessionID.uuidString,
                        status.agentSessionID,
                        status.kind.rawValue,
                        originFields.name,
                        originFields.detail,
                        eventFields.name,
                        runState,
                        status.cwd,
                        eventFields.toolName,
                        eventFields.toolDetail,
                        eventFields.awaitingReason,
                        eventFields.errorCategory,
                        eventFields.errorMessage,
                        eventFields.promptPresent,
                        status.modelDisplayName,
                        status.contextUsedPercent,
                        status.fiveHourLimitUsedPercent,
                        status.fiveHourLimitResetsAt.map(Self.isoString),
                        status.costUSD,
                        now,
                    ])
            }
        }
    }

    private static func ensureTerminalSessionRow(
        _ db: Database,
        hostSessionID: UUID,
        cwd: String,
        now: String
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO terminal_sessions (
                    host_session_id,
                    session_key,
                    target_kind,
                    target_id,
                    target_path,
                    backend_identifier,
                    backend_instance_id,
                    directory_path,
                    terminal_mode,
                    tmux_session_name,
                    custom_command_present,
                    hooks_socket_path,
                    is_active,
                    created_at,
                    last_seen_at,
                    ended_at
                )
                VALUES (?, ?, 'host_path', NULL, ?, NULL, NULL, ?, 'unknown', NULL, 0, NULL, 0, ?, ?, NULL)
                ON CONFLICT(host_session_id) DO NOTHING
                """,
            arguments: [
                hostSessionID.uuidString,
                "host_session_id:\(hostSessionID.uuidString)",
                cwd,
                cwd,
                now,
                now,
            ])
    }

    /// Fetch the most recent `agent_status_events` rows for one host session,
    /// returned newest first. Returns `[]` for unknown sessions.
    public func fetchAgentStatusEvents(
        hostSessionID: UUID,
        limit: Int = 200
    ) async throws -> [AgentStatusEventRow] {
        let sessionIDString = hostSessionID.uuidString
        let cappedLimit = max(0, limit)
        return try await dbPool.read { db -> [AgentStatusEventRow] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, host_session_id, agent_session_id, agent_kind, origin,
                           origin_detail, event_name, run_state, cwd, tool_name,
                           tool_detail, awaiting_reason, error_category, error_message,
                           model_display_name, event_at
                    FROM agent_status_events
                    WHERE host_session_id = ?
                    ORDER BY event_at DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [sessionIDString, cappedLimit]
            )
            return rows.compactMap(AgentStatusEventRow.init(row:))
        }
    }

    public func recordDiagnosticEvent(
        metric: String,
        durationMs: Double,
        labels: [String: String] = [:],
        occurredAt: Date = Date()
    ) async throws {
        let labelsJSON = try Self.jsonString(labels)
        let now = Self.isoString(occurredAt)
        try await dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO diagnostic_events (id, metric, duration_ms, labels_json, event_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, metric, durationMs, labelsJSON, now])
        }
    }

    public func recordDiagnosticExport(
        appVersion: String,
        buildNumber: String,
        filename: String,
        redactionLevel: String,
        status: String,
        rowCounts: [String: Int]
    ) async throws {
        let rowCountsJSON = try Self.jsonString(rowCounts)
        let now = Self.isoString(Date())
        try await dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO diagnostic_exports (
                        id,
                        created_at,
                        app_version,
                        build_number,
                        filename,
                        redaction_level,
                        status,
                        row_counts_json
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    now,
                    appVersion,
                    buildNumber,
                    filename,
                    redactionLevel,
                    status,
                    rowCountsJSON,
                ])
        }
    }

    public func summary() async throws -> LocalStateStoreSummary {
        let tables = [
            "terminal_sessions",
            "terminal_layout_snapshots",
            "terminal_split_snapshots",
            "agent_status_events",
            "diagnostic_events",
            "diagnostic_exports",
        ]

        let counts = try await dbPool.read { db -> [String: Int] in
            var result: [String: Int] = [:]
            for table in tables {
                result[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return result
        }
        let latestEventTimes = try await dbPool.read { db -> [String: Date] in
            let queries = [
                "terminal_sessions": "SELECT max(last_seen_at) FROM terminal_sessions",
                "terminal_layout_snapshots": "SELECT max(captured_at) FROM terminal_layout_snapshots",
                "agent_status_events": "SELECT max(event_at) FROM agent_status_events",
                "diagnostic_events": "SELECT max(event_at) FROM diagnostic_events",
                "diagnostic_exports": "SELECT max(created_at) FROM diagnostic_exports",
            ]
            var result: [String: Date] = [:]
            for (table, sql) in queries {
                if let rawValue = try String.fetchOne(db, sql: sql),
                    let date = Self.date(fromISOString: rawValue)
                {
                    result[table] = date
                }
            }
            return result
        }

        return LocalStateStoreSummary(
            schemaVersion: Self.schemaVersion,
            databasePath: databaseURL.path,
            generatedAt: Date(),
            tableCounts: counts,
            latestEventTimes: latestEventTimes
        )
    }

    private static func writeMetadata(in dbPool: DatabasePool) throws {
        let now = Self.isoString(Date())
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO local_state_metadata (key, value, updated_at)
                    VALUES ('schema_version', ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        value = excluded.value,
                        updated_at = excluded.updated_at
                    """,
                arguments: [String(Self.schemaVersion), now])
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS local_state_metadata (
                        key TEXT PRIMARY KEY NOT NULL,
                        value TEXT NOT NULL,
                        updated_at TEXT NOT NULL
                    ) STRICT;

                    CREATE TABLE IF NOT EXISTS terminal_sessions (
                        host_session_id TEXT PRIMARY KEY NOT NULL,
                        session_key TEXT NOT NULL,
                        target_kind TEXT NOT NULL
                            CHECK (target_kind IN ('default_home', 'repo', 'workspace', 'host_path', 'backend_session')),
                        target_id TEXT,
                        target_path TEXT,
                        backend_identifier TEXT,
                        backend_instance_id TEXT,
                        directory_path TEXT NOT NULL,
                        terminal_mode TEXT NOT NULL,
                        tmux_session_name TEXT,
                        custom_command_present INTEGER NOT NULL DEFAULT 0
                            CHECK (custom_command_present IN (0, 1)),
                        hooks_socket_path TEXT,
                        is_active INTEGER NOT NULL DEFAULT 0
                            CHECK (is_active IN (0, 1)),
                        created_at TEXT NOT NULL,
                        last_seen_at TEXT NOT NULL,
                        ended_at TEXT
                    ) STRICT;

                    CREATE INDEX IF NOT EXISTS idx_terminal_sessions_target
                        ON terminal_sessions(target_kind, target_id, target_path);
                    CREATE INDEX IF NOT EXISTS idx_terminal_sessions_last_seen
                        ON terminal_sessions(last_seen_at DESC);

                    CREATE TABLE IF NOT EXISTS terminal_layout_snapshots (
                        id TEXT PRIMARY KEY NOT NULL,
                        captured_at TEXT NOT NULL,
                        active_host_session_id TEXT,
                        selected_surface_kind TEXT,
                        selected_surface_id TEXT,
                        FOREIGN KEY (active_host_session_id)
                            REFERENCES terminal_sessions(host_session_id)
                            ON DELETE SET NULL
                    ) STRICT;

                    CREATE INDEX IF NOT EXISTS idx_terminal_layout_snapshots_captured
                        ON terminal_layout_snapshots(captured_at DESC);

                    CREATE TABLE IF NOT EXISTS terminal_split_snapshots (
                        snapshot_id TEXT NOT NULL,
                        primary_host_session_id TEXT NOT NULL,
                        split_host_session_id TEXT NOT NULL,
                        axis TEXT NOT NULL CHECK (axis IN ('leading_trailing', 'top_bottom')),
                        split_before_primary INTEGER NOT NULL CHECK (split_before_primary IN (0, 1)),
                        split_fraction REAL NOT NULL CHECK (split_fraction >= 0.0 AND split_fraction <= 1.0),
                        PRIMARY KEY (snapshot_id, primary_host_session_id),
                        FOREIGN KEY (snapshot_id)
                            REFERENCES terminal_layout_snapshots(id)
                            ON DELETE CASCADE,
                        FOREIGN KEY (primary_host_session_id)
                            REFERENCES terminal_sessions(host_session_id)
                            ON DELETE CASCADE,
                        FOREIGN KEY (split_host_session_id)
                            REFERENCES terminal_sessions(host_session_id)
                            ON DELETE CASCADE
                    ) STRICT;

                    CREATE TABLE IF NOT EXISTS agent_status_events (
                        id TEXT PRIMARY KEY NOT NULL,
                        host_session_id TEXT NOT NULL,
                        agent_session_id TEXT,
                        agent_kind TEXT NOT NULL,
                        origin TEXT NOT NULL CHECK (origin IN ('hook', 'osc', 'status_line', 'transcript', 'bell')),
                        origin_detail TEXT,
                        event_name TEXT NOT NULL,
                        run_state TEXT NOT NULL,
                        cwd TEXT NOT NULL,
                        tool_name TEXT,
                        tool_detail TEXT,
                        awaiting_reason TEXT,
                        error_category TEXT,
                        error_message TEXT,
                        prompt_present INTEGER NOT NULL DEFAULT 0 CHECK (prompt_present IN (0, 1)),
                        model_display_name TEXT,
                        context_used_percent REAL,
                        five_hour_limit_used_percent REAL,
                        five_hour_limit_resets_at TEXT,
                        cost_usd REAL,
                        event_at TEXT NOT NULL,
                        FOREIGN KEY (host_session_id)
                            REFERENCES terminal_sessions(host_session_id)
                            ON DELETE CASCADE
                    ) STRICT;

                    CREATE INDEX IF NOT EXISTS idx_agent_status_events_host_time
                        ON agent_status_events(host_session_id, event_at DESC);
                    CREATE INDEX IF NOT EXISTS idx_agent_status_events_agent_session
                        ON agent_status_events(agent_session_id, event_at DESC);
                    CREATE INDEX IF NOT EXISTS idx_agent_status_events_run_state
                        ON agent_status_events(run_state, event_at DESC);

                    CREATE TABLE IF NOT EXISTS diagnostic_events (
                        id TEXT PRIMARY KEY NOT NULL,
                        metric TEXT NOT NULL,
                        duration_ms REAL NOT NULL,
                        labels_json TEXT NOT NULL DEFAULT '{}',
                        event_at TEXT NOT NULL
                    ) STRICT;

                    CREATE INDEX IF NOT EXISTS idx_diagnostic_events_metric_time
                        ON diagnostic_events(metric, event_at DESC);

                    CREATE TABLE IF NOT EXISTS diagnostic_exports (
                        id TEXT PRIMARY KEY NOT NULL,
                        created_at TEXT NOT NULL,
                        app_version TEXT NOT NULL,
                        build_number TEXT NOT NULL,
                        filename TEXT NOT NULL,
                        redaction_level TEXT NOT NULL,
                        status TEXT NOT NULL,
                        row_counts_json TEXT NOT NULL DEFAULT '{}'
                    ) STRICT;

                    CREATE INDEX IF NOT EXISTS idx_diagnostic_exports_created
                        ON diagnostic_exports(created_at DESC);
                    """)
        }
        return migrator
    }

    private static func targetFields(
        for key: HostTerminalSessionKey
    ) -> (
        kind: String,
        id: String?,
        path: String?,
        backendIdentifier: String?,
        backendInstanceID: String?
    ) {
        switch key {
        case .defaultHome:
            return ("default_home", nil, nil, nil, nil)
        case .repoPath(let path):
            return ("repo", nil, path, nil, nil)
        case .hostPath(let path):
            return ("host_path", nil, path, nil, nil)
        case .backendSession(let providerID, let instanceID):
            return ("backend_session", nil, nil, providerID, instanceID)
        }
    }

    private static func eventFields(
        _ event: AgentEvent
    ) -> (
        name: String,
        toolName: String?,
        toolDetail: String?,
        awaitingReason: String?,
        errorCategory: String?,
        errorMessage: String?,
        promptPresent: Int
    ) {
        switch event {
        case .sessionStart:
            return ("session_start", nil, nil, nil, nil, nil, 0)
        case .userPrompt(let prompt):
            return ("user_prompt", nil, nil, nil, nil, nil, prompt == nil ? 0 : 1)
        case .toolStart(let name, let detail):
            return ("tool_start", name, safeToolDetail(for: name, rawDetail: detail), nil, nil, nil, 0)
        case .toolEnd(let name, _):
            return ("tool_end", name, nil, nil, nil, nil, 0)
        case .toolBatchEnd:
            return ("tool_batch_end", nil, nil, nil, nil, nil, 0)
        case .toolFailed(let name, let error):
            return ("tool_failed", name, nil, nil, AgentErrorCategory.toolFailure.rawValue, error, 0)
        case .awaitingInput(let reason, _, _):
            return ("awaiting_input", nil, nil, reason.rawValue, nil, nil, 0)
        case .stopped(let error):
            return ("stopped", nil, nil, nil, nil, error, 0)
        case .errored(let category, let message):
            return ("errored", nil, nil, nil, category.rawValue, message, 0)
        case .statusFields:
            return ("status_fields", nil, nil, nil, nil, nil, 0)
        case .workingDirectory:
            return ("working_directory", nil, nil, nil, nil, nil, 0)
        case .bell:
            return ("bell", nil, nil, nil, nil, nil, 0)
        }
    }

    private static func safeToolDetail(for toolName: String, rawDetail: String?) -> String? {
        guard let rawDetail = rawDetail?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawDetail.isEmpty
        else {
            return nil
        }

        switch toolName.lowercased() {
        case "bash":
            return "command_present"
        case "read", "edit", "multiedit", "write", "notebookread", "notebookedit":
            return "file_path_present"
        case "glob", "grep", "ls":
            return "path_or_pattern_present"
        case "webfetch":
            return "url_present"
        case "websearch":
            return "query_present"
        default:
            return "detail_present"
        }
    }

    private static func originFields(_ origin: AgentEventOrigin) -> (name: String, detail: String?) {
        switch origin {
        case .hook:
            return ("hook", nil)
        case .osc(let surfaceID):
            return ("osc", surfaceID.map(String.init))
        case .statusLine:
            return ("status_line", nil)
        case .transcript:
            return ("transcript", nil)
        case .bell:
            return ("bell", nil)
        }
    }

    private static func runStateName(_ runState: AgentRunState) -> String {
        switch runState {
        case .idle:
            return "idle"
        case .thinking:
            return "thinking"
        case .runningTool:
            return "running_tool"
        case .awaitingInput:
            return "awaiting_input"
        case .complete:
            return "complete"
        case .errored:
            return "errored"
        }
    }

    private static func tmuxSessionName(for directory: URL, terminalMode: String) -> String? {
        guard terminalMode == "tmux_per_session" else { return nil }
        let normalizedPath = directory
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let baseComponent = directory.lastPathComponent.isEmpty ? "session" : directory.lastPathComponent
        let sanitizedBase = sanitizeSessionComponent(baseComponent)
        let hash = fnv1a64(normalizedPath)
        let hashPrefix = String(format: "%016llx", hash).prefix(8)
        return "wm-\(sanitizedBase)-\(hashPrefix)"
    }

    private static func sanitizeSessionComponent(_ value: String) -> String {
        let transformed = value.lowercased().map { character -> Character in
            if character.isASCII, character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }

        let collapsed = String(transformed)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if collapsed.isEmpty {
            return "session"
        }

        return String(collapsed.prefix(20))
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0100_0000_01b3
        }
        return hash
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(fromISOString value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Read-side projection of one `agent_status_events` row. Strings are kept
/// verbatim from the table — mapping to a richer domain type (e.g.
/// `WorkspaceEvent`) is a caller concern, so the store stays the single owner
/// of the SQL contract.
public struct AgentStatusEventRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let hostSessionID: UUID
    public let agentSessionID: String?
    public let agentKind: String
    public let origin: String
    public let originDetail: String?
    public let eventName: String
    public let runState: String
    public let cwd: String
    public let toolName: String?
    public let toolDetail: String?
    public let awaitingReason: String?
    public let errorCategory: String?
    public let errorMessage: String?
    public let modelDisplayName: String?
    public let eventAt: Date

    public init(
        id: String,
        hostSessionID: UUID,
        agentSessionID: String?,
        agentKind: String,
        origin: String,
        originDetail: String?,
        eventName: String,
        runState: String,
        cwd: String,
        toolName: String?,
        toolDetail: String?,
        awaitingReason: String?,
        errorCategory: String?,
        errorMessage: String?,
        modelDisplayName: String?,
        eventAt: Date
    ) {
        self.id = id
        self.hostSessionID = hostSessionID
        self.agentSessionID = agentSessionID
        self.agentKind = agentKind
        self.origin = origin
        self.originDetail = originDetail
        self.eventName = eventName
        self.runState = runState
        self.cwd = cwd
        self.toolName = toolName
        self.toolDetail = toolDetail
        self.awaitingReason = awaitingReason
        self.errorCategory = errorCategory
        self.errorMessage = errorMessage
        self.modelDisplayName = modelDisplayName
        self.eventAt = eventAt
    }

    init?(row: Row) {
        guard let id = row["id"] as String?,
            let hostSessionIDString = row["host_session_id"] as String?,
            let hostSessionID = UUID(uuidString: hostSessionIDString),
            let agentKind = row["agent_kind"] as String?,
            let origin = row["origin"] as String?,
            let eventName = row["event_name"] as String?,
            let runState = row["run_state"] as String?,
            let cwd = row["cwd"] as String?,
            let eventAtRaw = row["event_at"] as String?,
            let eventAt = AgentStatusEventRow.parseISODate(eventAtRaw)
        else {
            return nil
        }

        self.init(
            id: id,
            hostSessionID: hostSessionID,
            agentSessionID: row["agent_session_id"] as String?,
            agentKind: agentKind,
            origin: origin,
            originDetail: row["origin_detail"] as String?,
            eventName: eventName,
            runState: runState,
            cwd: cwd,
            toolName: row["tool_name"] as String?,
            toolDetail: row["tool_detail"] as String?,
            awaitingReason: row["awaiting_reason"] as String?,
            errorCategory: row["error_category"] as String?,
            errorMessage: row["error_message"] as String?,
            modelDisplayName: row["model_display_name"] as String?,
            eventAt: eventAt
        )
    }

    private static func parseISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

public struct TerminalSplitSnapshotInput: Sendable, Equatable {
    public let primaryHostSessionID: UUID
    public let splitHostSessionID: UUID
    public let axis: String
    public let splitBeforePrimary: Bool
    public let splitFraction: Double

    public init(
        primaryHostSessionID: UUID,
        splitHostSessionID: UUID,
        axis: String,
        splitBeforePrimary: Bool,
        splitFraction: Double
    ) {
        self.primaryHostSessionID = primaryHostSessionID
        self.splitHostSessionID = splitHostSessionID
        self.axis = axis
        self.splitBeforePrimary = splitBeforePrimary
        self.splitFraction = splitFraction
    }
}
