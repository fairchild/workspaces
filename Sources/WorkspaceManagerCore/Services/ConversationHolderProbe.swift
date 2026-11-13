//
//  ConversationHolderProbe.swift
//  WorkspaceManagerCore
//
//  The one place anything asks which processes hold a conversation: resume, `ws launch` of
//  a named conversation, `ws check`, and the app's prefill all come here. Its answer has a
//  case for "could not tell", which no caller can read as "free"; a guard that could not see
//  refuses rather than letting a second agent start on one transcript.
//

import Foundation

/// How a holder was found, which says how sure the probe is that it holds this conversation.
public enum HolderEvidence: String, Codable, Sendable {
    /// Its arguments name the conversation.
    case arguments
    /// The conversation's record names this process as the one that last ran it.
    case recordedHarness = "recorded-harness"
    /// It runs in the tmux session the conversation was last seen in, and no recorded process
    /// holds the conversation.
    case sessionPaneTree = "session-pane-tree"
}

/// A process holding a conversation, and where it sits when that is known: the tmux session
/// and the tile the conversation was last seen in.
public struct ConversationHolder: Codable, Equatable, Sendable {
    public let pid: Int32
    public let foundBy: HolderEvidence
    public let startedAt: Date?
    public let tmuxSessionID: String?
    public let tmuxSessionName: String?
    public let hostSessionID: String?

    public init(
        pid: Int32,
        foundBy: HolderEvidence,
        startedAt: Date? = nil,
        tmuxSessionID: String? = nil,
        tmuxSessionName: String? = nil,
        hostSessionID: String? = nil
    ) {
        self.pid = pid
        self.foundBy = foundBy
        self.startedAt = startedAt
        self.tmuxSessionID = tmuxSessionID
        self.tmuxSessionName = tmuxSessionName
        self.hostSessionID = hostSessionID
    }

    func placed(tmuxSessionID: String? = nil, tmuxSessionName: String? = nil, hostSessionID: String?) -> Self {
        Self(
            pid: pid, foundBy: foundBy, startedAt: startedAt, tmuxSessionID: tmuxSessionID,
            tmuxSessionName: tmuxSessionName, hostSessionID: hostSessionID)
    }

    public var placeDescription: String {
        var parts = ["pid \(pid)"]
        if let tmuxSessionName {
            parts.append("in tmux session '\(tmuxSessionName)'" + (tmuxSessionID.map { " (\($0))" } ?? ""))
        } else if let tmuxSessionID {
            parts.append("in tmux session \(tmuxSessionID)")
        }
        if let hostSessionID {
            parts.append("in tile \(hostSessionID)")
        }
        let place = parts.joined(separator: " ")
        switch foundBy {
        case .arguments: return place
        case .recordedHarness:
            return "\(place) ran this conversation last and may have moved to another one since; "
                + "exit it to resume this one here."
        case .sessionPaneTree:
            return "\(place) runs claude without naming this conversation. It may have switched to "
                + "another one; this one resumes once that process exits."
        }
    }
}

/// What the probe saw. `unknown` is its own answer: the probe could not look, so nothing
/// can be ruled out, and a caller that would start an agent refuses on it.
public enum HolderProbe: Equatable, Sendable {
    case free
    /// `recordedSessionGone` is whether the tmux session the conversation was last seen in is
    /// positively gone, which makes these holders likely to be on their way out.
    case held([ConversationHolder], recordedSessionGone: Bool)
    case unknown(String)
}

/// The tmux session a record says its conversation was last seen in, as its server answers
/// for it now. `gone` is only ever a positive answer: the recorded server is dead, a later
/// process has its pid, or that same server says the session is not there.
public enum RecordedTmuxSession: Equatable, Sendable {
    case gone
    case live(sessionID: String, name: String?, panePIDs: Set<Int32>)
}

/// Everything an adapter's probe can consult, read for one probe. An adapter that needs more
/// (a daemon to ask) adds it here.
public struct HolderProbeContext: Sendable {
    public let processTable: ProcessTable
    public let inspector: ProcessInspector
    /// The record's tmux session as its server answers now; nil when it could not be asked.
    public let recordedSession: @Sendable (ConversationRecord) async -> RecordedTmuxSession?

