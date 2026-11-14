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
    /// `conversation resume --here`, just before it hands the terminal to the harness.
    public static let resume = ConversationObserver(rawValue: "resume")
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
    /// The socket path is where that server listens, which its label alone does not say: a
    /// label resolves under each client's own `TMUX_TMPDIR`. The server's start time tells
    /// it from a later process that reused its pid.
    public struct TmuxSession: Equatable, Sendable {
        public var serverPID: Int
        public var sessionID: String
        public var createdAt: Date?
        public var name: String?
        public var socketPath: String?
        public var serverStartedAtMicroseconds: Int64?

        public init(
            serverPID: Int,
            sessionID: String,
            createdAt: Date? = nil,
            name: String? = nil,
            socketPath: String? = nil,
            serverStartedAtMicroseconds: Int64? = nil
        ) {
            self.serverPID = serverPID
            self.sessionID = sessionID
            self.createdAt = createdAt
            self.name = name
            self.socketPath = socketPath
            self.serverStartedAtMicroseconds = serverStartedAtMicroseconds
        }
    }

    /// Where the conversation was last seen. Each part is optional because each writer knows
    /// only some of it: the app knows the tile but not its tmux session, `ws launch` knows the
    /// tmux session but no tile. `outsideTmux` is an observed fact, a hook that ran with no
    /// `$TMUX`, which a missing `tmux` alone does not say.
    public struct LastSeenIn: Equatable, Sendable {
        public var hostSessionID: String?
        public var tmux: TmuxSession?
        public var outsideTmux: Bool

        public init(hostSessionID: String?, tmux: TmuxSession? = nil, outsideTmux: Bool = false) {
            self.hostSessionID = hostSessionID
            self.tmux = tmux
            self.outsideTmux = tmux == nil && outsideTmux
        }
    }

    /// What a hook or a resume said about the process running the conversation: that one,
    /// or, from a hook, that it ran and could not name the claude it ran under.
    public enum HarnessAnswer: Equatable, Sendable {
        case named(ProcessIdentity)
        case unnamed
    }

    /// Every process a hook or a resume named as running the conversation, apart from where
    /// it was seen: a place a later sighting contradicts becomes history, while a process that
    /// ran the conversation holds it until it exits, whatever was seen since. Writers only add
    /// to it, and an entry leaves only once its process has exited.
    public struct HarnessProcesses: Equatable, Sendable {
        public struct Entry: Equatable, Sendable {
            public var process: ProcessIdentity
            public var observedAt: Date
            /// Where it was running the conversation when it was named.
            public var seenIn: LastSeenIn?

            public init(process: ProcessIdentity, observedAt: Date, seenIn: LastSeenIn? = nil) {
                self.process = process
                self.observedAt = observedAt
                self.seenIn = seenIn
            }
        }

        public var entries: [Entry]
        /// The newest answer that named a process, kept after that process's entry has left.
        public var namedAt: Date?
        /// The newest hook that ran and could not name its claude.
        public var unnamedAt: Date?

        public init(entries: [Entry] = [], namedAt: Date? = nil, unnamedAt: Date? = nil) {
            self.entries = entries
            self.namedAt = namedAt
            self.unnamedAt = unnamedAt
        }

        /// Whether the newest answer is a hook that could not name the claude it ran under.
        public var newestIsUnnamed: Bool {
            guard let unnamedAt else { return false }
            return namedAt.map { unnamedAt > $0 } ?? true
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
    public var harnessProcesses = HarnessProcesses()

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
    public var harnessProcess: ConversationRecord.HarnessAnswer?

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
        lastSeenIn: ConversationRecord.LastSeenIn? = nil,
        harnessProcess: ConversationRecord.HarnessAnswer? = nil
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
        self.harnessProcess = harnessProcess
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
        return (try? Date(string, strategy: fractional)) ?? (try? Date(string, strategy: whole))
    }

    static func string(_ date: Date) -> String {
        date.formatted(fractional)
    }

    /// Format styles are values, so the hook, the recorder, and the index's database closures
    /// can share these across threads; a shared `ISO8601DateFormatter` is not safe to.
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

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
            endedByUserAt: date(object["endedByUserAt"]),
            harnessProcesses: harnessProcesses(from: object[harnessProcessesKey] as? [String: Any] ?? [:])
        )
    }

    private static func launch(from object: [String: Any]) -> ConversationRecord.Launch? {
        guard let handle = object["handle"] as? String else { return nil }
        return .init(handle: handle, model: object["model"] as? String, effort: object["effort"] as? String)
    }

    static func lastSeenIn(from object: [String: Any]) -> ConversationRecord.LastSeenIn {
        let tmux = (object["tmux"] as? [String: Any]).flatMap { tmux -> ConversationRecord.TmuxSession? in
            guard let pid = tmux["serverPID"] as? Int, let id = tmux["sessionID"] as? String else { return nil }
            return .init(
                serverPID: pid, sessionID: id, createdAt: date(tmux["createdAt"]), name: tmux["name"] as? String,
                socketPath: tmux["socketPath"] as? String,
                serverStartedAtMicroseconds: (tmux["serverStartedAt"] as? NSNumber)?.int64Value
            )
        }
        return .init(
            hostSessionID: object["hostSessionID"] as? String,
            tmux: tmux,
            outsideTmux: object["outsideTmux"] as? Bool == true
        )
    }

    static func object(from seen: ConversationRecord.LastSeenIn) -> [String: Any] {
        var object: [String: Any] = [:]
        object["hostSessionID"] = seen.hostSessionID
        if let tmux = seen.tmux {
            var session: [String: Any] = ["serverPID": tmux.serverPID, "sessionID": tmux.sessionID]
            session["createdAt"] = tmux.createdAt.map(string)
            session["name"] = tmux.name
            session["socketPath"] = tmux.socketPath
            session["serverStartedAt"] = tmux.serverStartedAtMicroseconds
            object["tmux"] = session
        } else if seen.outsideTmux {
            object["outsideTmux"] = true
        }
        return object
    }

    static func harnessProcesses(from object: [String: Any]) -> ConversationRecord.HarnessProcesses {
        let entries = (object["entries"] as? [[String: Any]] ?? []).compactMap {
            entry -> ConversationRecord.HarnessProcesses.Entry? in
            guard let process = (entry["process"] as? String).flatMap(ProcessIdentity.init(recorded:)),
                let observedAt = date(entry["observedAt"])
            else { return nil }
            return .init(
                process: process, observedAt: observedAt,
                seenIn: (entry["seenIn"] as? [String: Any]).map(lastSeenIn(from:)))
        }
        return .init(entries: entries, namedAt: date(object["namedAt"]), unnamedAt: date(object["unnamedAt"]))
    }
}

