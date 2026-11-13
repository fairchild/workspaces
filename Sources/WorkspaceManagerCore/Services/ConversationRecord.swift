//
//  ConversationRecord.swift
//  WorkspaceManagerCore
//
//  The Conversation record: one file per agent conversation, saying where it ran and where
//  it was last seen. Every path that learns a conversation's id writes it — `ws launch`, the
//  SessionStart hook, the running app, a one-time migration — and files rather than the app's
//  database keep the CLI and the hook writing while the app is down.
//

import Foundation

public struct ConversationObserver: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let wsLaunch = ConversationObserver(rawValue: "ws-launch")
    public static let hook = ConversationObserver(rawValue: "hook")
    public static let app = ConversationObserver(rawValue: "app")
    public static let migration = ConversationObserver(rawValue: "migration")
}

public struct ConversationRecord: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let claudeHarness = "claude"

    public struct Launch: Equatable, Sendable {
        public var handle: String
        public var model: String?
        public var effort: String?

        public init(handle: String, model: String?, effort: String?) {
            self.handle = handle
            self.model = model
            self.effort = effort
        }
    }

    /// A tmux session as the server that holds it names it. The id alone repeats once a
    /// server restarts, so the server's pid and the session's creation time travel with it.
    public struct TmuxSession: Equatable, Sendable {
        public var serverPID: Int
        public var sessionID: String
        public var createdAt: Date?
        public var name: String?

        public init(serverPID: Int, sessionID: String, createdAt: Date? = nil, name: String? = nil) {
            self.serverPID = serverPID
            self.sessionID = sessionID
            self.createdAt = createdAt
            self.name = name
        }
    }

    public struct LastSeenIn: Equatable, Sendable {
        public var hostSessionID: String?
        public var tmux: TmuxSession?

        public init(hostSessionID: String?, tmux: TmuxSession? = nil) {
            self.hostSessionID = hostSessionID
            self.tmux = tmux
        }
    }

    public var schema: Int
    public var harness: String
    public var conversationID: String
    public var host: String
    public var cwd: String
    public var configHome: String?
    public var transcriptPath: String?
    public var workspacePath: String?
    public var workspaceCreatedAt: Date?
    public var socketLabel: String?
    public var createdAt: Date
    public var observedAt: Date
    public var observedBy: ConversationObserver
    public var launch: Launch?
    public var lastSeenIn: LastSeenIn?
    public var endedByUserAt: Date?

    /// Claude names conversations with lowercase UUIDs. One spelling per conversation keeps
    /// one file per conversation.
    public static func normalizedID(_ raw: String) -> String? {
        guard let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString.lowercased()
    }
}

/// What one writer learned about a conversation at one moment. A writer states only what it
/// knows; the record keeps everything else, including keys a newer build wrote.
public struct ConversationObservation: Sendable {
    public var harness: String
    public var conversationID: String
    public var host: String
    public var cwd: String?
    public var configHome: String?
    public var transcriptPath: String?
    public var workspacePath: String?
    public var workspaceCreatedAt: Date?
    public var socketLabel: String?
    public var observedAt: Date
    public var observedBy: ConversationObserver
    public var launch: ConversationRecord.Launch?
    public var lastSeenIn: ConversationRecord.LastSeenIn?

    public init(
        harness: String = ConversationRecord.claudeHarness,
        conversationID: String,
        host: String = ConversationHost.current,
        cwd: String? = nil,
        configHome: String? = nil,
        transcriptPath: String? = nil,
        workspacePath: String? = nil,
        workspaceCreatedAt: Date? = nil,
        socketLabel: String? = nil,
        observedAt: Date = Date(),
        observedBy: ConversationObserver,
        launch: ConversationRecord.Launch? = nil,
        lastSeenIn: ConversationRecord.LastSeenIn? = nil
    ) {
        self.harness = harness
        self.conversationID = conversationID
        self.host = host
        self.cwd = cwd
        self.configHome = configHome
        self.transcriptPath = transcriptPath
        self.workspacePath = workspacePath
        self.workspaceCreatedAt = workspaceCreatedAt
        self.socketLabel = socketLabel
        self.observedAt = observedAt
        self.observedBy = observedBy
        self.launch = launch
        self.lastSeenIn = lastSeenIn
    }
}

