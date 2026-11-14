//
//  ConversationHookObserver.swift
//  WorkspaceManagerCore
//
//  `workspaces conversation observe`: the SessionStart hook that writes a Conversation record
//  from Claude's payload, whether or not the app is running. It is installed for every Claude
//  session on the machine, so outside WorkSpaces it leaves at once, and inside it never
//  fails or waits in a way Claude could see.
//

import Foundation

public enum ConversationHookObserver {
    public typealias RecordWrite = (ConversationRecordStore, ConversationObservation, Duration) throws
        -> ConversationRecordStore.WriteOutcome

    /// A process is inside WorkSpaces when it carries either key a tile sets.
    public static func isInsideWorkSpaces(_ environment: [String: String]) -> Bool {
        [ConversationRecordStore.directoryEnvironmentKey, "WORKSPACES_HOST_SESSION_ID"].contains {
            !(environment[$0] ?? "").isEmpty
        }
    }

    /// Returns 0, since a hook's exit status is something Claude reports to the person, except
    /// when a note was owed and could not be written: then it returns 1 with a line on standard
    /// error. A note is owed when the walk could not say what runs the conversation, or found
    /// only processes that have exited, and then it is written before the record, which is
    /// left as it was when the note fails, so the uncertainty is written first or nothing is.
    /// A note is owed too when the record naming what runs it cannot be written, busy past
    /// `lockBudget` or failing, since a reader would otherwise find the conversation free.
    public static func run(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        input: FileHandle = .standardInput,
        now: Date = Date(),
        tmuxSession: (TmuxEnvironment) -> ConversationRecord.TmuxSession? = TmuxEnvironment.describe,
        ancestry: ([String: String]) -> HookAncestry = {
            HookAncestry.above(tmuxServer: TmuxEnvironment($0["TMUX"]).map { Int32($0.serverPID) })
        },
        inspector: ProcessInspector = .live,
        recordUnresolved: (ConversationRecordStore, ConversationObservation, HookAncestry) throws -> URL = {
            try $0.recordUnresolved($1, ancestry: $2)
        },
        lockBudget: Duration = .seconds(5),
        record: RecordWrite = { try $0.record($1, lockBudget: $2) },
        warn: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) -> Int32 {
        guard isInsideWorkSpaces(environment) else { return 0 }
        let walked = ancestry(environment)
        guard let payload = try? input.readToEnd(),
            let observation = observation(
                payload: payload,
                environment: environment,
                now: now,
                tmuxSession: tmuxSession,
                ancestry: { walked }
            )
        else { return 0 }
        let store = ConversationRecordStore(
            directory: ConversationRecordStore.resolvedDirectory(environment: environment))
        func leaveNote() -> Bool {
            do {
                _ = try recordUnresolved(store, observation, walked)
                return true
            } catch {
                warn(
                    "workspaces: could not record that this hook cannot tell what runs conversation "
                        + "\(observation.conversationID): \(error.localizedDescription)")
                return false
            }
        }
        // A walk that cannot say what runs the conversation, or whose every process has
        // exited before the write, leaves a note beside the record, before the record so no
        // reader sees the one without the other. Processes that exit during the write leave a
        // record that names only processes that have ended, which is what free means.
        let noted = !walked.complete || !walked.mayStillRun(inspector)
        if noted, !leaveNote() { return 1 }
        // A record this hook could not write leaves the conversation reading free while what
        // it found runs it, so that is uncertainty too, and it is written as a note.
        let written = (try? record(store, observation, lockBudget)) == .written
        if written || noted { return 0 }
        return leaveNote() ? 0 : 1
    }

    public static func observation(
        payload: Data,
        environment: [String: String],
        now: Date,
        tmuxSession: (TmuxEnvironment) -> ConversationRecord.TmuxSession? = { _ in nil },
        ancestry: () -> HookAncestry = { HookAncestry(claude: nil, passed: [], complete: false) }
    ) -> ConversationObservation? {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
            let sessionID = object["session_id"] as? String,
            let conversationID = ConversationRecord.normalizedID(sessionID)
        else { return nil }
        let tmux = TmuxEnvironment(environment["TMUX"])
        let hostSessionID = (environment["WORKSPACES_HOST_SESSION_ID"]).flatMap { UUID(uuidString: $0)?.uuidString }
        let place = ConversationRecord.LastSeenIn(
            hostSessionID: hostSessionID,
            tmux: tmux.flatMap(tmuxSession),
            outsideTmux: tmux == nil
        )
        return ConversationObservation(
            conversationID: conversationID,
            cwd: (object["cwd"] as? String) ?? FileManager.default.currentDirectoryPath,
            configHome: environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 },
            transcriptPath: object["transcript_path"] as? String,
            socketLabel: tmux?.socketLabel,
            observedAt: now,
            observedBy: .hook,
            lastSeenIn: place,
            harnessProcess: ancestry().answer
        )
    }
}

extension ConversationHookObserver {
    /// The file name the app installs the SessionStart forwarder under.
    public static let forwarderName = "conversation-observer.sh"

