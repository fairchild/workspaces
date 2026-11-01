//
//  AgentSessionInspection.swift
//  WorkspaceManagerCore
//
//  Answers whether a launched session is what its caller asked for, from three things that
//  cannot be talked into agreeing: the process table for how many agents hold the
//  conversation, the bottom of the pane for a prompt nobody will answer, and the transcript
//  for what the model actually ran on. Reading is separated from deciding so every verdict
//  is reachable without a running agent.
//

import Foundation

public enum AgentSessionVerdict: String, Codable, Sendable, Equatable {
    /// One agent, no prompt in the way, and a turn it took itself ran as requested.
    case verified
    /// One agent with its input box up, which has not taken a turn yet, so its model and
    /// effort are unproven. Where a resumed session stays until something is sent to it.
    case ready
    /// Nothing is wrong yet, and the evidence for an answer has not arrived.
    case waiting
    /// A prompt is holding the session, and nothing will answer it unattended.
    case blocked
    /// The last turn ran on something other than what was requested.
    case mismatch
    /// More than one process holds this conversation.
    case duplicate
    /// The session is gone.
    case notRunning = "not-running"
    /// The session is live, but its command named no conversation to check against.
    case unverifiable
}

/// `workspaces ws check --json`. Every observation is optional because "could not look" and
/// "looked and found nothing" are different answers.
public struct WorkspaceCheckResult: Codable, Sendable, Equatable {
    public let handle: String
    public let socketLabel: String
    public let verdict: AgentSessionVerdict
    public let detail: String
    public let sessionLive: Bool
    public let conversationID: String?
    public let agentProcesses: Int?
    public let blocker: String?
    public let requestedModel: String?
    public let requestedEffort: String?
    public let observedModel: String?
    public let observedEffort: String?
    public var visibleInApp: Bool?

    public init(
        handle: String,
        socketLabel: String,
        verdict: AgentSessionVerdict,
        detail: String,
        sessionLive: Bool,
        conversationID: String?,
        agentProcesses: Int?,
        blocker: String?,
        requestedModel: String?,
        requestedEffort: String?,
        observedModel: String?,
        observedEffort: String?,
        visibleInApp: Bool? = nil
    ) {
        self.handle = handle
        self.socketLabel = socketLabel
        self.verdict = verdict
        self.detail = detail
        self.sessionLive = sessionLive
        self.conversationID = conversationID
        self.agentProcesses = agentProcesses
        self.blocker = blocker
        self.requestedModel = requestedModel
        self.requestedEffort = requestedEffort
        self.observedModel = observedModel
        self.observedEffort = observedEffort
        self.visibleInApp = visibleInApp
    }
}

/// `workspaces ws resume --json`. `resumed` is false when the conversation was already
/// running, which is the answer a caller retrying after a restart needs to get back.
public struct WorkspaceResumeResult: Codable, Sendable, Equatable {
    public let handle: String
    public let socketLabel: String
    public let conversationID: String
    public let resumed: Bool
    public let command: String?

    public init(handle: String, socketLabel: String, conversationID: String, resumed: Bool, command: String?) {
        self.handle = handle
        self.socketLabel = socketLabel
        self.conversationID = conversationID
        self.resumed = resumed
        self.command = command
    }
}

public enum AgentSessionInspection {
    /// Rows from the bottom of the pane a dialog or the input box can occupy.
    static let dialogRows = 8

    /// What a prompt says, and the name a caller gets for it. A prompt nobody answers holds
    /// a launch forever, and the trust prompt's default choice exits the agent.
    private static let blockers: [(name: String, marker: String)] = [
        ("trust-folder", "Yes, I trust this folder"),
        ("dialog", "Enter to confirm"),
    ]

    /// The prompt holding this pane, or `nil`. A dialog takes the input box's place, so a
    /// box on screen means none is up, whatever the conversation above it has quoted.
    public static func blocker(inPane text: String) -> String? {
        guard !inputReady(inPane: text) else { return nil }
        let bottom = bottomRows(of: text).joined(separator: "\n")
        return blockers.first { bottom.contains($0.marker) }?.name
    }

    private static func bottomRows(of text: String) -> [String] {
        Array(
            text.split(separator: "\n").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .suffix(dialogRows)
        )
    }

    /// Whether the agent's input box is on screen: a prompt row directly under a rule, which
    /// is what tells it from a dialog's selection cursor. Text typed before the box is drawn
    /// is thrown away when the agent takes over its terminal, so a session is not ready for
    /// anything until this holds, however far along its transcript is. A future redraw of
    /// the box fails toward `waiting`.
    public static func inputReady(inPane text: String) -> Bool {
        let rows = bottomRows(of: text).map { $0.trimmingCharacters(in: .whitespaces) }
        return zip(rows, rows.dropFirst()).contains { above, row in
            above.hasPrefix("──") && row.hasPrefix("❯")
        }
    }