public enum ConversationHost {
    /// `gethostname` rather than `ProcessInfo.hostName`, which can wait on DNS, and the hook
    /// that reads this runs at the start of every Claude session.
    public static let current: String = {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "unknown" }
        return String(cString: buffer)
    }()
}

// MARK: - JSON shape

/// The record's JSON keys and the merge that applies an observation to a file's object.
/// Works on the decoded object rather than a Codable struct, because a Codable round trip
/// would drop every key this build does not know.
enum ConversationRecordJSON {
    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return fractional.date(from: string) ?? whole.date(from: string)
    }

    static func string(_ date: Date) -> String {
        fractional.string(from: date)
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func record(from object: [String: Any]) -> ConversationRecord? {
        guard let rawID = object["conversationID"] as? String,
            let conversationID = ConversationRecord.normalizedID(rawID),
            let harness = object["harness"] as? String,
            let cwd = object["cwd"] as? String,
            let observedAt = date(object["observedAt"])
        else { return nil }
        return ConversationRecord(
            schema: object["schema"] as? Int ?? ConversationRecord.schemaVersion,
            harness: harness,
            conversationID: conversationID,
            host: object["host"] as? String ?? "",
            cwd: cwd,
            configHome: object["configHome"] as? String,
            transcriptPath: object["transcriptPath"] as? String,
            workspacePath: object["workspacePath"] as? String,
            workspaceCreatedAt: date(object["workspaceCreatedAt"]),
            socketLabel: object["socketLabel"] as? String,
            createdAt: date(object["createdAt"]) ?? observedAt,
            observedAt: observedAt,
            observedBy: ConversationObserver(rawValue: object["observedBy"] as? String ?? ""),
            launch: (object["launch"] as? [String: Any]).flatMap(launch(from:)),
            lastSeenIn: (object["lastSeenIn"] as? [String: Any]).map(lastSeenIn(from:)),
            endedByUserAt: date(object["endedByUserAt"])
        )
    }

    private static func launch(from object: [String: Any]) -> ConversationRecord.Launch? {
        guard let handle = object["handle"] as? String else { return nil }
        return .init(handle: handle, model: object["model"] as? String, effort: object["effort"] as? String)
    }

    private static func lastSeenIn(from object: [String: Any]) -> ConversationRecord.LastSeenIn {
        let tmux = (object["tmux"] as? [String: Any]).flatMap { tmux -> ConversationRecord.TmuxSession? in
            guard let pid = tmux["serverPID"] as? Int, let id = tmux["sessionID"] as? String else { return nil }
            return .init(
                serverPID: pid, sessionID: id, createdAt: date(tmux["createdAt"]), name: tmux["name"] as? String)
        }
        return .init(hostSessionID: object["hostSessionID"] as? String, tmux: tmux)
    }

    /// Applies `observation` to the file's object. An observation at least as new as the
    /// record's sets every field it carries; an older one, such as the migration's, only
    /// fills fields the record lacks. `observedAt` therefore only moves forward, and the
    /// record describes its newest sighting.
    ///
    /// Keys this version does not know survive at the top level and under `launch`, which
    /// describe the conversation wherever it runs. `lastSeenIn` and its `tmux` describe one
    /// place, so their keys are location-specific:
    /// - `lastSeenIn` belongs to one holder, its `hostSessionID` (none, for a session no tile
    ///   holds). The same holder's observations, older or newer, merge into it field by
    ///   field. A newer observation from another holder replaces it whole, dropping every key
    ///   under it, `tmux` included; an older one from another holder is ignored.
    /// - `tmux` belongs to one session, its `serverPID` and `sessionID`. Observations of that
    ///   session merge into it field by field. A newer observation of another session
    ///   replaces it whole; an older one is ignored.
    static func merge(_ observation: ConversationObservation, into existing: [String: Any]?) -> [String: Any] {
        var object = existing ?? [:]
        let recordedAt = date(object["observedAt"])
        let isNewer = recordedAt.map { observation.observedAt >= $0 } ?? true

        func apply(_ key: String, _ value: Any?, into target: inout [String: Any]) {
            guard let value else { return }
            if isNewer || target[key] == nil { target[key] = value }
        }

        object["schema"] = max(object["schema"] as? Int ?? 0, ConversationRecord.schemaVersion)
        object["conversationID"] = observation.conversationID
        apply("harness", observation.harness, into: &object)
        apply("host", observation.host, into: &object)
        apply("cwd", observation.cwd, into: &object)
        apply("configHome", observation.configHome, into: &object)
        apply("transcriptPath", observation.transcriptPath, into: &object)
        apply("workspacePath", observation.workspacePath, into: &object)
        apply("workspaceCreatedAt", observation.workspaceCreatedAt.map(string), into: &object)
        apply("socketLabel", observation.socketLabel, into: &object)
        apply("observedBy", observation.observedBy.rawValue, into: &object)

        let earliest = [date(object["createdAt"]), recordedAt, observation.observedAt].compactMap { $0 }.min()
        object["createdAt"] = earliest.map(string)
        object["observedAt"] = string(max(recordedAt ?? observation.observedAt, observation.observedAt))

        if let launch = observation.launch {
            var target = object["launch"] as? [String: Any] ?? [:]
            apply("handle", launch.handle, into: &target)
            apply("model", launch.model, into: &target)
            apply("effort", launch.effort, into: &target)
            object["launch"] = target
        }

        if let seen = observation.lastSeenIn {
            object["lastSeenIn"] = mergeLastSeenIn(
                seen, into: object["lastSeenIn"] as? [String: Any], isNewer: isNewer)
        }
        return object
    }
}

