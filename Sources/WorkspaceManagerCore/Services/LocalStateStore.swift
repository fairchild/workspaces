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
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "LocalStateStore")

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
            // Best-effort retention once per launch. Detached so it never blocks
            // startup; it only prunes aged rows and never touches active sessions,
            // so racing early writes is safe.
            Task.detached(priority: .utility) {
                do {
                    let outcome = try await store.runRetention()
                    log.info(
                        "[LocalStateStore] retention: sessions=\(outcome.deletedEndedSessions, privacy: .public) agent_events=\(outcome.deletedAgentEvents, privacy: .public) diagnostics=\(outcome.deletedDiagnosticEvents, privacy: .public) integrity=\((outcome.integrityOK ? "ok" : outcome.integrityDetail), privacy: .public)"
                    )
                } catch {
                    log.error("[LocalStateStore] retention failed: \(String(describing: error), privacy: .public)")
                }
            }
            return LocalStateStoreBootstrapResult(
                store: store,
                mode: .persistent(path: databaseURL.path),
                bootstrapErrors: []
            )
        } catch {
            let message = "Failed to open local state store: \(String(describing: error))"
            log.error("[LocalStateStore] \(message, privacy: .public)")
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
    /// When the last retention pass completed, and whether its `PRAGMA quick_check`
    /// reported a sound database. `nil` until retention has run at least once.
    public let lastRetentionAt: Date?
    public let integrityOK: Bool?

    public init(
        schemaVersion: Int,
        databasePath: String,
        generatedAt: Date,
        tableCounts: [String: Int],
        latestEventTimes: [String: Date] = [:],
        lastRetentionAt: Date? = nil,
        integrityOK: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.databasePath = databasePath
        self.generatedAt = generatedAt
        self.tableCounts = tableCounts
        self.latestEventTimes = latestEventTimes
        self.lastRetentionAt = lastRetentionAt
        self.integrityOK = integrityOK
    }
}

/// Bounds how long the high-volume tables keep rows. Ages are measured against
/// the retention pass's `now`; anything older than a table's max age is eligible
/// for pruning except the rows the cold-start restore path depends on, which are
/// preserved regardless of age (see `LocalStateStore.runRetention`).
public struct LocalStateRetentionPolicy: Sendable, Equatable {
    public var agentEventMaxAge: TimeInterval
    public var diagnosticEventMaxAge: TimeInterval
    public var endedSessionMaxAge: TimeInterval

    public init(
        agentEventMaxAge: TimeInterval = 30 * 86_400,
        diagnosticEventMaxAge: TimeInterval = 14 * 86_400,
        endedSessionMaxAge: TimeInterval = 30 * 86_400
    ) {
        self.agentEventMaxAge = agentEventMaxAge
        self.diagnosticEventMaxAge = diagnosticEventMaxAge
        self.endedSessionMaxAge = endedSessionMaxAge
    }

    public static let `default` = LocalStateRetentionPolicy()
}

/// Result of one retention pass: how many rows each high-volume table shed, plus
/// the `PRAGMA quick_check` health signal captured at the end of the pass.
/// Counts are the rows each DELETE removed directly — child rows cleared by an
/// ended session's `ON DELETE CASCADE` are not included in `deletedAgentEvents`.
public struct LocalStateRetentionOutcome: Sendable, Equatable {
    public let deletedEndedSessions: Int
    public let deletedAgentEvents: Int
    public let deletedDiagnosticEvents: Int
    public let integrityOK: Bool
    public let integrityDetail: String

    public init(
        deletedEndedSessions: Int,
        deletedAgentEvents: Int,
        deletedDiagnosticEvents: Int,
        integrityOK: Bool,
        integrityDetail: String
    ) {
        self.deletedEndedSessions = deletedEndedSessions
        self.deletedAgentEvents = deletedAgentEvents
        self.deletedDiagnosticEvents = deletedDiagnosticEvents
        self.integrityOK = integrityOK
        self.integrityDetail = integrityDetail
    }
}