    public init(
        processTable: ProcessTable,
        inspector: ProcessInspector,
        recordedSession: @escaping @Sendable (ConversationRecord) async -> RecordedTmuxSession?
    ) {
        self.processTable = processTable
        self.inspector = inspector
        self.recordedSession = recordedSession
    }
}

public struct ConversationHolderProbe: Sendable {
    let adapter: any HarnessAdapter
    let records: ConversationRecordStore?
    let readProcessTable: @Sendable () async -> ProcessTable?
    let inspector: ProcessInspector
    let recordedSession: @Sendable (ConversationRecord) async -> RecordedTmuxSession?

    public init(
        adapter: any HarnessAdapter = ClaudeHarnessAdapter(),
        records: ConversationRecordStore?,
        readProcessTable: @escaping @Sendable () async -> ProcessTable? = { await ProcessTable.read() },
        inspector: ProcessInspector = .live,
        recordedSession: (@Sendable (ConversationRecord) async -> RecordedTmuxSession?)? = nil,
        fallbackSocketLabel: String = TmuxSessionProbe.socketLabel
    ) {
        self.adapter = adapter
        self.records = records
        self.readProcessTable = readProcessTable
        self.inspector = inspector
        self.recordedSession =
            recordedSession
            ?? Self.tmuxRecordedSession(fallbackSocketLabel: fallbackSocketLabel, inspector: inspector)
    }

    public func probe(_ record: ConversationRecord) async -> HolderProbe {
        guard let table = await readProcessTable() else { return .unknown("Could not read the process table") }
        let context = HolderProbeContext(processTable: table, inspector: inspector, recordedSession: recordedSession)
        return await adapter.holders(of: record, in: context)
    }

    /// The holders of a conversation named by id: its record's, or for an id with no record,
    /// those the harness finds from the id alone.
    public func probe(conversationID: String) async -> HolderProbe {
        let record =
            records?.load(conversationID: conversationID)
            ?? ConversationRecord(
                schema: ConversationRecord.schemaVersion, harness: adapter.harness, conversationID: conversationID,
                host: ConversationHost.current, cwd: "/", configHome: nil, transcriptPath: nil, workspacePath: nil,
                workspaceCreatedAt: nil, socketLabel: nil, createdAt: Date(), observedAt: Date(), observedBy: .wsLaunch,
                launch: nil, lastSeenIn: nil, endedByUserAt: nil)
        return await probe(record)
    }

    // MARK: - The recorded tmux session

    /// Whether the process at the recorded server pid is that server: alive, started when it
    /// was recorded as starting, or for an older record, started before the session was. Nil
    /// when the kernel could not be asked.
    static func serverIsRecorded(_ tmux: ConversationRecord.TmuxSession, inspector: ProcessInspector) -> Bool? {
        let server: ProcessIdentity
        switch inspector.read(Int32(tmux.serverPID)) {
        case .unreadable: return nil
        case .absent: return false
        case .found(let found): server = found
        }
        if let started = tmux.serverStartedAtMicroseconds { return server.startedAtMicroseconds == started }
        if let created = tmux.createdAt { return server.startedAt <= created.addingTimeInterval(1) }
        return true
    }

