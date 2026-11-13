//
//  ConversationResumer.swift
//  WorkspaceManagerCore
//
//  The guarded resume verb: continues a recorded conversation so that exactly one agent ever
//  holds it. Two tiles, two app builds, or a double Return all go through one per-conversation
//  lock, and under it the holder probe decides. `--here` replaces the calling process with
//  the harness, and the lock's descriptor closes in that same exec, so the conversation goes
//  from free to held with no moment in which a second resume could find it free.
//

import Foundation

/// A harness invocation that replaces the calling process.
public struct HarnessInvocation: Equatable, Sendable {
    public let arguments: [String]
    public let environment: [String: String]
    public let directory: String

    public init(arguments: [String], environment: [String: String], directory: String) {
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }
}

/// `workspaces conversation resume --json`. A `--here` resume that succeeds prints nothing,
/// because the process that would print has become the harness.
public struct ConversationResumeResult: Codable, Sendable, Equatable {
    public let conversationID: String
    /// The `--into` handle; nil for `--here`.
    public let handle: String?
    public let resumed: Bool
    public let command: String?
    /// What holds the conversation when `resumed` is false.
    public let holders: [ConversationHolder]

    public init(
        conversationID: String,
        handle: String?,
        resumed: Bool,
        command: String? = nil,
        holders: [ConversationHolder] = []
    ) {
        self.conversationID = conversationID
        self.handle = handle
        self.resumed = resumed
        self.command = command
        self.holders = holders
    }
}

