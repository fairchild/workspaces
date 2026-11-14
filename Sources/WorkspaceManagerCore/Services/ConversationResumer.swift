//
//  ConversationResumer.swift
//  WorkspaceManagerCore
//
//  The guarded resume verb: continues a recorded conversation so that exactly one agent ever
//  holds it. Two tiles, two app builds, or a double Return all go through one per-conversation
//  lock, and under it the holder probe decides. `--here` records its own process as the
//  conversation's, then replaces itself with the harness; the lock's descriptor closes in that
//  same exec, so the conversation goes from free to held with no moment in which a second
//  resume could find it free. `--into` starts that same `--here` under a handle, so ownership
//  is decided when the command runs there, however long after it was typed.
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

    /// Becomes the harness. `handOff` runs once the harness binary is found and the directory
    /// entered, so what it records is only ever followed by the exec itself, and its throw
    /// leaves the process as it was. Returns only by throwing, when the process could not be
    /// replaced or `handOff` refused.
    ///
    /// The exec is `posix_spawn` with `POSIX_SPAWN_SETEXEC`, which keeps this pid as `execve`
    /// does and also sets the new image's signal state. This code runs on a concurrency worker
    /// thread whose mask blocks most signals, and a mask survives an exec, as does a signal
    /// whatever started this process ignored. The harness starts with nothing blocked and
    /// every signal at its default, so a closed tile's HUP, a resize's WINCH and a TERM reach it.
    public static func replaceProcess(
        with invocation: HarnessInvocation, handOff: () async throws -> Void
    ) async throws -> Never {
        guard let name = invocation.arguments.first, let path = resolve(name, in: invocation.environment["PATH"])
        else { throw Failure.notOnPath(invocation.arguments.first ?? "") }
        guard chdir(invocation.directory) == 0 else { throw Failure.directory(invocation.directory, errno) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        var nothingBlocked = sigset_t()
        sigemptyset(&nothingBlocked)
        posix_spawnattr_setsigmask(&attributes, &nothingBlocked)
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        try await handOff()
        fflush(stdout)
        fflush(stderr)
        var argv = invocation.arguments.map { strdup($0) } + [nil]
        var envp = invocation.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let code = posix_spawn(nil, path, nil, &attributes, &argv, &envp)
        throw Failure.exec(path, code)
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
        case otherHost(conversationID: String, host: String, advice: String)
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
        case cannotStart(String)
        case unrecorded(conversationID: String, reason: String)
        case damagedRecord(conversationID: String, path: String)
        case movedAside(conversationID: String, path: String)
        case unresolvedOwner(conversationID: String, path: String)
        case unlistableRecords(conversationID: String, path: String)

        public var errorDescription: String? {
            switch self {
            case .invalidID(let id):
                return "'\(id)' is not a conversation id."
            case .noRecord(let id):
                return "No record names conversation \(id) on this machine, so there is nothing to resume."
            case .otherHost(let id, let host, let advice):
                let place = host.isEmpty ? "a machine it does not name" : host
                return "Conversation \(id) was recorded on \(place), and its transcript lives there. "
                    + "Resume it on \(place). To continue it on this machine instead, \(advice)"
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
                return HolderProbe.refusal(detail)
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
            case .cannotStart(let reason):
                return reason
            case .unrecorded(let id, let reason):
                return "Could not record that this terminal now holds conversation \(id): \(reason). "
                    + "Nothing was started, since another resume would not have seen it."
            case .damagedRecord(let id, let path):
                return "The record of conversation \(id) at \(path) cannot be read, and it may name a process "
                    + "that still runs the conversation, so a second agent cannot be ruled out. Nothing was started "
                    + "and the file was left as it is. Once no agent runs this conversation, move the file aside "
                    + "and resume again."
            case .movedAside(let id, let path):
                return "A damaged record of conversation \(id) was moved aside to \(path), and it may name a process "
                    + "that still runs the conversation, so a second agent cannot be ruled out. Nothing was started. "
                    + "If no claude runs this conversation, delete that file to resume."
            case .unresolvedOwner(let id, let path):
                return "A hook saw conversation \(id) start and could not tell which process runs it, so it left "
                    + "\(path), and a second agent cannot be ruled out. Nothing was started. If no claude runs this "
                    + "conversation, delete that file to resume."
            case .unlistableRecords(let id, let path):
                return "The records directory \(path) cannot be listed, so neither a copy of conversation \(id)'s "
                    + "record moved aside as damaged nor a hook's note that it could not tell what runs it can be "
                    + "ruled out. Nothing was started. Give your user read permission on that directory and resume "
                    + "again."
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
    /// Replaces the process with the invocation, running `handOff` once nothing but the exec
    /// itself is left to fail; a throw from `handOff` stops the exec.
    public typealias Exec = @Sendable (HarnessInvocation, _ handOff: () async throws -> Void) async throws -> Void

    let records: ConversationRecordStore
    let launches: AgentLaunchRecordStore
    let control: TmuxSessionControl
    let adapter: any HarnessAdapter
    let environment: [String: String]
    let homeDirectory: URL
    let host: String
    let probe: ConversationHolderProbe
    let inspector: ProcessInspector
    let describeTmux: @Sendable (TmuxEnvironment) -> ConversationRecord.TmuxSession?
    let exec: Exec
    let warn: @Sendable (String) -> Void
    let cliPath: String

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
        inspector: ProcessInspector = .live,
        describeTmux: @escaping @Sendable (TmuxEnvironment) -> ConversationRecord.TmuxSession? = {
            TmuxEnvironment.describe($0)
        },
        exec: @escaping Exec = { try await HarnessExec.replaceProcess(with: $0, handOff: $1) },
        warn: @escaping @Sendable (String) -> Void = { _ in },
        cliPath: String? = nil
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
        self.probe = ConversationHolderProbe(
            adapter: adapter,
            records: records,
            readProcessTable: readProcessTable,
            inspector: inspector,
            recordedSession: recordedSession,
            fallbackSocketLabel: control.socketLabel
        )
        self.inspector = inspector
        self.describeTmux = describeTmux
        self.exec = exec
        self.warn = warn
        self.cliPath = cliPath ?? Bundle.main.executablePath ?? "workspaces"
    }

    // MARK: - Reading

    /// The conversation's record, or one made from a launch record on this socket that names
    /// it, for a launch from before records existed. A record the store cannot read refuses:
    /// it may name a process that still runs the conversation, which a launch record would not.
    public func subject(conversationID: String) throws -> ConversationRecord? {
        guard let id = ConversationRecord.normalizedID(conversationID) else { return nil }
        switch records.read(conversationID: id) {
        case .found(let record): return record
        case .damaged(let url): throw Refusal.damagedRecord(conversationID: id, path: url.path)
        case .movedAside(let url): throw Refusal.movedAside(conversationID: id, path: url.path)
        case .unresolved(let url): throw Refusal.unresolvedOwner(conversationID: id, path: url.path)
        case .unlistable(let url): throw Refusal.unlistableRecords(conversationID: id, path: url.path)
        case .absent: break
        }
        return launches.all(socketLabel: control.socketLabel)
            .first { $0.identity.flatMap { ConversationRecord.normalizedID($0.conversationID) } == id }
            .map { ConversationRecord(launch: $0, host: host, harness: adapter.harness) }
    }

    /// The record's host, then holders, then the transcript, in that order: a held
    /// conversation is open whatever its transcript looks like. Holders found while the
    /// window `exitWindow` gives is open are looked for again until they leave or it closes;
    /// it is passed whether the tmux server the conversation was last seen under is gone.
    func status(
        of record: ConversationRecord,
        exitWindow: (_ recordedSessionGone: Bool) -> TimeInterval
    ) async -> ConversationStatus {
        guard record.host == host else { return .unknown(.otherHost(record.host)) }
        var deadline: Date?
        probing: while true {
            switch await probe.probe(record) {
            case .unknown(let detail):
                return .unknown(.probeFailed(detail))
            case .free:
                break probing
            case .held(let holders, let recordedSessionGone):
                let window = deadline ?? Date().addingTimeInterval(exitWindow(recordedSessionGone))
                deadline = window
                if Date() >= window { return .open(holders: holders) }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        guard
            let transcript = adapter.transcript(for: record, environment: environment, homeDirectory: homeDirectory)
        else { return .unknown(.transcriptGone) }
        return .saved(transcript)
    }

    // MARK: - Resuming

    public func resume(conversationID: String, target: Target) async throws -> Outcome {
        guard let id = ConversationRecord.normalizedID(conversationID) else { throw Refusal.invalidID(conversationID) }
        guard let record = try subject(conversationID: id) else { throw Refusal.noRecord(id) }
        return try await resume(record, target: target)
    }

    /// Resumes `subject` unless something holds it. The decision runs under the conversation's
    /// lock, and the record is read again once the lock is held, since the resume that held
    /// it last may have just moved the conversation; what the caller filled in on `subject`
    /// is kept, and what was checked on it is checked again on what was read.
    public func resume(_ subject: ConversationRecord, target: Target) async throws -> Outcome {
        let id = subject.conversationID
        try require(subject)

        // An `--into` resume holds a hand-off claim until the conversation is taken up where
        // it sent it, so a second `--into` waits and then finds it held rather than free.
        var handOff: AgentConversationLock?
        if case .into = target { handOff = try await claim(id, for: .handOff) }
        defer { handOff?.release() }
        let lock = try await claim(id)
        defer { lock.release() }
        var targetLive: Bool?
        if case .into(let handle) = target {
            targetLive = await control.isLive(handle: handle)
        }

        let record: ConversationRecord
        let transcript: HarnessTranscript
        switch try await decide(subject, exitWindow: { $0 ? Self.holderExitWindow : 0 }) {
        case .held(let holders):
            return .held(holders: holders, targetLive: targetLive)
        case .free(let stored, let found):
            record = stored
            transcript = found
        }
        guard let arguments = adapter.resumeArguments(for: record, transcript: transcript),
            let command = adapter.resumeCommandLine(for: record, transcript: transcript)
        else { throw Refusal.malformedID(id) }

        switch target {
        case .here:
            let invocation = HarnessInvocation(
                arguments: arguments,
                environment: adapter.harnessEnvironment(from: environment, transcript: transcript),
                directory: record.cwd
            )
            do {
                try await exec(invocation) {
                    let own = try recordSighting(of: record)
                    if case .held(let holders) = try await decide(record, excluding: own, exitWindow: { _ in 0 }) {
                        throw HeldMeanwhile(holders: holders)
                    }
                }
            } catch let failure as HarnessExec.Failure {
                throw Refusal.cannotStart(failure.localizedDescription)
            } catch let meanwhile as HeldMeanwhile {
                return .held(holders: meanwhile.holders, targetLive: targetLive)
            }
        case .into(let handle):
            // The `--here` started there takes this same lock, so it is released first.
            keepFilledIn(record)
            lock.release()
            if let holders = try await start(
                record: record, handle: handle, live: targetLive == true)
            {
                return .held(holders: holders, targetLive: targetLive)
            }
        }
        return .resumed(command: command)
    }

    private enum Decision {
        case held([ConversationHolder])
        case free(ConversationRecord, HarnessTranscript)
    }

    /// Something took the conversation between the decision and this resume's sighting.
    private struct HeldMeanwhile: Error {
        let holders: [ConversationHolder]
    }

    /// Whether the conversation is free, from its record as every reader reads it, a copy
    /// moved aside as damaged and a hook's unresolved note included, and then the probe;
    /// what the caller filled in on `subject` is kept, and what was checked on it is checked
    /// again on what was read. The decision before the sighting and the one after it are this
    /// same function: the one after passes `own`, the process that sighting named, which must
    /// be in the record and holds nothing against itself.
    private func decide(
        _ subject: ConversationRecord,
        excluding own: ProcessIdentity? = nil,
        exitWindow: (_ recordedSessionGone: Bool) -> TimeInterval
    ) async throws -> Decision {
        let id = subject.conversationID
        var record: ConversationRecord
        switch records.read(conversationID: id) {
        case .found(let stored): record = stored
        case .absent: record = subject
        case .damaged(let url): throw Refusal.damagedRecord(conversationID: id, path: url.path)
        case .movedAside(let url): throw Refusal.movedAside(conversationID: id, path: url.path)
        case .unresolved(let url): throw Refusal.unresolvedOwner(conversationID: id, path: url.path)
        case .unlistable(let url): throw Refusal.unlistableRecords(conversationID: id, path: url.path)
        }
        record.launch = record.launch ?? subject.launch
        if let own {
            guard record.harnessProcesses.entries.contains(where: { $0.process == own }) else {
                throw Refusal.unrecorded(
                    conversationID: id, reason: "its record, read back, does not name this process")
            }
            record.harnessProcesses.entries.removeAll { $0.process == own }
        }
        try require(record)
        switch await status(of: record, exitWindow: exitWindow) {
        case .open(let holders):
            return .held(holders)
        case .unknown(.otherHost(let recordedHost)):
            throw Refusal.otherHost(
                conversationID: id, host: recordedHost, advice: adapter.forkAdvice(conversationID: id))
        case .unknown(.probeFailed(let detail)):
            throw Refusal.probeFailed(detail)
        case .unknown(.transcriptGone):
            throw Refusal.transcriptGone(id)
        case .unknown(.noRecord):
            throw Refusal.noRecord(id)
        case .saved(let found):
            return .free(record, found)
        }
    }

    /// The command that resumes the conversation in whatever terminal runs it: this verb with
    /// `--here`, so it takes the lock and asks the probe at the moment it runs.
    func guardedCommand(conversationID: String) -> String {
        "\(RaceGroupPlanner.shellQuoted(cliPath)) conversation resume \(conversationID) --here"
    }

    /// Writes what the caller filled in on a record (a launch's requested effort, or the whole
    /// record for a launch from before records existed) so the `--here` run under a handle
    /// reads it too.
    private func keepFilledIn(_ record: ConversationRecord) {
        let stored = records.load(conversationID: record.conversationID)
        guard stored == nil || (stored?.launch == nil && record.launch != nil) else { return }
        let observation = ConversationObservation(
            harness: record.harness,
            conversationID: record.conversationID,
            host: record.host,
            cwd: record.cwd,
            configHome: record.configHome,
            transcriptPath: record.transcriptPath,
            workspacePath: record.workspacePath,
            workspaceCreatedAt: record.workspaceCreatedAt,
            socketLabel: record.socketLabel,
            observedAt: record.observedAt,
            observedBy: record.observedBy,
            launch: record.launch
        )
        do {
            if try records.record(observation, lockBudget: .seconds(2), movingDamagedAside: false) == .lockBusy {
                warn("warning: the conversation record was busy, so the resume may not keep the launch's effort.")
            }
        } catch {
            warn("warning: the conversation record was not updated: \(error.localizedDescription).")
        }
    }

    private func require(_ record: ConversationRecord) throws {
        guard record.harness == adapter.harness else { throw Refusal.unsupportedHarness(record.harness) }
        guard record.host == host else {
            throw Refusal.otherHost(
                conversationID: record.conversationID, host: record.host,
                advice: adapter.forkAdvice(conversationID: record.conversationID))
        }
        try requireDirectories(of: record)
    }

    private func claim(
        _ conversationID: String,
        for kind: ConversationRecordStore.ClaimKind = .start
    ) async throws -> AgentConversationLock {
        do {
            return try await records.claim(conversationID, for: kind)
        } catch ConversationRecordStore.ClaimError.held {
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

    /// Says the conversation is now in this terminal and this process, which the exec is about
    /// to make the harness: a pid keeps its start time across an exec. Once the lock's
    /// descriptor closes in that exec, this sighting is all another resume has to find the
    /// harness by; the decision that follows reads it back. Returns the process it named.
    private func recordSighting(of record: ConversationRecord) throws -> ProcessIdentity {
        let id = record.conversationID
        guard let harness = inspector.identity(getpid()) else {
            throw Refusal.unrecorded(conversationID: id, reason: "the kernel would not describe this process")
        }
        let tmux = TmuxEnvironment(environment["TMUX"])
        let observation = ConversationObservation(
            harness: record.harness,
            conversationID: id,
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
            ),
            harnessProcess: .named(harness)
        )
        let outcome: ConversationRecordStore.WriteOutcome
        do {
            outcome = try records.record(
                observation, lockBudget: .seconds(2), movingDamagedAside: false,
                ended: { inspector.liveness($0) == .ended })
        } catch {
            throw Refusal.unrecorded(conversationID: id, reason: error.localizedDescription)
        }
        guard outcome == .written else {
            throw Refusal.unrecorded(conversationID: id, reason: "its record stayed locked for two seconds")
        }
        return harness
    }

    /// Starts the guarded command under `handle`: a new session when there is none, or typed
    /// into the idle shell there when nobody is looking at it. Returns nil once the command
    /// there has become the harness, or the holders when it found the conversation held.
    private func start(
        record: ConversationRecord,
        handle: String,
        live: Bool
    ) async throws -> [ConversationHolder]? {
        let command = guardedCommand(conversationID: record.conversationID)
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
        if await waitForHandOff(of: record.conversationID, in: handle) { return nil }
        if case .held(let holders, _) = await probe.probe(records.load(conversationID: record.conversationID) ?? record)
        {
            return holders
        }
        throw Refusal.startFailed(handle: handle, conversationID: record.conversationID)
    }

    /// Until the `--here` run under `handle` has recorded itself and exec'd into the harness.
    /// `false` if it did not within ten seconds: it failed, refused, or has not run yet. Any
    /// running harness the record names counts: the probe under the lock found none before
    /// the command was sent, and the hand-off claim keeps a second sender out since.
    private func waitForHandOff(of conversationID: String, in handle: String) async -> Bool {
        var handleSession: ConversationRecord.TmuxSession?
        var askedHandle = false
        for _ in 0..<100 {
            for entry in records.load(conversationID: conversationID)?.harnessProcesses.entries ?? [] {
                guard let tmux = entry.seenIn?.tmux, inspector.isRunning(entry.process),
                    let arguments = inspector.arguments(entry.process.pid), !Self.isResumeVerb(arguments)
                else { continue }
                if tmux.name == nil, !askedHandle {
                    handleSession = await control.sessionIdentity(handle: handle)
                    askedHandle = true
                }
                if Self.sighting(tmux, isIn: handle, handleSession: handleSession) { return true }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// A sighting is in `handle` when it carries the handle's name, or, when the hook could
    /// not learn a name, when it is the handle's session on the handle's server.
    static func sighting(
        _ tmux: ConversationRecord.TmuxSession,
        isIn handle: String,
        handleSession: ConversationRecord.TmuxSession?
    ) -> Bool {
        if let name = tmux.name { return name == handle }
        guard let handleSession else { return false }
        return tmux.serverPID == handleSession.serverPID && tmux.sessionID == handleSession.sessionID
    }

    static func isResumeVerb(_ arguments: [String]) -> Bool {
        arguments.count >= 3 && arguments[1] == "conversation" && arguments[2] == "resume"
    }
}

extension ConversationRecord {
    /// A record for a launch from before Conversation records, built from what its Launch
    /// Record says. The workspace's creation is bounded by the launch time, the same rule
    /// `AgentLaunchRecord.isForWorkspaceOnDisk` applies.
    public init(launch: AgentLaunchRecord, host: String, harness: String) {
        self.init(
            schema: Self.schemaVersion,
            harness: harness,
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