// MARK: - Store

public struct ConversationRecordStore: Sendable {
    /// Names the directory the records live in. The app puts the directory it resolved into
    /// each tile's environment under this key, so a hook writes where the app reads even when
    /// the hook's own `XDG_CONFIG_HOME` differs from the app's (#1417).
    public static let directoryEnvironmentKey = "WORKSPACES_CONVERSATIONS_DIR"

    /// The directory and its lock directory are the owner's alone, whichever process makes
    /// them first: a record names the person's working directories and transcripts.
    public static let directoryPermissions = 0o700

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
        guard case .found(let record) = read(conversationID: conversationID) else { return nil }
        return record
    }

    /// What the store holds for a conversation: a record, none, or a file it cannot read as
    /// one. A caller deciding who holds the conversation refuses on `damaged`, since the
    /// record it cannot read may name a process that still runs it.
    public enum Read: Equatable, Sendable {
        case found(ConversationRecord)
        case absent
        case damaged(URL)
    }

    public func read(conversationID: String) -> Read {
        guard let url = fileURL(conversationID: conversationID) else { return .absent }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch {
            return .damaged(url)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let record = ConversationRecordJSON.record(from: object)
        else { return .damaged(url) }
        return .found(record)
    }

    /// Every readable record. An unreadable one is skipped: nothing can act on a record whose
    /// conversation it cannot name.
    public func all() -> [ConversationRecord] {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                ConversationRecord.normalizedID(url.deletingPathExtension().lastPathComponent) != nil
            else { return nil }
            return Self.readObject(at: url).flatMap(ConversationRecordJSON.record(from:))
        }
    }

    /// Read, merge, replace, under a per-record lock. The lock is tried without blocking until
    /// `lockBudget` runs out, then the write is dropped: a hook writer must never hold up the
    /// agent it observes. The replace is a rename, so a reader sees the old record or the new
    /// one and never half of either.
    ///
    /// A record that exists but cannot be read is left alone and the write throws. One that
    /// reads but is not a JSON object is moved aside to `<id>.json.corrupt-<epoch>-<random>`,
    /// where no reader looks and a person still can, and the write starts a fresh record.
    ///
    /// A writer that decides who holds the conversation passes `movingDamagedAside: false`:
    /// a record it cannot read may name a process that still runs it, so the write throws.
    ///
    /// A harness process leaves the record once `ended` says it has exited, so the record
    /// keeps only processes that might still hold the conversation. One the kernel cannot
    /// be asked about stays.
    @discardableResult
    public func record(
        _ observation: ConversationObservation,
        lockBudget: Duration = .milliseconds(100),
        movingDamagedAside: Bool = true,
        ended: (ProcessIdentity) -> Bool = { ProcessInspector.live.liveness($0) == .ended }
    ) throws -> WriteOutcome {
        guard let conversationID = ConversationRecord.normalizedID(observation.conversationID),
            let url = fileURL(conversationID: conversationID)
        else { throw WriteError.invalidConversationID }
        var observation = observation
        observation.conversationID = conversationID

        let locks = directory.appendingPathComponent(".locks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: locks, withIntermediateDirectories: true, attributes: [.posixPermissions: Self.directoryPermissions])
        let lockPath = locks.appendingPathComponent("\(conversationID).write").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard Self.lock(descriptor, within: lockBudget) else { return .lockBusy }

        let existing = try Self.existingObject(at: url, movingDamagedAside: movingDamagedAside)
        let merged = ConversationRecordJSON.merge(observation, into: existing, ended: ended)
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        let temporary = directory.appendingPathComponent(".\(conversationID).\(getpid()).\(UUID().uuidString).tmp")
        try Self.writePrivately(data, to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        return .written
    }

    public enum ClaimError: Error, Equatable {
        case invalidConversationID
        case held
    }

    /// What a claim is for. `start` decides who holds the conversation. `handOff` is held by
    /// a resume that started the conversation somewhere else and waits for it to be taken
    /// up there, which needs `start` free for the process doing the taking.
    public enum ClaimKind: String, Sendable {
        case start = "claim"
        case handOff = "hand-off"
    }

    /// Waits for the conversation to be free, then claims it. The lock sits beside the record,
    /// so every launch and resume that names the conversation contends on one file wherever
    /// its own config directory points: a tile's `XDG_CONFIG_HOME` can differ from the
    /// caller's, and the records directory is the one they are made to agree on (#1417).
    public func claim(
        _ conversationID: String,
        for kind: ClaimKind = .start,
        timeout: Duration = .seconds(30)
    ) async throws -> AgentConversationLock {
        guard let id = ConversationRecord.normalizedID(conversationID) else { throw ClaimError.invalidConversationID }
        let locks = directory.appendingPathComponent(".locks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: locks, withIntermediateDirectories: true, attributes: [.posixPermissions: Self.directoryPermissions])
        // Close-on-exec: a lock stays held for as long as anything that inherited the
        // descriptor runs, and a resume can start a tmux server. `resume --here` relies on
        // it the other way: the exec that starts the harness is what lets the lock go.
        let descriptor = open(
            locks.appendingPathComponent("\(id).\(kind.rawValue)").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ContinuousClock.now < deadline else {
                close(descriptor)
                throw ClaimError.held
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                close(descriptor)
                throw error
            }
        }
        return AgentConversationLock(descriptor: descriptor)
    }

    /// Records name workspaces, transcripts and config homes, so the file is 0600 from the
    /// moment it exists rather than after a chmod.
    private static func writePrivately(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
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
    private static func existingObject(at url: URL, movingDamagedAside: Bool) throws -> [String: Any]? {
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
        guard movingDamagedAside, moveAside(url) else { throw WriteError.unreadableRecord }
        return nil
    }

    /// Renames `url` to a name no earlier aside holds: the rename refuses an existing
    /// destination rather than replacing it, so every damaged copy is kept.
    private static func moveAside(_ url: URL) -> Bool {
        let stamp = Int(Date().timeIntervalSince1970)
        for _ in 0..<4 {
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let aside = "\(url.path).corrupt-\(stamp)-\(suffix)"
            if renamex_np(url.path, aside, UInt32(RENAME_EXCL)) == 0 { return true }
            guard errno == EEXIST else { return false }
        }
        return false
    }

    private static func readObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