public enum HarnessExec {
    public enum Failure: Error, LocalizedError {
        case notOnPath(String)
        case directory(String, Int32)
        case exec(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .notOnPath(let name): return "'\(name)' is not on PATH."
            case .directory(let path, let code): return "Could not enter \(path): \(String(cString: strerror(code)))."
            case .exec(let path, let code): return "Could not start \(path): \(String(cString: strerror(code)))."
            }
        }
    }

    /// Becomes the harness. Returns only by throwing, when the process could not be replaced.
    public static func replaceProcess(with invocation: HarnessInvocation) throws -> Never {
        guard let name = invocation.arguments.first, let path = resolve(name, in: invocation.environment["PATH"])
        else { throw Failure.notOnPath(invocation.arguments.first ?? "") }
        guard chdir(invocation.directory) == 0 else { throw Failure.directory(invocation.directory, errno) }
        fflush(stdout)
        fflush(stderr)
        var argv = invocation.arguments.map { strdup($0) } + [nil]
        var envp = invocation.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(path, &argv, &envp)
        throw Failure.exec(path, errno)
    }

    static func resolve(_ name: String, in path: String?) -> String? {
        guard !name.contains("/") else { return name }
        return (path ?? "").split(separator: ":").lazy
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public struct ConversationResumer: Sendable {
    public enum Target: Equatable, Sendable {
        /// Replace the calling process: the terminal it runs in becomes the conversation's.
        case here
        /// Start it under a detached session handle, or type it into the idle shell there.
        case into(handle: String)
    }

    public enum Outcome: Equatable, Sendable {
        case resumed(command: String)
        /// Something already holds the conversation, and nothing was started. `targetLive` is
        /// whether an `into` handle had a session, nil for `here`.
        case held(holders: [ConversationHolder], targetLive: Bool?)
    }

    public enum Refusal: Error, LocalizedError, Equatable {
        case invalidID(String)
        case noRecord(String)
        case otherHost(conversationID: String, host: String)
        case unsupportedHarness(String)
        case directoryGone(String)
        case earlierWorkspace(conversationID: String, path: String)
        case lockBusy(String)
        case lockFailed(conversationID: String, reason: String)
        case probeFailed(String)
        case transcriptGone(String)
        case malformedID(String)
        case paneBusy(handle: String, paneCommand: String?)
        case paneAttached(handle: String, command: String)
        case tmux(String)
        case startFailed(handle: String, conversationID: String)

        public var errorDescription: String? {
            switch self {
            case .invalidID(let id):
                return "'\(id)' is not a conversation id."
            case .noRecord(let id):
                return "No record names conversation \(id) on this machine, so there is nothing to resume."
            case .otherHost(let id, let host):
                let place = host.isEmpty ? "a machine it does not name" : host
                return "Conversation \(id) was recorded on \(place), and its transcript lives there. "
                    + "Resume it on \(place). To continue it on this machine instead, copy its transcript "
                    + "here and fork it: claude --resume \(id) --fork-session"
            case .unsupportedHarness(let harness):
                return "Conversations run by '\(harness)' cannot be resumed by this build."
            case .directoryGone(let path):
                return "The workspace directory is gone: \(path)"
            case .earlierWorkspace(let id, let path):
                return "\(path) was made after conversation \(id) was recorded there, so it may belong "
                    + "to an earlier workspace at that path."
            case .lockBusy(let id):
                return "Another launch or resume of conversation \(id) is still running."
            case .lockFailed(let id, let reason):
                return "Could not claim conversation \(id): \(reason)"
            case .probeFailed(let detail):
                return "\(detail), so a second agent cannot be ruled out."
            case .transcriptGone(let id):
                return "No transcript exists for conversation \(id): it never took a turn, "
                    + "so there is nothing to continue. 'workspaces ws launch' starts a new one."
            case .malformedID(let id):
                return "The recorded conversation id is malformed: \(id)"
            case .paneBusy(let handle, let paneCommand):
                return "'\(handle)' is running \(paneCommand ?? "something tmux would not name"), "
                    + "not a shell, so the resume command cannot be typed into it."
            case .paneAttached(let handle, let command):
                return "'\(handle)' is open in a terminal, and its prompt may hold someone's work, so "
                    + "nothing was typed. To resume it there, press Return on the prefilled "
                    + "command, or run: \(command)"
            case .tmux(let message):
                return message
            case .startFailed(let handle, let id):
                return "The resume command ran under '\(handle)', but nothing took up conversation "
                    + "\(id). To see why: workspaces ws read \(handle)"
            }
        }
    }

    /// How long a holder found outside any live session gets to finish exiting: an agent
    /// outlives a killed tmux server by a few seconds while it shuts down, and a resume in
    /// that window would be refused for nothing.
    public static let holderExitWindow: TimeInterval = 15

    /// The record's tmux session as its server answers now; nil when the server could not be
    /// asked, which leaves the probe unable to rule a holder out.
    public typealias RecordedSessionLookup = @Sendable (ConversationRecord) async -> RecordedTmuxSession?
    public typealias Exec = @Sendable (HarnessInvocation) throws -> Void

    let records: ConversationRecordStore
    let launches: AgentLaunchRecordStore
    let control: TmuxSessionControl
    let adapter: any HarnessAdapter
    let environment: [String: String]
    let homeDirectory: URL
    let host: String
    let readProcessTable: @Sendable () async -> ProcessTable?
    let recordedSession: RecordedSessionLookup
    let describeTmux: @Sendable (TmuxEnvironment) -> ConversationRecord.TmuxSession?
    let exec: Exec
    let warn: @Sendable (String) -> Void

    public init(
        records: ConversationRecordStore,
        launches: AgentLaunchRecordStore,
        control: TmuxSessionControl,
        adapter: any HarnessAdapter = ClaudeHarnessAdapter(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL? = nil,
        host: String = ConversationHost.current,
        readProcessTable: @escaping @Sendable () async -> ProcessTable? = { await ProcessTable.read() },
        recordedSession: RecordedSessionLookup? = nil,
        describeTmux: @escaping @Sendable (TmuxEnvironment) -> ConversationRecord.TmuxSession? = {
            TmuxEnvironment.describe($0)
        },
        exec: @escaping Exec = { try HarnessExec.replaceProcess(with: $0) },
        warn: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.records = records
        self.launches = launches
        self.control = control
        self.adapter = adapter
        self.environment = environment
        self.homeDirectory =
            homeDirectory ?? environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.host = host
        self.readProcessTable = readProcessTable
        self.recordedSession =
            recordedSession ?? Self.tmuxRecordedSession(fallbackSocketLabel: control.socketLabel)
        self.describeTmux = describeTmux
        self.exec = exec
        self.warn = warn
    }

    // MARK: - Reading

    /// The conversation's record, or one made from a launch record on this socket that names
    /// it, for a launch from before records existed.
    public func subject(conversationID: String) -> ConversationRecord? {
        guard let id = ConversationRecord.normalizedID(conversationID) else { return nil }
        if let record = records.load(conversationID: id) { return record }
        return launches.all(socketLabel: control.socketLabel)
            .first { $0.identity.flatMap { ConversationRecord.normalizedID($0.conversationID) } == id }
            .map { ConversationRecord(launch: $0, host: host) }
    }

    /// Advisory: what the conversation looks like now, outside the lock. For display only;
    /// `resume` asks again under the lock and acts on that answer.
    public func conversationStatus(conversationID: String) async -> ConversationStatus {
        guard let record = subject(conversationID: conversationID) else { return .unknown(.noRecord) }
        return await status(of: record) { _ in 0 }
    }

    /// The record's host, then holders, then the transcript, in that order: a held
    /// conversation is open whatever its transcript looks like. Holders found while the
    /// window `exitWindow` gives is open are looked for again until they leave or it closes.
    func status(
        of record: ConversationRecord,
        exitWindow: (RecordedTmuxSession) -> TimeInterval
    ) async -> ConversationStatus {
        guard record.host == host else { return .unknown(.otherHost(record.host)) }
        var deadline: Date?
        while true {
            guard let recorded = await recordedSession(record) else {
                return .unknown(.probeFailed("The tmux server holding its last session did not answer"))
            }
            guard let table = await readProcessTable() else {
                return .unknown(.probeFailed("Could not read the process table"))
            }
            let holders = adapter.holders(of: record, processTable: table, recordedSession: recorded)
            if holders.isEmpty { break }
            let window = deadline ?? Date().addingTimeInterval(exitWindow(recorded))
            deadline = window
            if Date() >= window { return .open(holders: holders) }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard
            let transcript = adapter.transcript(for: record, environment: environment, homeDirectory: homeDirectory)
        else { return .unknown(.transcriptGone) }
        return .saved(transcript)
    }

    // MARK: - Resuming

    public func resume(conversationID: String, target: Target) async throws -> Outcome {
        guard let id = ConversationRecord.normalizedID(conversationID) else { throw Refusal.invalidID(conversationID) }
        guard let record = subject(conversationID: id) else { throw Refusal.noRecord(id) }
        return try await resume(record, target: target)
    }

    /// Resumes `subject` unless something holds it. Everything up to the start runs under the
    /// conversation's lock, and the record is read again once the lock is held, since the
    /// resume that held it last may have just moved the conversation.
    public func resume(_ subject: ConversationRecord, target: Target) async throws -> Outcome {
        let id = subject.conversationID
        guard subject.harness == adapter.harness else { throw Refusal.unsupportedHarness(subject.harness) }
        guard subject.host == host else { throw Refusal.otherHost(conversationID: id, host: subject.host) }
        try requireDirectories(of: subject)

        let lock = try await claim(id)
        defer { lock.release() }
        let record = records.load(conversationID: id) ?? subject

        var targetLive: Bool?
        if case .into(let handle) = target {
            targetLive = await control.isLive(handle: handle)
        }
        let window: (RecordedTmuxSession) -> TimeInterval = { recorded in
            if let targetLive { return targetLive ? 0 : Self.holderExitWindow }
            return recorded == .gone ? Self.holderExitWindow : 0
        }

        let transcript: HarnessTranscript
        switch await status(of: record, exitWindow: window) {
        case .open(let holders):
            return .held(holders: holders, targetLive: targetLive)
        case .unknown(.otherHost(let recordedHost)):
            throw Refusal.otherHost(conversationID: id, host: recordedHost)
        case .unknown(.probeFailed(let detail)):
            throw Refusal.probeFailed(detail)
        case .unknown(.transcriptGone):
            throw Refusal.transcriptGone(id)
        case .unknown(.noRecord):
            throw Refusal.noRecord(id)
        case .saved(let found):
            transcript = found
        }
        guard let arguments = adapter.resumeArguments(for: record, transcript: transcript),
            let command = adapter.resumeCommandLine(for: record, transcript: transcript)
        else { throw Refusal.malformedID(id) }

        switch target {
        case .here:
            recordSighting(of: record)
            try exec(
                HarnessInvocation(
                    arguments: arguments,
                    environment: adapter.harnessEnvironment(from: environment, transcript: transcript),
                    directory: record.cwd
                )
            )
        case .into(let handle):
            try await start(command, conversationID: id, record: record, handle: handle, live: targetLive == true)
        }
        return .resumed(command: command)
    }

    private func claim(_ conversationID: String) async throws -> AgentConversationLock {
        do {
            return try await launches.lockConversation(conversationID)
        } catch AgentLaunchRecordStore.LockError.held {
            throw Refusal.lockBusy(conversationID)
        } catch {
            throw Refusal.lockFailed(conversationID: conversationID, reason: error.localizedDescription)
        }
    }

    /// A workspace can be archived and another made at the same path, and a conversation
    /// recorded in the first is no part of the second.
    private func requireDirectories(of record: ConversationRecord) throws {
        guard FileManager.default.fileExists(atPath: record.cwd) else { throw Refusal.directoryGone(record.cwd) }
        guard let path = record.workspacePath, let recordedAt = record.workspaceCreatedAt else { return }
        guard let created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date else {
            throw Refusal.directoryGone(path)
        }
        guard created.timeIntervalSince(recordedAt) < 1 else {
            throw Refusal.earlierWorkspace(conversationID: record.conversationID, path: path)
        }
    }

    /// Says the conversation is now in this terminal, before the harness takes it over. The
    /// record is not what guards the conversation, the lock is, so a write that fails warns.
    private func recordSighting(of record: ConversationRecord) {
        let tmux = TmuxEnvironment(environment["TMUX"])
        let observation = ConversationObservation(
            harness: record.harness,
            conversationID: record.conversationID,
            host: host,
            cwd: record.cwd,
            workspacePath: record.workspacePath,
            workspaceCreatedAt: record.workspaceCreatedAt,
            socketLabel: tmux?.socketLabel,
            observedBy: .resume,
            launch: record.launch,
            lastSeenIn: .init(
                hostSessionID: environment["WORKSPACES_HOST_SESSION_ID"].flatMap { UUID(uuidString: $0)?.uuidString },
                tmux: tmux.flatMap(describeTmux),
                outsideTmux: tmux == nil
            )
        )
        do {
            if try records.record(observation, lockBudget: .seconds(2)) == .lockBusy {
                warn("warning: the conversation record was busy, so it does not say where this resume ran yet.")
            }
        } catch {
            warn("warning: the conversation record was not updated: \(error.localizedDescription).")
        }
    }

    /// Starts the command under `handle`: a new session when there is none, or typed into
    /// the idle shell there when nobody is looking at it. Returns once the harness holds the
    /// conversation, which is what makes it safe to let the lock go.
    private func start(
        _ command: String,
        conversationID: String,
        record: ConversationRecord,
        handle: String,
        live: Bool
    ) async throws {
        do {
            if live {
                let paneCommand = await control.paneCommand(handle: handle)
                guard let paneCommand, TmuxSessionControl.isIdleShell(paneCommand: paneCommand) else {
                    throw Refusal.paneBusy(handle: handle, paneCommand: paneCommand)
                }
                guard await control.attachedClients(handle: handle) == 0 else {
                    throw Refusal.paneAttached(handle: handle, command: command)
                }
                try await control.adoptSessionEnvironment(handle: handle)
                try await control.clearInputLine(handle: handle)
                let report = try await control.send(
                    handle: handle, text: control.prefixingSessionEnvironment(command), submit: true)
                if report.verification == .paneMissingText {
                    warn("warning: the pane did not show the resume command; 'ws check' will say if it ran.")
                }
            } else {
                try await control.launch(handle: handle, directory: URL(fileURLWithPath: record.cwd), command: command)
            }
        } catch let error as TmuxSessionControl.ControlError {
            throw Refusal.tmux(error.localizedDescription)
        }
        guard await waitForHolder(of: record) else {
            throw Refusal.startFailed(handle: handle, conversationID: conversationID)
        }
    }

    /// Until the new agent shows in the process table. `false` if none appeared, which is a
    /// start that failed.
    private func waitForHolder(of record: ConversationRecord) async -> Bool {
        for _ in 0..<100 {
            if let table = await readProcessTable(),
                !adapter.holders(of: record, processTable: table, recordedSession: .notRecorded).isEmpty
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    // MARK: - The recorded tmux session

    /// Asks the server the record names for the session's panes. A server that is gone, a
    /// server that restarted and reused the session id, and a session that ended all answer
    /// `gone`; a server that is alive and does not answer leaves the probe blind.
    public static func tmuxRecordedSession(
        fallbackSocketLabel: String,
        run: @escaping TmuxSessionControl.CommandRunner = TmuxSessionControl.defaultRunner,
        environment: [String: String] = TmuxSessionProbe.defaultEnvironment
    ) -> RecordedSessionLookup {
        { record in
            guard let tmux = record.lastSeenIn?.tmux else { return .notRecorded }
            if kill(pid_t(tmux.serverPID), 0) != 0, errno == ESRCH { return .gone }
            let label = record.socketLabel ?? fallbackSocketLabel
            guard TmuxSessionProbe.isSafeSocketLabel(label) else { return nil }
            let arguments = [
                "tmux", "-L", label, "list-panes", "-s", "-t", tmux.sessionID,
                "-F", "#{pid}\t#{session_created}\t#{pane_pid}\t#{session_name}",
            ]
            guard let result = await run("/usr/bin/env", arguments, environment) else { return nil }
            guard result.success else { return .gone }
            return recordedSession(tmux, listing: result.stdout)
        }
    }

    static func recordedSession(_ tmux: ConversationRecord.TmuxSession, listing: String) -> RecordedTmuxSession {
        var panes: Set<Int32> = []
        var name: String?
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 3).map(String.init)
            guard fields.count == 4, Int(fields[0]) == tmux.serverPID, let pane = Int32(fields[2]) else {
                return .gone
            }
            if let createdAt = tmux.createdAt, Int(fields[1]) != Int(createdAt.timeIntervalSince1970.rounded()) {
                return .gone
            }
            panes.insert(pane)
            name = fields[3]
        }
        return panes.isEmpty ? .gone : .live(sessionID: tmux.sessionID, name: name, panePIDs: panes)
    }
}

extension ConversationRecord {
    /// A record for a launch from before Conversation records, built from what its Launch
    /// Record says. The workspace's creation is bounded by the launch time, the same rule
    /// `AgentLaunchRecord.isForWorkspaceOnDisk` applies.
    public init(launch: AgentLaunchRecord, host: String) {
        self.init(
            schema: Self.schemaVersion,
            harness: Self.claudeHarness,
            conversationID: launch.identity.flatMap { Self.normalizedID($0.conversationID) } ?? "",
            host: host,
            cwd: launch.workspacePath,
            configHome: nil,
            transcriptPath: nil,
            workspacePath: launch.workspacePath,
            workspaceCreatedAt: launch.launchedAt,
            socketLabel: launch.socketLabel,
            createdAt: launch.launchedAt,
            observedAt: launch.launchedAt,
            observedBy: .wsLaunch,
            launch: .init(
                handle: launch.handle,
                model: launch.identity?.requestedModel,
                effort: launch.identity?.requestedEffort
            ),
            lastSeenIn: nil,
            endedByUserAt: nil
        )
    }
}