    /// How long each process holding `conversationID` has been running, in seconds, from
    /// `ps -A -ww -o etime=,command=` output. The id has to follow the flag that names a
    /// conversation, and `claude` has to be the program, directly or through an interpreter:
    /// the shell that started it, a tmux client and a hook all carry the same text and hold
    /// nothing.
    public static func conversationHolders(_ conversationID: String, processListing: String) -> [Int] {
        processListing.split(separator: "\n").compactMap { line in
            guard line.contains(conversationID) else { return nil }
            let words = line.split(separator: " ").map(String.init)
            guard let elapsed = words.first.flatMap(elapsedSeconds) else { return nil }
            let command = Array(words.dropFirst())
            let program = command.prefix(2).contains { URL(fileURLWithPath: $0).lastPathComponent == "claude" }
            guard program else { return nil }
            let holds = zip(command, command.dropFirst()).contains { flag, value in
                value == conversationID && ["--session-id", "--resume", "-r"].contains(flag)
            }
            return holds ? elapsed : nil
        }
    }

    /// Parses `ps` elapsed time, `[[dd-]hh:]mm:ss`.
    static func elapsedSeconds(_ text: String) -> Int? {
        let dayParts = text.split(separator: "-")
        guard (1...2).contains(dayParts.count), let clock = dayParts.last else { return nil }
        let days = dayParts.count == 2 ? Int(dayParts[0]) : 0
        let fields = clock.split(separator: ":").map { Int($0) }
        guard let days, (2...3).contains(fields.count), !fields.contains(nil) else { return nil }
        let clockSeconds = fields.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return days * 86_400 + clockSeconds
    }

    public static func verdict(
        sessionLive: Bool,
        identity: AgentLaunchIdentity?,
        agentProcesses: Int?,
        blocker: String?,
        inputReady: Bool,
        lastTurn: ClaudeTranscriptTurn?,
        agentStartedAt: Date?
    ) -> (verdict: AgentSessionVerdict, detail: String) {
        guard sessionLive else {
            return (.notRunning, "No terminal session is running under this handle.")
        }
        if let blocker {
            return (.blocked, "A '\(blocker)' prompt is holding the session.")
        }
        guard let identity else {
            return (.unverifiable, "The launch command named no conversation to check against.")
        }
        guard let agentProcesses else {
            return (.waiting, "The process table could not be read.")
        }
        if agentProcesses > 1 {
            return (.duplicate, "\(agentProcesses) processes hold this conversation.")
        }
        guard agentProcesses == 1 else {
            return (.waiting, "No agent process holds this conversation yet.")
        }
        guard inputReady else {
            return (.waiting, "The agent is starting and its input box is not up yet.")
        }
        guard let lastTurn, isOwnTurn(lastTurn, agentStartedAt: agentStartedAt) else {
            return (.ready, "The agent is up and has not taken a turn yet, so its model and effort are unproven.")
        }
        if let requested = identity.requestedModel {
            guard let observed = lastTurn.model, ClaudeTranscriptTurn.model(observed, satisfies: requested) else {
                return (
                    .mismatch,
                    "Requested model \(requested), last turn ran on \(lastTurn.model ?? "an unrecorded model")."
                )
            }
        }
        if let requested = identity.requestedEffort, lastTurn.effort != requested {
            return (
                .mismatch,
                "Requested effort \(requested), last turn ran at \(lastTurn.effort ?? "an unrecorded effort")."
            )
        }
        return (.verified, "One agent is running as requested.")
    }

    /// Whether the running process took this turn. Transcripts outlive processes, so a
    /// resumed conversation's last turn usually belongs to the process before it, and says
    /// nothing about this one. `ps` rounds elapsed time down, which puts `agentStartedAt` up
    /// to a second late; a process cannot start, reach a model and hear back inside that, so
    /// the error only ever falls on the side of refusing a turn from before it existed.
    /// An unknown time on either side is not evidence.
    static func isOwnTurn(_ turn: ClaudeTranscriptTurn, agentStartedAt: Date?) -> Bool {
        guard let timestamp = turn.timestamp, let agentStartedAt else { return false }
        return timestamp >= agentStartedAt
    }

    /// `ps` listing every process's elapsed time and full argument list, or `nil` when it
    /// did not answer.
    public static func processListing() async -> String? {
        let result = try? await ProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["-A", "-ww", "-o", "etime=", "-o", "command="],
            timeout: 5
        )
        return result?.success == true ? result?.stdout : nil
    }
}
