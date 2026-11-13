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
    public static let migrationMetadataKeyPrefix = "conversation_records_migration"

    public let records: ConversationRecordStore
    public let localState: LocalStateStore
    public let launchRecords: AgentLaunchRecordStore
    /// Runs between staging and writing. Tests use it to put another attempt there.
    var afterStaging: (@Sendable () async throws -> Void)?

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

    /// What the migration still owes this destination, keyed by conversation id: absent
    /// before any attempt, and empty once every observation has been written or rejected.
    /// Empty is the only completed state. The same database pointed at a new records
    /// directory has carried nothing there yet, so the key is per destination.
    public var migrationMetadataKey: String {
        "\(Self.migrationMetadataKeyPrefix):\(destination)"
    }

    /// The directory as configured, with `.` and `..` folded by text alone. Anything that
    /// consults the file system (resolving links, Foundation's standardizing, which drops a
    /// leading `/private` only when the result exists) answers differently once the first
    /// writer creates the directory, and would move the key away from what earlier attempts
    /// staged. Two spellings of one directory (a link and its target, `/tmp` and
    /// `/private/tmp`) are two destinations; carrying the same observations into one
    /// directory twice is safe, because the merge is idempotent.
    private var destination: String {
        var components: [String] = []
        for component in records.directory.pathComponents.dropFirst() {
            switch component {
            case ".", "": continue
            case "..": _ = components.popLast()
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// Writes a record for every conversation the app already knew before records existed:
    /// each Launch Record that names one, and each id reported by the tiles of the current
    /// and previous runs. Every attempt adds what it gathers to the pending set, unless the
    /// set is already empty, and writes the whole set; then it removes what it wrote or had
    /// rejected, and nothing else. Both steps are single transactions, so attempts from any
    /// number of stores on one database interleave safely: an observation leaves the set only
    /// once some attempt has written it, and the set empties only when all have been. An
    /// empty set is never refilled: a rerun would bring back a record a later cleanup removed
    /// on purpose.
    ///
    /// Each sighting carries the time it was made, so against a record a hook has written
    /// since, it only fills what that record lacks.
    @discardableResult
    public func migrateOnce() async throws -> MigrationOutcome {
        let key = migrationMetadataKey
        if let stored = try await localState.metadataValue(forKey: key), try Self.decode(stored).isEmpty {
            return .init(alreadyDone: true)
        }
        let gathered = try await gatheredObservations()
        let staged = try await localState.updateMetadataValue(forKey: key) { current in
            var pending = try current.map(Self.decode) ?? [:]
            if current != nil, pending.isEmpty { return nil }
            for observation in gathered where !(pending[observation.conversationID] ?? []).contains(observation) {
                pending[observation.conversationID, default: []].append(observation)
            }
            return try Self.encode(pending)
        }
        let pending = try staged.map(Self.decode) ?? [:]
        guard !pending.isEmpty else { return .init() }
        try await afterStaging?()

        var outcome = MigrationOutcome()
        var settled: [PendingMigrationObservation] = []
        for item in pending.keys.sorted().flatMap({ pending[$0] ?? [] }) {
            do {
                switch try records.record(item.observation, lockBudget: .seconds(1)) {
                case .written:
                    outcome.written += 1
                    settled.append(item)
                case .lockBusy:
                    outcome.failed += 1
                }
            } catch ConversationRecordStore.WriteError.invalidConversationID {
                outcome.rejected += 1
                settled.append(item)
            } catch {
                outcome.failed += 1
            }
        }
        _ = try await localState.updateMetadataValue(forKey: key) { [settled] current in
            var remaining = try current.map(Self.decode) ?? [:]
            for item in settled {
                remaining[item.conversationID]?.removeAll { $0 == item }
                if remaining[item.conversationID]?.isEmpty == true { remaining[item.conversationID] = nil }
            }
            return try Self.encode(remaining)
        }
        return outcome
    }

    /// The launch records' and recent runs' observations as they are now.
    private func gatheredObservations() async throws -> [PendingMigrationObservation] {
        var gathered = launchRecordObservations()
        gathered += try await localState.fetchConversationSightings(runIDs: localState.recentRunIDs()).map {
            sighting in
            ConversationObservation(
                conversationID: sighting.conversationID,
                cwd: sighting.cwd,
                observedAt: sighting.observedAt,
                observedBy: .migration,
                lastSeenIn: .init(hostSessionID: sighting.hostSessionID.uuidString)
            )
        }
        return gathered.map(PendingMigrationObservation.init)
    }

    private static func decode(_ stored: String) throws -> [String: [PendingMigrationObservation]] {
        try JSONDecoder().decode([String: [PendingMigrationObservation]].self, from: Data(stored.utf8))
    }

    private static func encode(_ pending: [String: [PendingMigrationObservation]]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(pending), as: UTF8.self)
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

/// One observation the migration owes a destination, in the fields migration observations
/// carry, so it can be stored between launches and written as it was gathered.
struct PendingMigrationObservation: Codable, Equatable, Sendable {
    var conversationID: String
    var host: String
    var cwd: String?
    var workspacePath: String?
    var socketLabel: String?
    var observedAt: Date
    var hostSessionID: String?
    var launch: Launch?

    struct Launch: Codable, Equatable, Sendable {
        var handle: String
        var model: String?
        var effort: String?
    }

    init(_ observation: ConversationObservation) {
        conversationID = observation.conversationID
        host = observation.host
        cwd = observation.cwd
        workspacePath = observation.workspacePath
        socketLabel = observation.socketLabel
        observedAt = observation.observedAt
        hostSessionID = observation.lastSeenIn?.hostSessionID
        launch = observation.launch.map { Launch(handle: $0.handle, model: $0.model, effort: $0.effort) }
    }

    var observation: ConversationObservation {
        ConversationObservation(
            conversationID: conversationID,
            host: host,
            cwd: cwd,
            workspacePath: workspacePath,
            socketLabel: socketLabel,
            observedAt: observedAt,
            observedBy: .migration,
            launch: launch.map { .init(handle: $0.handle, model: $0.model, effort: $0.effort) },
            lastSeenIn: hostSessionID.map { .init(hostSessionID: $0) }
        )
    }
}