    /// Asks the recorded server, at the socket path it was seen on, for the session's panes.
    /// `-u` keeps the tab separators: without a UTF-8 locale tmux prints each as `_`. Any
    /// answer that is not definitive is nil, and the probe refuses on it.
    public static func tmuxRecordedSession(
        fallbackSocketLabel: String,
        run: @escaping TmuxSessionControl.CommandRunner = TmuxSessionControl.defaultRunner,
        environment: [String: String] = TmuxSessionProbe.defaultEnvironment,
        inspector: ProcessInspector = .live
    ) -> @Sendable (ConversationRecord) async -> RecordedTmuxSession? {
        { record in
            guard let tmux = record.lastSeenIn?.tmux else { return nil }
            guard let isRecorded = serverIsRecorded(tmux, inspector: inspector) else { return nil }
            guard isRecorded else { return .gone }
            let address: [String]
            if let path = tmux.socketPath {
                address = ["-S", path]
            } else {
                let label = record.socketLabel ?? fallbackSocketLabel
                guard TmuxSessionProbe.isSafeSocketLabel(label) else { return nil }
                address = ["-L", label]
            }
            let sessions =
                ["tmux", "-u"] + address + ["list-sessions", "-F", "#{pid}\t#{session_id}\t#{session_created}"]
            guard let listing = await run("/usr/bin/env", sessions, environment), listing.success,
                let answer = sessionAnswer(tmux, listing: listing.stdout)
            else { return nil }
            guard answer else { return .gone }
            let panes =
                ["tmux", "-u"] + address + [
                    "list-panes", "-s", "-t", tmux.sessionID, "-F", "#{session_id}\t#{pane_pid}\t#{session_name}",
                ]
            guard let result = await run("/usr/bin/env", panes, environment), result.success else { return nil }
            return paneAnswer(tmux, listing: result.stdout)
        }
    }

    /// From `list-sessions`: true when the recorded server has the session, false when it
    /// does not or has another session under that id, nil when this is not the recorded
    /// server or the listing does not parse.
    static func sessionAnswer(_ tmux: ConversationRecord.TmuxSession, listing: String) -> Bool? {
        var found = false
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, let pid = Int(fields[0]), let created = Int(fields[2]) else { return nil }
            guard pid == tmux.serverPID else { return nil }
            guard fields[1] == tmux.sessionID else { continue }
            if let createdAt = tmux.createdAt, created != Int(createdAt.timeIntervalSince1970.rounded()) {
                return false
            }
            found = true
        }
        return found
    }

    static func paneAnswer(_ tmux: ConversationRecord.TmuxSession, listing: String) -> RecordedTmuxSession? {
        var panes: Set<Int32> = []
        var name: String?
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, fields[0] == tmux.sessionID, let pane = Int32(fields[1]) else { return nil }
            panes.insert(pane)
            name = fields[2]
        }
        return panes.isEmpty ? nil : .live(sessionID: tmux.sessionID, name: name, panePIDs: panes)
    }
}

/// Every process on the machine with its parent and arguments, read once so every rule of a
/// probe judges the same instant.
public struct ProcessTable: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public let pid: Int32
        public let parentPID: Int32
        public let arguments: [String]

        public init(pid: Int32, parentPID: Int32, arguments: [String]) {
            self.pid = pid
            self.parentPID = parentPID
            self.arguments = arguments
        }
    }

    public let rows: [Row]

    public init(rows: [Row]) {
        self.rows = rows
    }

    /// Parses `ps -A -ww -o pid=,ppid=,command=` output. A line that does not parse is left
    /// out; a listing with no line that parses is no listing.
    public init?(listing: String) {
        let rows = listing.split(separator: "\n").compactMap { line -> Row? in
            let words = line.split(separator: " ").map(String.init)
            guard words.count >= 3, let pid = Int32(words[0]), let parent = Int32(words[1]) else { return nil }
            return Row(pid: pid, parentPID: parent, arguments: Array(words.dropFirst(2)))
        }
        guard !rows.isEmpty else { return nil }
        self.rows = rows
    }

    public func row(_ pid: Int32) -> Row? {
        rows.first { $0.pid == pid }
    }

    /// `roots` and every process under them.
    public func descendants(of roots: Set<Int32>) -> [Row] {
        let children = Dictionary(grouping: rows, by: \.parentPID)
        var found: [Row] = rows.filter { roots.contains($0.pid) }
        var frontier = Array(roots)
        var seen = roots
        while let pid = frontier.popLast() {
            for child in children[pid] ?? [] where seen.insert(child.pid).inserted {
                found.append(child)
                frontier.append(child.pid)
            }
        }
        return found
    }

    /// The table now, or nil when `ps` did not answer.
    public static func read() async -> ProcessTable? {
        let result = try? await ProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["-A", "-ww", "-o", "pid=", "-o", "ppid=", "-o", "command="],
            timeout: 5
        )
        guard let result, result.success else { return nil }
        return ProcessTable(listing: result.stdout)
    }
}