extension ConversationRecordJSON {
    fileprivate static func mergeLastSeenIn(
        _ seen: ConversationRecord.LastSeenIn,
        into current: [String: Any]?,
        isNewer: Bool
    ) -> [String: Any]? {
        guard let current, current["hostSessionID"] as? String == seen.hostSessionID else {
            return isNewer || current == nil ? fresh(seen) : current
        }
        var target = current
        if let tmux = seen.tmux {
            target["tmux"] = mergeTmux(tmux, into: current["tmux"] as? [String: Any], isNewer: isNewer)
        }
        return target
    }

    fileprivate static func mergeTmux(
        _ tmux: ConversationRecord.TmuxSession,
        into current: [String: Any]?,
        isNewer: Bool
    ) -> [String: Any] {
        guard let current,
            current["serverPID"] as? Int == tmux.serverPID,
            current["sessionID"] as? String == tmux.sessionID
        else { return isNewer || current == nil ? fresh(tmux) : current ?? [:] }
        var target = current
        if let createdAt = tmux.createdAt, isNewer || target["createdAt"] == nil {
            target["createdAt"] = string(createdAt)
        }
        if let name = tmux.name, isNewer || target["name"] == nil { target["name"] = name }
        return target
    }

    private static func fresh(_ seen: ConversationRecord.LastSeenIn) -> [String: Any] {
        var object: [String: Any] = [:]
        if let hostSessionID = seen.hostSessionID { object["hostSessionID"] = hostSessionID }
        if let tmux = seen.tmux { object["tmux"] = fresh(tmux) }
        return object
    }

    private static func fresh(_ tmux: ConversationRecord.TmuxSession) -> [String: Any] {
        var object: [String: Any] = ["serverPID": tmux.serverPID, "sessionID": tmux.sessionID]
        if let createdAt = tmux.createdAt { object["createdAt"] = string(createdAt) }
        if let name = tmux.name { object["name"] = name }
        return object
    }
}

// MARK: - Store

