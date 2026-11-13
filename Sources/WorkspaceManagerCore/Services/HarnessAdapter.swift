//
//  HarnessAdapter.swift
//  WorkspaceManagerCore
//
//  What the guarded resume verb needs from one agent harness: the command that continues a
//  conversation, where its transcript lives, and which processes hold one now, as far as its
//  records and the process table can show. The vocabulary is Agent Client Protocol's (open,
//  saved, unknown); the transport is the harness's own CLI in a terminal. Claude is the only
//  conformer until Codex and Pi.
//

import Foundation

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

public protocol HarnessAdapter: Sendable {
    /// The `harness` value of this harness's Conversation records.
    var harness: String { get }

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

    /// Every process holding the conversation, or `unknown` when the probe could not look.
    func holders(of record: ConversationRecord, in context: HolderProbeContext) async -> HolderProbe

    /// What to tell someone whose record is from another machine: how to carry the
    /// conversation here instead of resuming it there.
    func forkAdvice(conversationID: String) -> String
}

public struct ClaudeHarnessAdapter: HarnessAdapter {
    public init() {}

    public var harness: String { ConversationRecord.claudeHarness }

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

    /// Claude's holders, by three rules, each of which can only add a holder, and each of
    /// which holds until the process exits. A process whose arguments name the conversation
    /// holds it. When the record names the process it was last run by, that process holds it
    /// while it lives: a pid with its start time is one process lifetime, and an exec keeps
    /// both, so whatever wrapper or runtime the harness execs through stays the recorded
    /// process whatever its arguments say. Neither lets go when the process starts another
    /// conversation, as `/clear` does: only a hook could say so, and a hook can be late,
    /// dropped, or fired by something beneath it. When no recorded process holds it, the tmux
    /// session it was last seen in is asked, and any claude there is counted, since it may be
    /// this conversation under an id its arguments do not carry. Holders are found first and
    /// placed once: in that session only when its server answers that they run there, and,
    /// outside tmux, the recorded process in the tile it was seen in.
    ///
    /// A conversation whose newest hook could not name its claude, and that nothing else
    /// holds, is unknown: that claude may still run, and nothing says when it exits.
    public func holders(of record: ConversationRecord, in context: HolderProbeContext) async -> HolderProbe {
        let found = await namedHolders(of: record, in: context)
        guard found == .free, record.lastSeenIn?.harnessUnnamed == true else { return found }
        return .unknown(
            "The hook that last saw conversation \(record.conversationID) start could not name the claude it ran "
                + "under, as happens when the hook command reaches \(ConversationHookObserver.forwarderName) through a "
                + "link, a script or a shim, so whether that claude still runs is unknown")
    }

    private func namedHolders(of record: ConversationRecord, in context: HolderProbeContext) async -> HolderProbe {
        let id = record.conversationID
        let table = context.processTable
        let seen = record.lastSeenIn
        var recorded: ProcessIdentity?
        if let harness = seen?.harness {
            switch context.inspector.liveness(harness) {
            case .running: recorded = harness
            case .ended: recorded = nil
            case .unreadable: return .unknown("Could not ask the kernel about process \(harness.pid)")
            }
        }
        var holders = table.rows
            .filter { AgentSessionInspection.isClaude($0.arguments) && AgentSessionInspection.names(id, $0.arguments) }
            .map {
                ConversationHolder(
                    pid: $0.pid, foundBy: .arguments, startedAt: context.inspector.identity($0.pid)?.startedAt)
            }
        let counted = Set(holders.map(\.pid))
        if let recorded, !counted.contains(recorded.pid) {
            holders.append(
                ConversationHolder(pid: recorded.pid, foundBy: .recordedHarness, startedAt: recorded.startedAt))
        }

        guard seen?.tmux != nil else {
            holders = holders.map { $0.pid == recorded?.pid ? $0.placed(hostSessionID: seen?.hostSessionID) : $0 }
            return holders.isEmpty ? .free : .held(holders, recordedSessionGone: false)
        }
        guard let session = await context.recordedSession(record) else {
            guard !holders.isEmpty else { return .unknown("The tmux server holding its last session did not answer") }
            return .held(holders, recordedSessionGone: false)
        }
        guard case .live(let sessionID, let name, let panePIDs) = session else {
            return holders.isEmpty ? .free : .held(holders, recordedSessionGone: true)
        }
        let inSession = Set(table.descendants(of: panePIDs).map(\.pid))
        if recorded == nil {
            for row in table.rows
            where inSession.contains(row.pid) && !counted.contains(row.pid)
                && AgentSessionInspection.isClaude(row.arguments)
            {
                holders.append(
                    ConversationHolder(
                        pid: row.pid, foundBy: .sessionPaneTree,
                        startedAt: context.inspector.identity(row.pid)?.startedAt))
            }
        }
        holders = holders.map {
            inSession.contains($0.pid)
                ? $0.placed(
                    tmuxSessionID: sessionID, tmuxSessionName: name, hostSessionID: seen?.hostSessionID) : $0
        }
        return holders.isEmpty ? .free : .held(holders, recordedSessionGone: false)
    }

    public func forkAdvice(conversationID: String) -> String {
        "copy its transcript here and fork it: claude --resume \(conversationID) --fork-session"
    }
}
