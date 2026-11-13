//
//  HarnessAdapter.swift
//  WorkspaceManagerCore
//
//  What the guarded resume verb needs from one agent harness: how its conversations get an
//  id, the command that continues one, where its transcript lives, and which processes hold
//  one now. The vocabulary is Agent Client Protocol's (open, saved, unknown); the transport
//  is the harness's own CLI in a terminal. Claude is the only conformer until Codex and Pi.
//

import Foundation

/// How a harness's conversations come to have records: from a hook the harness runs, from
/// watching its session files, or only from launches that name the id up front. A harness
/// whose conversations get records only at launch has no record for one started by hand.
public enum HarnessIdentitySource: String, Codable, Sendable {
    case hook
    case sessionFileWatch = "session-file-watch"
    case launchOnly = "launch-only"
}

/// A process holding a conversation, and where it sits when that is known: the tmux session
/// and the tile the conversation was last seen in, when the process runs inside it.
///
/// `namesConversation` is false for a harness found only because it runs in the session the
/// conversation was last seen in. It may have switched to another conversation since, and is
/// counted as holding this one anyway: a refusal that turns out wrong costs a wait, and a
/// second writer costs the transcript.
public struct ConversationHolder: Codable, Equatable, Sendable {
    public let pid: Int32
    public let namesConversation: Bool
    public let tmuxSessionID: String?
    public let tmuxSessionName: String?
    public let hostSessionID: String?

    public init(
        pid: Int32,
        namesConversation: Bool = true,
        tmuxSessionID: String? = nil,
        tmuxSessionName: String? = nil,
        hostSessionID: String? = nil
    ) {
        self.pid = pid
        self.namesConversation = namesConversation
        self.tmuxSessionID = tmuxSessionID
        self.tmuxSessionName = tmuxSessionName
        self.hostSessionID = hostSessionID
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
        guard !namesConversation else { return place }
        return "\(place) runs claude without naming this conversation. It may have switched to "
            + "another one; this one resumes once that process exits."
    }
}

/// Why a conversation's state could not be read as open or saved. Each asks something
/// different of the caller: there is nothing to resume, look again, it has expired, or it
/// belongs to another machine.
public enum ConversationUnknownReason: Equatable, Sendable {
    case noRecord
    case probeFailed(String)
    case transcriptGone
    case otherHost(String)
}

/// A transcript, and the config home the harness has to run with to find it. `configHome`
/// is nil for the harness's default, which is different from naming the default explicitly.
public struct HarnessTranscript: Equatable, Sendable {
    public let url: URL
    public let configHome: String?

    public init(url: URL, configHome: String?) {
        self.url = url
        self.configHome = configHome
    }
}

/// A conversation's state at one moment. It is advisory: by the time a caller acts, a holder
/// may have started or gone. The resume verb asks again under the conversation's lock and
/// acts only on that answer.
public enum ConversationStatus: Equatable, Sendable {
    case open(holders: [ConversationHolder])
    case saved(HarnessTranscript)
    case unknown(ConversationUnknownReason)
}

/// The tmux session a record says its conversation was last seen in, as the server answers
/// for it now. `gone` covers a dead server, a restarted one, and a session that ended.
public enum RecordedTmuxSession: Equatable, Sendable {
    case notRecorded
    case gone
    case live(sessionID: String, name: String?, panePIDs: Set<Int32>)
}

public protocol HarnessAdapter: Sendable {
    /// The `harness` value of this harness's Conversation records.
    var harness: String { get }
    var identitySource: HarnessIdentitySource { get }

    /// A launch command naming a new conversation's id up front, for a harness that takes
    /// one; nil for a harness that assigns its own.
    func launchCommand(conversationID: String) -> String?

    /// The argument vector that continues the conversation; nil for an id the harness
    /// could not have issued.
    func resumeArguments(for record: ConversationRecord, transcript: HarnessTranscript) -> [String]?

    /// The environment the harness runs with when the resume replaces the calling process:
    /// `base` without another agent's identity, pointed at the transcript's config home.
    func harnessEnvironment(from base: [String: String], transcript: HarnessTranscript) -> [String: String]

    /// The resume as one line typed into a shell, carrying what `harnessEnvironment` would
    /// have set.
    func resumeCommandLine(for record: ConversationRecord, transcript: HarnessTranscript) -> String?

    /// The conversation's transcript, if it still exists.
    func transcript(
        for record: ConversationRecord, environment: [String: String], homeDirectory: URL
    )
        -> HarnessTranscript?

    /// Every process holding the conversation: one whose arguments name it, and, when the
    /// session it was last seen in is live, this harness running anywhere in that session.
    func holders(
        of record: ConversationRecord,
        processTable: ProcessTable,
        recordedSession: RecordedTmuxSession
    ) -> [ConversationHolder]
}

