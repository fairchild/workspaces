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
    /// A process is inside WorkSpaces when it carries either key a tile sets.
    public static func isInsideWorkSpaces(_ environment: [String: String]) -> Bool {
        [ConversationRecordStore.directoryEnvironmentKey, "WORKSPACES_HOST_SESSION_ID"].contains {
            !(environment[$0] ?? "").isEmpty
        }
    }

    /// Always returns 0: a hook's exit status is something Claude reports to the person, and
    /// nothing this observer can fail at is theirs to act on.
    public static func run(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        input: FileHandle = .standardInput,
        now: Date = Date(),
        tmuxSession: (TmuxEnvironment) -> ConversationRecord.TmuxSession? = TmuxEnvironment.describe,
        ancestry: () -> HookAncestry = { HookAncestry.above() }
    ) -> Int32 {
        guard isInsideWorkSpaces(environment) else { return 0 }
        guard let payload = try? input.readToEnd(),
            let observation = observation(
                payload: payload,
                environment: environment,
                now: now,
                tmuxSession: tmuxSession,
                ancestry: ancestry
            )
        else { return 0 }
        let store = ConversationRecordStore(
            directory: ConversationRecordStore.resolvedDirectory(environment: environment))
        _ = try? store.record(observation)
        return 0
    }

    public static func observation(
        payload: Data,
        environment: [String: String],
        now: Date,
        tmuxSession: (TmuxEnvironment) -> ConversationRecord.TmuxSession? = { _ in nil },
        ancestry: () -> HookAncestry = { HookAncestry(claude: nil, passed: []) }
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
    public static let ancestorLimit = 8
}

/// What a hook finds above it: the nearest claude, as far up as it looks and short of
/// launchd or a tmux server, and the processes it passed on the way, up to the one leading
/// the terminal's session; nothing above that leader, `login` or the terminal application,
/// can be what runs the conversation. A claude above a program that fired the hook beneath
/// it is named too, and holds that conversation until it exits: a wrong name costs a wait.
/// The passed processes are recorded either way, since any of them may be what runs the
/// conversation, a harness the adapter does not recognize among them; the hook's own shell
/// and the forwarder exit with it.
public struct HookAncestry: Equatable, Sendable {
    public var claude: ProcessIdentity?
    public var passed: [ProcessIdentity]

    public init(claude: ProcessIdentity?, passed: [ProcessIdentity]) {
        self.claude = claude
        self.passed = passed
    }

    public var answer: ConversationRecord.HarnessAnswer {
        claude.map { .named($0, passing: passed) } ?? .unnamed(chain: passed)
    }

    public static func above(_ pid: Int32 = getppid(), inspector: ProcessInspector = .live) -> HookAncestry {
        var passed: [ProcessIdentity] = []
        var passing = true
        var current = pid
        for _ in 0..<ConversationHookObserver.ancestorLimit {
            guard current > 1 else { break }
            let words = inspector.arguments(current)
            if let words, AgentSessionInspection.isClaude(words) {
                return HookAncestry(claude: inspector.identity(current), passed: passed)
            }
            if let program = words?.first, URL(fileURLWithPath: program).lastPathComponent.hasPrefix("tmux") { break }
            if passing, let identity = inspector.identity(current) { passed.append(identity) }
            if inspector.leadsTerminalSession(current) { passing = false }
            guard let parent = inspector.parent(current) else { break }
            current = parent
        }
        return HookAncestry(claude: nil, passed: passed)
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
