//
//  ConversationIndex.swift
//  WorkspaceManagerCore
//
//  Keeps the `conversation_index` table a faithful lookup over the Conversation record files,
//  and carries identities learned before the records existed into them, once. The table is
//  derived: it is rebuilt from the files at launch and synced from them when they change.
//

import Foundation
import GRDB

public struct ConversationIndexEntry: Equatable, Sendable {
    public let conversationID: String
    public let harness: String
    public let hostSessionID: UUID?
    public let tmuxServerPID: Int?
    public let tmuxSessionID: String?
    public let cwd: String
    public let observedAt: Date

    public init(record: ConversationRecord) {
        conversationID = record.conversationID
        harness = record.harness
        hostSessionID = record.lastSeenIn?.hostSessionID.flatMap(UUID.init(uuidString:))
        tmuxServerPID = record.lastSeenIn?.tmux?.serverPID
        tmuxSessionID = record.lastSeenIn?.tmux?.sessionID
        cwd = record.cwd
        observedAt = Self.millisecondPrecision(record.observedAt)
    }

    init?(row: Row) {
        guard let conversationID: String = row["conversation_id"],
            let harness: String = row["harness"],
            let cwd: String = row["cwd"],
            let observedAt = (row["observed_at"] as String?).flatMap(ConversationRecordJSON.date)
        else { return nil }
        self.conversationID = conversationID
        self.harness = harness
        hostSessionID = (row["host_session_id"] as String?).flatMap(UUID.init(uuidString:))
        tmuxServerPID = row["tmux_server_pid"]
        tmuxSessionID = row["tmux_session_id"]
        self.cwd = cwd
        self.observedAt = observedAt
    }

    /// The table stores times as ISO-8601 with milliseconds, so an entry read from a file and
    /// the same entry read back from the table compare equal.
    private static func millisecondPrecision(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }
}

/// A conversation a tile reported to the app, as the app's own event history remembers it.
public struct ConversationSighting: Equatable, Sendable {
    public let hostSessionID: UUID
    public let conversationID: String
    public let cwd: String
    public let observedAt: Date
}

public struct ConversationIndexer: Sendable {
    public static let migrationMetadataKeyPrefix = "conversation_records_migrated_at"

    public let records: ConversationRecordStore
    public let localState: LocalStateStore
    public let launchRecords: AgentLaunchRecordStore

    public init(
        records: ConversationRecordStore,
        localState: LocalStateStore,
        launchRecords: AgentLaunchRecordStore = AgentLaunchRecordStore()
    ) {
        self.records = records
        self.localState = localState
        self.launchRecords = launchRecords
    }

    /// What the app runs at launch: the one-time migration, then a rebuild, so a record a
    /// hook wrote while the app was down is in the index before anything reads it.
    public func launch() async throws {
        try await migrateOnce()
        try await rebuild()
    }

    public func rebuild() async throws {
        try await localState.rebuildConversationIndex(entries())
    }

    public func sync() async throws {
        try await localState.syncConversationIndex(entries())
    }

    private func entries() -> [ConversationIndexEntry] {
        records.all().map(ConversationIndexEntry.init(record:))
    }

    /// What one migration pass did with each observation it had.
    public struct MigrationOutcome: Equatable, Sendable {
        public var written = 0
        /// Observations no record can hold, such as an id that is not a UUID. Retrying
        /// cannot change them, so they do not hold the migration open.
        public var rejected = 0
        /// Writes that may succeed later: a busy lock, an unwritable directory.
        public var failed = 0
        /// The marker was already there, so nothing was attempted.
        public var alreadyDone = false

        public init(written: Int = 0, rejected: Int = 0, failed: Int = 0, alreadyDone: Bool = false) {
            self.written = written
            self.rejected = rejected
            self.failed = failed
            self.alreadyDone = alreadyDone
        }
    }

    /// The marker is per destination: the same database pointed at a new records directory
    /// has carried nothing there yet.
    public var migrationMetadataKey: String {
        "\(Self.migrationMetadataKeyPrefix):\(records.directory.resolvingSymlinksInPath().path)"
    }

    /// Writes a record for every conversation the app already knew before records existed:
    /// each Launch Record that names one, and each id the current and previous runs' tiles
    /// reported. It is marked done for this database and destination only once every
    /// observation was written or rejected, so a failed pass runs again at the next launch.
    /// After that it never runs again: a rerun would bring back a record a later cleanup
    /// removed on purpose.
    ///
    /// Each sighting carries the time it was made, so against a record a hook has written
    /// since, it only fills what that record lacks.
    @discardableResult
    public func migrateOnce(now: Date = Date()) async throws -> MigrationOutcome {
        let key = migrationMetadataKey
        guard try await localState.metadataValue(forKey: key) == nil else { return .init(alreadyDone: true) }
        var observations = launchRecordObservations()
        observations += try await localState.fetchRecentConversationSightings().map { sighting in
            ConversationObservation(
                conversationID: sighting.conversationID,
                cwd: sighting.cwd,
                observedAt: sighting.observedAt,
                observedBy: .migration,
                lastSeenIn: .init(hostSessionID: sighting.hostSessionID.uuidString)
            )
        }
        var outcome = MigrationOutcome()
        for observation in observations {
            do {
                switch try records.record(observation, lockBudget: .seconds(1)) {
                case .written: outcome.written += 1
                case .lockBusy: outcome.failed += 1
                }
            } catch ConversationRecordStore.WriteError.invalidConversationID {
                outcome.rejected += 1
            } catch {
                outcome.failed += 1
            }
        }
        if outcome.failed == 0 {
            try await localState.setMetadataValue(ConversationRecordJSON.string(now), forKey: key)
        }
        return outcome
    }

    private func launchRecordObservations() -> [ConversationObservation] {
        let sockets =
            (try? FileManager.default.contentsOfDirectory(
                at: launchRecords.directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        return sockets.flatMap { launchRecords.all(socketLabel: $0.lastPathComponent) }.compactMap { launch in
            guard let identity = launch.identity else { return nil }
            return ConversationObservation(
                conversationID: identity.conversationID,
                cwd: launch.workspacePath,
                workspacePath: launch.workspacePath,
                socketLabel: launch.socketLabel,
                observedAt: launch.resumedAt.map { max($0, launch.launchedAt) } ?? launch.launchedAt,
                observedBy: .migration,
                launch: .init(handle: launch.handle, model: identity.requestedModel, effort: identity.requestedEffort)
            )
        }
    }
}