public struct ConversationRecordFile: Equatable, Sendable {
    public let record: ConversationRecord
    public let modifiedAt: Date
}

public struct ConversationRecordStore: Sendable {
    /// Names the directory the records live in. The app puts the directory it resolved into
    /// each tile's environment under this key, so a hook writes where the app reads even when
    /// the hook's own `XDG_CONFIG_HOME` differs from the app's (#1417).
    public static let directoryEnvironmentKey = "WORKSPACES_CONVERSATIONS_DIR"

    public let directory: URL

    public init(directory: URL = ConversationRecordStore.resolvedDirectory()) {
        self.directory = directory
    }

    public static func resolvedDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let explicit = environment[directoryEnvironmentKey], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        return CLIConfigDirectory.resolved(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("conversations", isDirectory: true)
    }

    public enum WriteOutcome: Equatable, Sendable {
        case written
        /// Another writer held the record for the whole budget, so this write was dropped.
        case lockBusy
    }

    public enum WriteError: Error, Equatable {
        /// The observation's id is not a UUID, so no record file can be named for it.
        case invalidConversationID
        /// The record exists but could not be read. Writing would replace what it holds with
        /// one observation's worth, so nothing is written.
        case unreadableRecord
    }

    public func fileURL(conversationID: String) -> URL? {
        ConversationRecord.normalizedID(conversationID).map { directory.appendingPathComponent("\($0).json") }
    }

    public func load(conversationID: String) -> ConversationRecord? {
        guard let url = fileURL(conversationID: conversationID) else { return nil }
        return Self.readObject(at: url).flatMap(ConversationRecordJSON.record(from:))
    }

    /// Every readable record. An unreadable one is skipped: nothing can act on a record whose
    /// conversation it cannot name.
    public func files() -> [ConversationRecordFile] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                ConversationRecord.normalizedID(url.deletingPathExtension().lastPathComponent) != nil,
                let object = Self.readObject(at: url),
                let record = ConversationRecordJSON.record(from: object)
            else { return nil }
            let modifiedAt =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? record.observedAt
            return ConversationRecordFile(record: record, modifiedAt: modifiedAt)
        }
    }

    /// Read, merge, replace, under a per-record lock. The lock is tried without blocking until
    /// `lockBudget` runs out, then the write is dropped: a hook writer must never hold up the
    /// agent it observes. The replace is a rename, so a reader sees the old record or the new
    /// one and never half of either.
    ///
    /// A record that exists but cannot be read is left alone and the write throws. One that
    /// reads but is not a JSON object is moved aside to `<id>.json.corrupt-<epoch>`, where no
    /// reader looks and a person still can, and the write starts a fresh record.
    @discardableResult
    public func record(
        _ observation: ConversationObservation,
        lockBudget: Duration = .milliseconds(100)
    ) throws -> WriteOutcome {
        guard let conversationID = ConversationRecord.normalizedID(observation.conversationID),
            let url = fileURL(conversationID: conversationID)
        else { throw WriteError.invalidConversationID }
        var observation = observation
        observation.conversationID = conversationID

        let locks = directory.appendingPathComponent(".locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let lockPath = locks.appendingPathComponent("\(conversationID).write").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard Self.lock(descriptor, within: lockBudget) else { return .lockBusy }

        let merged = ConversationRecordJSON.merge(observation, into: try Self.existingObject(at: url))
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        let temporary = directory.appendingPathComponent(".\(conversationID).\(getpid()).\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        return .written
    }

    private static func lock(_ descriptor: Int32, within budget: Duration) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: budget)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ContinuousClock.now < deadline else { return false }
            usleep(5_000)
        }
        return true
    }

    /// The record's object for a merge: nil when there is no record yet.
    private static func existingObject(at url: URL) throws -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw WriteError.unreadableRecord
        }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return object
        }
        let aside = "\(url.path).corrupt-\(Int(Date().timeIntervalSince1970))"
        guard rename(url.path, aside) == 0 else { throw WriteError.unreadableRecord }
        return nil
    }

    private static func readObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