extension HarnessAdapter {
    public func launchCommand(conversationID: String) -> String? { nil }
}

public struct ClaudeHarnessAdapter: HarnessAdapter {
    public init() {}

    public var harness: String { ConversationRecord.claudeHarness }
    public var identitySource: HarnessIdentitySource { .hook }

    public func launchCommand(conversationID: String) -> String? {
        ConversationRecord.normalizedID(conversationID).map { "claude --session-id \($0)" }
    }

    public static let configHomeKey = "CLAUDE_CONFIG_DIR"

    /// `claude --resume <id>` plus the effort its last turn ran at, falling back to the one
    /// the launch asked for; claude restores the model and permission mode on its own but
    /// not the effort. Every word comes through a shape check, so the vector is safe to type.
    public func resumeArguments(for record: ConversationRecord, transcript: HarnessTranscript) -> [String]? {
        resumeLine(for: record, transcript: transcript)?.split(separator: " ").map(String.init)
    }

    public func harnessEnvironment(from base: [String: String], transcript: HarnessTranscript) -> [String: String] {
        var environment = AgentSessionEnvironment.removingAgentIdentity(from: base)
        environment[Self.configHomeKey] = transcript.configHome
        return environment
    }

    public func resumeCommandLine(for record: ConversationRecord, transcript: HarnessTranscript) -> String? {
        guard let line = resumeLine(for: record, transcript: transcript) else { return nil }
        guard let configHome = transcript.configHome else { return line }
        return "\(Self.configHomeKey)=\(RaceGroupPlanner.shellQuoted(configHome)) \(line)"
    }

    private func resumeLine(for record: ConversationRecord, transcript: HarnessTranscript) -> String? {
        AgentLaunchCommand.claudeResume(
            conversationID: record.conversationID,
            effort: ClaudeTranscriptTurn.last(in: transcript.url)?.effort ?? record.launch?.effort
        )
    }

    /// The path the hook reported first, then the recorded config home, then the default
    /// home and the caller's own. The config home handed back is the one the transcript was
    /// found under, so the harness looks where the transcript is.
    public func transcript(
        for record: ConversationRecord,
        environment: [String: String],
        homeDirectory: URL
    ) -> HarnessTranscript? {
        let defaultHome = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        func found(_ url: URL, configHome: String?) -> HarnessTranscript {
            let home = configHome.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let isDefault = home.map { $0.standardizedFileURL.path == defaultHome.standardizedFileURL.path } ?? true
            return HarnessTranscript(url: url, configHome: isDefault ? nil : home?.path)
        }
        func search(_ environment: [String: String]) -> URL? {
            ClaudeTranscriptResumability(environment: environment, homeDirectory: homeDirectory)
                .existingTranscriptURL(agentSessionID: record.conversationID, launchDirectory: record.cwd)
        }

        if let path = record.transcriptPath, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            let home = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return found(url, configHome: record.configHome ?? home.path)
        }
        if let configHome = record.configHome, let url = search(["CLAUDE_CONFIG_DIR": configHome]) {
            return found(url, configHome: configHome)
        }
        // A launched session sheds the caller's config directory, so the default comes first;
        // the caller's own second, for a login shell that exports the same one back.
        for candidate in [AgentSessionEnvironment.removingCallerIdentity(from: environment), environment] {
            if let url = search(candidate) {
                return found(url, configHome: candidate["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 })
            }
        }
        return nil
    }

    public func holders(
        of record: ConversationRecord,
        processTable: ProcessTable,
        recordedSession: RecordedTmuxSession
    ) -> [ConversationHolder] {
        var inSession: Set<Int32> = []
        var sessionID: String?
        var sessionName: String?
        if case .live(let id, let name, let panePIDs) = recordedSession {
            inSession = Set(processTable.descendants(of: panePIDs).map(\.pid))
            sessionID = id
            sessionName = name
        }
        return processTable.rows.compactMap { row in
            guard AgentSessionInspection.isClaude(row.arguments) else { return nil }
            let sitsInSession = inSession.contains(row.pid)
            let names = AgentSessionInspection.names(record.conversationID, row.arguments)
            guard sitsInSession || names else { return nil }
            guard sitsInSession else { return ConversationHolder(pid: row.pid) }
            return ConversationHolder(
                pid: row.pid,
                namesConversation: names,
                tmuxSessionID: sessionID,
                tmuxSessionName: sessionName,
                hostSessionID: record.lastSeenIn?.hostSessionID
            )
        }
    }
}

/// Every process on the machine with its parent and arguments, read once so the argument
/// rule and the pane-tree rule judge the same instant.
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