public actor LocalStateStore {
    public static let schemaVersion = 2
    public let databaseURL: URL

    /// Identity of this app run. One store instance == one process == one run, so
    /// every terminal session recorded through it is stamped with this run, and
    /// cold-start restore can offer only the single most recent *prior* run
    /// (issue #783 #2) instead of every never-cleanly-closed session ever.
    private let runID: String
    private let runStartedAt: String

    private let dbPool: DatabasePool

    public init(
        databaseURL: URL,
        runID: UUID = UUID(),
        runStartedAt: Date = Date()
    ) throws {
        self.databaseURL = databaseURL
        self.runID = runID.uuidString
        self.runStartedAt = Self.isoString(runStartedAt)

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
        try Self.endStaleSessionsFromOlderRuns(
            in: dbPool,
            currentRunID: self.runID,
            currentRunStartedAt: self.runStartedAt
        )
    }

    /// Startup hygiene (#1347 D4): rows still flagged active from runs *older
    /// than the most-recent prior run* (or from before run tracking existed)
    /// can never be offered again — cold-start restore reads only that single
    /// prior run, and continuity rehydration upserts move live ids to the
    /// current run — yet they polluted every `is_active = 1` listing and
    /// blocked agent-event retention (135 "active" rows vs 13 live tiles
    /// measured on 2026-08-23).
    ///
    /// Two stages, because ending a row is terminal for its id (#1239's
    /// ended-wins upsert guard) while the continuity manifest can still hold a
    /// stranded id whose upsert never landed in the intervening run:
    ///
    /// 1. This launch only *deactivates* stale rows (`is_active = 0`, no
    ///    `ended_at`) — a manifest rehydration that lands later this launch
    ///    still revives the row into the current run.
    /// 2. A row a *previous* launch deactivated and nothing revived since is
    ///    ended terminally, which is what makes it eligible for retention
    ///    deletion. (A session would have to hit the crash-before-upsert edge
    ///    in two consecutive runs to be ended while its tile is still open;
    ///    even then the tile keeps working and heals on close-and-reopen.)
    ///
    /// The current run's rows and the single restorable prior run's rows are
    /// never touched, and a store stamped with an older run start (the fixture
    /// continuity seeder opens one deliberately) cannot deactivate rows of
    /// runs newer than itself.
    private static func endStaleSessionsFromOlderRuns(
        in dbPool: DatabasePool,
        currentRunID: String,
        currentRunStartedAt: String
    ) throws {
        let now = isoString(Date())
        let stalePredicate = """
            (
                run_id IS NULL
                OR (
                    run_id != ?
                    AND run_started_at < ?
                    AND run_id IS NOT (
                        SELECT run_id
                        FROM terminal_sessions
                        WHERE run_started_at IS NOT NULL AND run_started_at < ?
                        ORDER BY run_started_at DESC
                        LIMIT 1
                    )
                )
            )
            """
        try dbPool.write { db in
            // Stage 2 first: rows a previous launch deactivated. Running it
            // before stage 1 keeps this launch's own deactivations revivable.
            try db.execute(
                sql: """
                    UPDATE terminal_sessions
                    SET ended_at = ?
                    WHERE is_active = 0
                      AND ended_at IS NULL
                      AND \(stalePredicate)
                    """,
                arguments: [now, currentRunID, currentRunStartedAt, currentRunStartedAt]
            )
            try db.execute(
                sql: """
                    UPDATE terminal_sessions
                    SET is_active = 0
                    WHERE is_active = 1
                      AND ended_at IS NULL
                      AND \(stalePredicate)
                    """,
                arguments: [currentRunID, currentRunStartedAt, currentRunStartedAt]
            )
        }
    }

    /// Upserts a session's continuity row. Ended is terminal for a
    /// `host_session_id`: the conflict update is guarded on `ended_at IS NULL`,
    /// so an in-flight upsert that lands after `markTerminalSessionEnded` is a
    /// no-op instead of resurrecting a closed tile into the restore set (#1239).
    ///
    /// Ids are not fresh per surface across runs. With `restoreSessionsOnLaunch`
    /// off — the default — launch rehydrates the previous run's tabs from the
    /// terminal continuity manifest under their recorded ids, so this store does
    /// see a later run upsert an id it already holds. Those rows are live ones:
    /// closing a surface ends its row and drops it from the manifest off the same
    /// session-list change, so the guard passes and the row moves to the current
    /// run. An ended id can only come back if a crash loses the manifest write
    /// after the close landed, and there the guard holds the row ended — the
    /// surface runs but stays out of the continuity and restore listings until it
    /// is closed and reopened under a new id.
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
        // The session's chosen name (split-pane or restore override included), not a
        // directory re-derivation — restore probes and reattaches by this recorded value.
        let tmuxSessionName = terminalMode == "tmux_per_session" ? session.effectiveTmuxSessionName : nil
        let runID = self.runID
        let runStartedAt = self.runStartedAt

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
                        run_id,
                        run_started_at,
                        ended_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
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
                        run_id = excluded.run_id,
                        run_started_at = excluded.run_started_at
                    WHERE terminal_sessions.ended_at IS NULL
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
                    runID,
                    runStartedAt,
                ])
        }
    }

    /// Marks a session's row ended. Idempotent — the first close time wins, so a
    /// repeated close cannot shift `ended_at` or `last_seen_at`. `endedAt` is the
    /// moment the app closed the surface (captured by the caller at close, not
    /// when a queued write executes).
    public func markTerminalSessionEnded(hostSessionID: UUID, endedAt: Date = Date()) async throws {
        let now = Self.isoString(endedAt)
        try await dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE terminal_sessions
                    SET ended_at = ?, is_active = 0, last_seen_at = ?
                    WHERE host_session_id = ? AND ended_at IS NULL
                    """,
                arguments: [now, now, hostSessionID.uuidString])
        }
    }

    public func recordTerminalLayoutSnapshot(
        activeHostSessionID: UUID?,
        selectedSurfaceKind: String?,
        selectedSurfaceID: String?,
        splitPanes: [TerminalSplitSnapshotInput] = [],
        capturedAt: Date = Date()
    ) async throws {
        let snapshotID = UUID().uuidString
        let now = Self.isoString(capturedAt)
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

        let runID = self.runID
        let runStartedAt = self.runStartedAt
        try await dbPool.write { db in
            try Self.ensureTerminalSessionRow(
                db,
                hostSessionID: hostSessionID,
                cwd: status.cwd,
                now: now,
                runID: runID,
                runStartedAt: runStartedAt
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
        now: String,
        runID: String,
        runStartedAt: String
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
                    run_id,
                    run_started_at,
                    ended_at
                )
                VALUES (?, ?, 'host_path', NULL, ?, NULL, NULL, ?, 'unknown', NULL, 0, NULL, 0, ?, ?, ?, ?, NULL)
                ON CONFLICT(host_session_id) DO NOTHING
                """,
            arguments: [
                hostSessionID.uuidString,
                "host_session_id:\(hostSessionID.uuidString)",
                cwd,
                cwd,
                now,
                now,
                runID,
                runStartedAt,
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

    /// Continuity read model (local-state-store plan, slice 3): the most recent
    /// terminal sessions, each joined with the latest agent status event recorded
    /// for that host session (or `nil` agent fields when none exists). Rows are
    /// ordered newest `last_seen_at` first. Pass `activeOnly: true` to restrict to
    /// sessions that have not been marked ended — after a crash or reboot the
    /// previous run's sessions typically remain active, which is what a cold-start
    /// restore wants to enumerate.
    public func fetchContinuitySessions(
        activeOnly: Bool = false,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> [TerminalSessionContinuityRow] {
        let cappedLimit = max(0, limit)
        let cappedOffset = max(0, offset)
        let activeOnlyValue = activeOnly ? 1 : 0
        return try await dbPool.read { db -> [TerminalSessionContinuityRow] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        ts.host_session_id,
                        ts.session_key,
                        ts.target_kind,
                        ts.target_id,
                        ts.target_path,
                        ts.backend_identifier,
                        ts.backend_instance_id,
                        ts.directory_path,
                        ts.terminal_mode,
                        ts.tmux_session_name,
                        ts.custom_command_present,
                        ts.is_active,
                        ts.created_at,
                        ts.last_seen_at,
                        ts.ended_at,
                        ae.agent_session_id,
                        ae.agent_kind,
                        ae.run_state AS agent_run_state,
                        ae.cwd AS agent_cwd,
                        ae.model_display_name AS agent_model_display_name,
                        ae.event_at AS agent_event_at
                    FROM terminal_sessions ts
                    LEFT JOIN (
                        SELECT
                            host_session_id,
                            agent_session_id,
                            agent_kind,
                            run_state,
                            cwd,
                            model_display_name,
                            event_at,
                            ROW_NUMBER() OVER (
                                PARTITION BY host_session_id
                                ORDER BY event_at DESC, id DESC
                            ) AS event_rank
                        FROM agent_status_events
                    ) ae ON ae.host_session_id = ts.host_session_id AND ae.event_rank = 1
                    WHERE (? = 0 OR (ts.is_active = 1 AND ts.ended_at IS NULL))
                    ORDER BY ts.last_seen_at DESC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [activeOnlyValue, cappedLimit, cappedOffset]
            )
            return rows.compactMap(TerminalSessionContinuityRow.init(row:))
        }
    }

    /// Cold-start restore read model (issue #783 #2): the active continuity rows
    /// belonging to the single most-recent *prior* app run — the run whose
    /// `run_started_at` is the greatest value strictly less than this store
    /// instance's run. Rows from older never-cleanly-closed runs and from the
    /// current run are excluded, so restore offers only the user's previous
    /// session set instead of an all-time backlog of stale "active" rows. Returns
    /// `[]` on first launch and for pre-v2 rows (NULL `run_id`).
    public func fetchPreviousRunSessions(limit: Int = 100) async throws -> [TerminalSessionContinuityRow] {
        let cappedLimit = max(0, limit)
        let currentRunStartedAt = runStartedAt
        return try await dbPool.read { db -> [TerminalSessionContinuityRow] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        ts.host_session_id,
                        ts.session_key,
                        ts.target_kind,
                        ts.target_id,
                        ts.target_path,
                        ts.backend_identifier,
                        ts.backend_instance_id,
                        ts.directory_path,
                        ts.terminal_mode,
                        ts.tmux_session_name,
                        ts.custom_command_present,
                        ts.is_active,
                        ts.created_at,
                        ts.last_seen_at,
                        ts.ended_at,
                        ae.agent_session_id,
                        ae.agent_kind,
                        ae.run_state AS agent_run_state,
                        ae.cwd AS agent_cwd,
                        ae.model_display_name AS agent_model_display_name,
                        ae.event_at AS agent_event_at
                    FROM terminal_sessions ts
                    LEFT JOIN (
                        SELECT
                            host_session_id,
                            agent_session_id,
                            agent_kind,
                            run_state,
                            cwd,
                            model_display_name,
                            event_at,
                            ROW_NUMBER() OVER (
                                PARTITION BY host_session_id
                                ORDER BY event_at DESC, id DESC
                            ) AS event_rank
                        FROM agent_status_events
                    ) ae ON ae.host_session_id = ts.host_session_id AND ae.event_rank = 1
                    WHERE ts.run_id = (
                        SELECT run_id
                        FROM terminal_sessions
                        WHERE run_started_at IS NOT NULL AND run_started_at < ?
                        ORDER BY run_started_at DESC
                        LIMIT 1
                    )
                    AND ts.is_active = 1
                    AND ts.ended_at IS NULL
                    ORDER BY ts.last_seen_at DESC
                    LIMIT ?
                    """,
                arguments: [currentRunStartedAt, cappedLimit]
            )
            return rows.compactMap(TerminalSessionContinuityRow.init(row:))
        }
    }

    /// The `run_id` of the single most-recent *prior* app run — the same run
    /// `fetchPreviousRunSessions` scopes to — or `nil` on first launch / pre-v2
    /// data. Lets restore identify which prior run a plan was built from, so an
    /// already-handled (restored or dismissed) run is not re-offered when a later
    /// launch selects the same prior run again.
    public func fetchPreviousRunID() async throws -> String? {
        let currentRunStartedAt = runStartedAt
        return try await dbPool.read { db -> String? in
            try String.fetchOne(
                db,
                sql: """
                    SELECT run_id
                    FROM terminal_sessions
                    WHERE run_started_at IS NOT NULL AND run_started_at < ?
                    ORDER BY run_started_at DESC
                    LIMIT 1
                    """,
                arguments: [currentRunStartedAt]
            )
        }
    }

    /// Continuity read model (local-state-store plan, slice 3): the most recently
    /// captured terminal layout snapshot with its split pane rows, or `nil` when
    /// no snapshot has been recorded.
    public func fetchLatestLayoutSnapshot() async throws -> TerminalLayoutSnapshotRow? {
        try await dbPool.read { db -> TerminalLayoutSnapshotRow? in
            guard
                let snapshotRow = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id, captured_at, active_host_session_id, selected_surface_kind, selected_surface_id
                        FROM terminal_layout_snapshots
                        ORDER BY captured_at DESC, id DESC
                        LIMIT 1
                        """
                )
            else {
                return nil
            }

            guard let snapshotID = snapshotRow["id"] as String? else { return nil }
            let splitRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT primary_host_session_id, split_host_session_id, axis, split_before_primary, split_fraction
                    FROM terminal_split_snapshots
                    WHERE snapshot_id = ?
                    """,
                arguments: [snapshotID]
            )
            let splitPanes = splitRows.compactMap { row -> TerminalSplitSnapshotInput? in
                guard let primaryString = row["primary_host_session_id"] as String?,
                    let primaryID = UUID(uuidString: primaryString),
                    let splitString = row["split_host_session_id"] as String?,
                    let splitID = UUID(uuidString: splitString),
                    let axis = row["axis"] as String?,
                    let splitBeforePrimary = row["split_before_primary"] as Int?,
                    let splitFraction = row["split_fraction"] as Double?
                else {
                    return nil
                }
                return TerminalSplitSnapshotInput(
                    primaryHostSessionID: primaryID,
                    splitHostSessionID: splitID,
                    axis: axis,
                    splitBeforePrimary: splitBeforePrimary == 1,
                    splitFraction: splitFraction
                )
            }
            return TerminalLayoutSnapshotRow(row: snapshotRow, splitPanes: splitPanes)
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

    // MARK: - Retention & Health

    /// Prunes aged rows from the high-volume tables and probes integrity, without
    /// disturbing anything the cold-start restore path reads. Two invariants hold
    /// regardless of `policy` or `now`:
    ///
    /// - Only ended *and* aged `terminal_sessions` are removed, so every active
    ///   row — including the previous run's resumable sessions that
    ///   `fetchPreviousRunSessions` enumerates — is preserved. Removing an ended
    ///   session cascades its `agent_status_events` and split snapshots away.
    /// - The latest `agent_status_events` row per still-active session is kept
    ///   regardless of age (it carries the `agent_session_id` that drives
    ///   `claude --resume`); only older, non-latest events past the cutoff are
    ///   pruned. The preserved set is computed with the same latest-per-session
    ///   projection the continuity readers use, so what survives is exactly what
    ///   they return.
    ///
    /// The pass runs in a single write transaction and finishes with
    /// `PRAGMA quick_check`, recording the result so `summary()` can surface it.
    @discardableResult
    public func runRetention(
        policy: LocalStateRetentionPolicy = .default,
        now: Date = Date()
    ) async throws -> LocalStateRetentionOutcome {
        let sessionCutoff = Self.isoString(now.addingTimeInterval(-policy.endedSessionMaxAge))
        let agentCutoff = Self.isoString(now.addingTimeInterval(-policy.agentEventMaxAge))
        let diagnosticCutoff = Self.isoString(now.addingTimeInterval(-policy.diagnosticEventMaxAge))
        let completedAt = Self.isoString(now)
        let currentRunStartedAt = runStartedAt

        let deletions = try await dbPool.write { db -> (sessions: Int, agentEvents: Int, diagnostics: Int) in
            // Ended + aged sessions first; ON DELETE CASCADE clears their agent
            // events and split snapshots. Active rows never match this predicate.
            // One exception: a *fully-ended* most-recent prior run keeps its rows.
            // `fetchPreviousRunSessions` selects the prior run from all rows, so
            // deleting the last rows of a cleanly-closed prior run would make the
            // reader fall back to an older run's stale never-ended crash rows and
            // offer the wrong restore set — a cleanly-closed prior run must read
            // as "nothing to restore", not as an older run's leftovers. When the
            // prior run still has active rows, those anchor the reader and its
            // ended rows prune normally. (The EXISTS probe checks active rows,
            // which this statement never deletes, so it is stable mid-delete.)
            try db.execute(
                sql: """
                    DELETE FROM terminal_sessions
                    WHERE is_active = 0 AND ended_at IS NOT NULL AND ended_at < ?
                      AND (
                          run_id IS NOT (
                              SELECT run_id
                              FROM terminal_sessions
                              WHERE run_started_at IS NOT NULL AND run_started_at < ?
                              ORDER BY run_started_at DESC
                              LIMIT 1
                          )
                          OR EXISTS (
                              SELECT 1 FROM terminal_sessions anchor
                              WHERE anchor.run_id = terminal_sessions.run_id
                                AND anchor.is_active = 1 AND anchor.ended_at IS NULL
                          )
                      )
                    """,
                arguments: [sessionCutoff, currentRunStartedAt])
            let deletedEndedSessions = db.changesCount

            // Aged agent events, except the latest per still-active session. The
            // ROW_NUMBER projection mirrors fetchContinuitySessions /
            // fetchPreviousRunSessions, so the row each reader joins as "latest"
            // is exactly the row this keeps.
            try db.execute(
                sql: """
                    DELETE FROM agent_status_events
                    WHERE event_at < ?
                      AND id NOT IN (
                          SELECT id FROM (
                              SELECT
                                  ae.id,
                                  ROW_NUMBER() OVER (
                                      PARTITION BY ae.host_session_id
                                      ORDER BY ae.event_at DESC, ae.id DESC
                                  ) AS event_rank
                              FROM agent_status_events ae
                              JOIN terminal_sessions ts
                                  ON ts.host_session_id = ae.host_session_id
                              WHERE ts.is_active = 1 AND ts.ended_at IS NULL
                          )
                          WHERE event_rank = 1
                      )
                    """,
                arguments: [agentCutoff])
            let deletedAgentEvents = db.changesCount

            try db.execute(
                sql: "DELETE FROM diagnostic_events WHERE event_at < ?",
                arguments: [diagnosticCutoff])
            let deletedDiagnosticEvents = db.changesCount

            return (deletedEndedSessions, deletedAgentEvents, deletedDiagnosticEvents)
        }

        // The integrity probe runs outside the pruning transaction: quick_check
        // scans the whole file, and holding the writer slot for that at launch
        // would stall the first session/event writes. A read connection suffices
        // — the probe is a health signal, not a gate on the deletes.
        let quickCheck = try await dbPool.read { db in
            try String.fetchAll(db, sql: "PRAGMA quick_check")
        }
        let integrityOK = quickCheck == ["ok"]
        let integrityDetail = quickCheck.isEmpty ? "ok" : quickCheck.joined(separator: "; ")

        try await dbPool.write { db in
            try Self.writeMetadataValue(db, key: "last_retention_at", value: completedAt)
            try Self.writeMetadataValue(db, key: "last_integrity_ok", value: integrityOK ? "1" : "0")
            try Self.writeMetadataValue(db, key: "last_integrity_detail", value: integrityDetail)
        }

        return LocalStateRetentionOutcome(
            deletedEndedSessions: deletions.sessions,
            deletedAgentEvents: deletions.agentEvents,
            deletedDiagnosticEvents: deletions.diagnostics,
            integrityOK: integrityOK,
            integrityDetail: integrityDetail
        )
    }

    /// Standalone `PRAGMA quick_check` probe. Returns `true` when SQLite reports a
    /// structurally sound database (`["ok"]`).
    public func checkIntegrity() async throws -> Bool {
        try await dbPool.read { db in
            try String.fetchAll(db, sql: "PRAGMA quick_check") == ["ok"]
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

        let metadata = try await dbPool.read { db -> [String: String] in
            var result: [String: String] = [:]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT key, value FROM local_state_metadata
                    WHERE key IN ('last_retention_at', 'last_integrity_ok')
                    """
            )
            for row in rows {
                result[row["key"]] = row["value"]
            }
            return result
        }

        return LocalStateStoreSummary(
            schemaVersion: Self.schemaVersion,
            databasePath: databaseURL.path,
            generatedAt: Date(),
            tableCounts: counts,
            latestEventTimes: latestEventTimes,
            lastRetentionAt: metadata["last_retention_at"].flatMap(Self.date(fromISOString:)),
            integrityOK: metadata["last_integrity_ok"].map { $0 == "1" }
        )
    }

    private static func writeMetadata(in dbPool: DatabasePool) throws {
        try dbPool.write { db in
            try writeMetadataValue(db, key: "schema_version", value: String(Self.schemaVersion))
        }
    }

    private static func writeMetadataValue(_ db: Database, key: String, value: String) throws {
        try db.execute(
            sql: """
                INSERT INTO local_state_metadata (key, value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value = excluded.value,
                    updated_at = excluded.updated_at
                """,
            arguments: [key, value, Self.isoString(Date())])
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
        migrator.registerMigration("v2") { db in
            // App-run epoch (issue #783 #2): stamp each session with the run that
            // recorded it so cold-start restore can offer only the previous run,
            // not every never-cleanly-closed session. Additive; pre-v2 rows keep
            // NULL and are excluded from previous-run restore.
            try db.execute(
                sql: """
                    ALTER TABLE terminal_sessions ADD COLUMN run_id TEXT;
                    ALTER TABLE terminal_sessions ADD COLUMN run_started_at TEXT;

                    CREATE INDEX IF NOT EXISTS idx_terminal_sessions_run
                        ON terminal_sessions(run_started_at DESC);
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
        parseLocalStateISODate(value)
    }
}

/// Read-side projection of one `terminal_sessions` row joined with the latest
/// `agent_status_events` row for the same host session. Agent fields are `nil`
/// when no agent event was ever recorded. Strings are kept verbatim from the
/// tables; resolving targets against current SwiftData rows is a caller concern.
public struct TerminalSessionContinuityRow: Sendable, Equatable, Identifiable {
    public let hostSessionID: UUID
    public let sessionKey: String
    public let targetKind: String
    public let targetID: String?
    public let targetPath: String?
    public let backendIdentifier: String?
    public let backendInstanceID: String?
    public let directoryPath: String
    public let terminalMode: String
    public let tmuxSessionName: String?
    public let customCommandPresent: Bool
    public let isActive: Bool
    public let createdAt: Date
    public let lastSeenAt: Date
    public let endedAt: Date?
    public let agentSessionID: String?
    public let agentKind: String?
    public let agentRunState: String?
    public let agentCwd: String?
    public let agentModelDisplayName: String?
    public let agentEventAt: Date?

    public var id: UUID { hostSessionID }

    public init(
        hostSessionID: UUID,
        sessionKey: String,
        targetKind: String,
        targetID: String?,
        targetPath: String?,
        backendIdentifier: String?,
        backendInstanceID: String?,
        directoryPath: String,
        terminalMode: String,
        tmuxSessionName: String?,
        customCommandPresent: Bool,
        isActive: Bool,
        createdAt: Date,
        lastSeenAt: Date,
        endedAt: Date?,
        agentSessionID: String?,
        agentKind: String?,
        agentRunState: String?,
        agentCwd: String?,
        agentModelDisplayName: String?,
        agentEventAt: Date?
    ) {
        self.hostSessionID = hostSessionID
        self.sessionKey = sessionKey
        self.targetKind = targetKind
        self.targetID = targetID
        self.targetPath = targetPath
        self.backendIdentifier = backendIdentifier
        self.backendInstanceID = backendInstanceID
        self.directoryPath = directoryPath
        self.terminalMode = terminalMode
        self.tmuxSessionName = tmuxSessionName
        self.customCommandPresent = customCommandPresent
        self.isActive = isActive
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.endedAt = endedAt
        self.agentSessionID = agentSessionID
        self.agentKind = agentKind
        self.agentRunState = agentRunState
        self.agentCwd = agentCwd
        self.agentModelDisplayName = agentModelDisplayName
        self.agentEventAt = agentEventAt
    }

    init?(row: Row) {
        guard let hostSessionIDString = row["host_session_id"] as String?,
            let hostSessionID = UUID(uuidString: hostSessionIDString),
            let sessionKey = row["session_key"] as String?,
            let targetKind = row["target_kind"] as String?,
            let directoryPath = row["directory_path"] as String?,
            let terminalMode = row["terminal_mode"] as String?,
            let createdAtRaw = row["created_at"] as String?,
            let createdAt = parseLocalStateISODate(createdAtRaw),
            let lastSeenAtRaw = row["last_seen_at"] as String?,
            let lastSeenAt = parseLocalStateISODate(lastSeenAtRaw)
        else {
            return nil
        }

        self.init(
            hostSessionID: hostSessionID,
            sessionKey: sessionKey,
            targetKind: targetKind,
            targetID: row["target_id"] as String?,
            targetPath: row["target_path"] as String?,
            backendIdentifier: row["backend_identifier"] as String?,
            backendInstanceID: row["backend_instance_id"] as String?,
            directoryPath: directoryPath,
            terminalMode: terminalMode,
            tmuxSessionName: row["tmux_session_name"] as String?,
            customCommandPresent: (row["custom_command_present"] as Int? ?? 0) == 1,
            isActive: (row["is_active"] as Int? ?? 0) == 1,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt,
            endedAt: (row["ended_at"] as String?).flatMap(parseLocalStateISODate),
            agentSessionID: row["agent_session_id"] as String?,
            agentKind: row["agent_kind"] as String?,
            agentRunState: row["agent_run_state"] as String?,
            agentCwd: row["agent_cwd"] as String?,
            agentModelDisplayName: row["agent_model_display_name"] as String?,
            agentEventAt: (row["agent_event_at"] as String?).flatMap(parseLocalStateISODate)
        )
    }
}

/// Read-side projection of the latest `terminal_layout_snapshots` row plus its
/// `terminal_split_snapshots` children.
public struct TerminalLayoutSnapshotRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let capturedAt: Date
    public let activeHostSessionID: UUID?
    public let selectedSurfaceKind: String?
    public let selectedSurfaceID: String?
    public let splitPanes: [TerminalSplitSnapshotInput]

    public init(
        id: String,
        capturedAt: Date,
        activeHostSessionID: UUID?,
        selectedSurfaceKind: String?,
        selectedSurfaceID: String?,
        splitPanes: [TerminalSplitSnapshotInput]
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.activeHostSessionID = activeHostSessionID
        self.selectedSurfaceKind = selectedSurfaceKind
        self.selectedSurfaceID = selectedSurfaceID
        self.splitPanes = splitPanes
    }

    init?(row: Row, splitPanes: [TerminalSplitSnapshotInput]) {
        guard let id = row["id"] as String?,
            let capturedAtRaw = row["captured_at"] as String?,
            let capturedAt = parseLocalStateISODate(capturedAtRaw)
        else {
            return nil
        }

        self.init(
            id: id,
            capturedAt: capturedAt,
            activeHostSessionID: (row["active_host_session_id"] as String?).flatMap(UUID.init(uuidString:)),
            selectedSurfaceKind: row["selected_surface_kind"] as String?,
            selectedSurfaceID: row["selected_surface_id"] as String?,
            splitPanes: splitPanes
        )
    }
}

private func parseLocalStateISODate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
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