    /// How far up the hook looks for its claude: past the hook's shell, the forwarder, and
    /// any wrapper, link or shim between them.
    /// A bound on the walk for safety alone: a walk that reaches it records a note, not a chain.
    public static let ancestorLimit = 64
}

/// What a hook finds above it: the nearest claude, short of launchd and the tmux server its
/// `TMUX` names, and the processes it passed on the way, up to and including the one leading
/// the terminal's session, since what sits above that leader, `login` or the terminal
/// application, runs no conversation unless it is a claude: the search for a claude goes on
/// above it, and a claude found there is named. A claude above a program that fired the hook
/// beneath it is named too, and holds that conversation until it exits. The passed processes are
/// recorded either way, since any of them may be what runs the conversation, a harness the
/// adapter does not recognize among them; the hook's own shell and the forwarder exit with it.
///
/// The walk is complete when it found a claude, the terminal's session leader or the tmux
/// server. One that reached launchd with none of them, as a hook whose parent left it does,
/// ran out of generations, or could not read a process on the way, cannot say what runs the
/// conversation.
public struct HookAncestry: Equatable, Sendable {
    public var claude: ProcessIdentity?
    public var passed: [ProcessIdentity]
    public var complete: Bool

    public init(claude: ProcessIdentity?, passed: [ProcessIdentity], complete: Bool = true) {
        self.claude = claude
        self.passed = passed
        self.complete = complete
    }

    public var answer: ConversationRecord.HarnessAnswer {
        claude.map { .named($0, passing: passed) } ?? .unnamed(chain: passed)
    }

    /// Whether any process the walk would record may still run.
    public func mayStillRun(_ inspector: ProcessInspector) -> Bool {
        ([claude].compactMap { $0 } + passed).contains { inspector.liveness($0) != .ended }
    }

    public static func above(
        _ pid: Int32 = getppid(), tmuxServer: Int32? = nil, inspector: ProcessInspector = .live
    ) -> HookAncestry {
        var passed: [ProcessIdentity] = []
        var reachedLeader = false
        var readAll = true
        var current = pid
        for _ in 0..<ConversationHookObserver.ancestorLimit {
            if current == tmuxServer { return HookAncestry(claude: nil, passed: passed, complete: readAll) }
            guard current > 1 else { break }
            if let words = inspector.arguments(current), AgentSessionInspection.isClaude(words) {
                let claude = inspector.identity(current)
                return HookAncestry(claude: claude, passed: passed, complete: claude != nil && readAll)
            }
            if !reachedLeader {
                if let identity = inspector.identity(current) { passed.append(identity) } else { readAll = false }
                reachedLeader = inspector.leadsTerminalSession(current)
            }
            guard let parent = inspector.parent(current) else {
                readAll = false
                break
            }
            current = parent
        }
        return HookAncestry(claude: nil, passed: passed, complete: reachedLeader && readAll)
    }
}

/// The tmux session a process runs in, as `$TMUX` gives it: `<socket path>,<server pid>,<session
/// id number>`. The socket's file name is the `-L` label it was started under.
public struct TmuxEnvironment: Equatable, Sendable {
    public let socketPath: String
    public let serverPID: Int
    public let sessionID: String

    public init?(_ value: String?) {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 3, let pid = Int(parts[parts.count - 2]), let number = Int(parts[parts.count - 1])
        else { return nil }
        socketPath = parts.dropLast(2).joined(separator: ",")
        serverPID = pid
        sessionID = "$\(number)"
    }

    public var socketLabel: String {
        URL(fileURLWithPath: socketPath).lastPathComponent
    }

    /// Asks the server for the session's creation time and name, which with the pid and id
    /// make an identity a restarted server cannot repeat. Best effort: a server that does not
    /// answer within half a second leaves them out.
    public static func describe(_ tmux: TmuxEnvironment) -> ConversationRecord.TmuxSession? {
        var described = ConversationRecord.TmuxSession(
            serverPID: tmux.serverPID,
            sessionID: tmux.sessionID,
            socketPath: tmux.socketPath,
            serverStartedAtMicroseconds: ProcessInspector.live.identity(Int32(tmux.serverPID))?.startedAtMicroseconds
        )
        let arguments = [
            "tmux", "-u", "-S", tmux.socketPath, "display-message", "-p", "-t", tmux.sessionID,
            "#{session_created}\t#{session_name}",
        ]
        guard TmuxLiveSocketGuard.permits(tmuxArguments: arguments) else { return described }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = TmuxSessionProbe.pathPrependingToolPaths(environment["PATH"])
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return described }
        guard exited.wait(timeout: .now() + 0.5) == .success, process.terminationStatus == 0 else {
            if process.isRunning { process.terminate() }
            return described
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let fields = text.trimmingCharacters(in: .newlines).split(separator: "\t", maxSplits: 1)
        if let seconds = fields.first.flatMap({ TimeInterval($0) }) {
            described.createdAt = Date(timeIntervalSince1970: seconds)
        }
        if fields.count == 2 { described.name = String(fields[1]) }
        return described
    }
}
