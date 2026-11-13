//
//  TerminalSessionExit.swift
//  WorkspaceManagerCore
//
//  How a terminal session's tile ended, and the tmux question that tells the cases
//  apart. The answer decides what the session's continuity row keeps: a person
//  ending the tile ends the row, while a tmux server dying under it leaves the row
//  open so the next launch can bring the tile back.
//

import Foundation

/// How a terminal session's tile ended.
///
/// Each case maps to one thing its continuity row keeps (`rowOutcome`), so a reason
/// that should keep the row — losing the holder, a detach, a later deliberate pause —
/// is one more case rather than a flag beside the close path.
public enum TerminalSessionExit: Sendable, Equatable {
    /// The person closed the tile.
    case userClosed
    /// The app closed the tile along with its scope: a workspace archived or a repo
    /// removed. The tile is gone for good, and what happens to its tmux session is the
    /// retiring path's decision, not the close's.
    case retired
    /// The tile's own shell ended: a plain shell exiting, or the tile's tmux session
    /// ending on a server that is still running.
    case shellExited
    /// The tmux server holding the tile's processes died under it. Nobody chose to end
    /// the tile, so the row stays restorable.
    case holderLost
    /// The tile's tmux client left a session that is still running, for example a
    /// detach. The work the row describes is alive, so the row stays open and the next
    /// launch reattaches it.
    case detached
    /// The evidence cannot tell the other reasons apart: tmux gave no answer, or its answer
    /// is ambiguous without the launch's server identity or a server known to outlive its
    /// last session. Ending the row cannot be undone and keeping it costs one restore
    /// offer, so the row stays open.
    case undetermined

    /// What a tile ending this way leaves on its continuity row.
    public enum RowOutcome: Sendable, Equatable {
        /// Set `ended_at`: the row leaves every restore set.
        case end
        /// Set `holder_lost_at` and leave the row open.
        case markHolderLost
        /// Leave the row open with nothing new recorded about why.
        case keepOpen
    }

    public var rowOutcome: RowOutcome {
        switch self {
        case .userClosed, .retired, .shellExited:
            return .end
        case .holderLost:
            return .markHolderLost
        case .detached, .undetermined:
            return .keepOpen
        }
    }

    /// Whether a tile ending this way kills its own tmux session.
    ///
    /// Only a person closing the tile asks for its work to end. Every other reason is the
    /// tmux client ending, which happens because the session is already gone or because
    /// the client left a session still running work, so killing on it has nothing to gain
    /// and a running session to lose.
    public var reclaimsTmuxSession: Bool {
        switch self {
        case .userClosed:
            return true
        case .retired, .shellExited, .holderLost, .detached, .undetermined:
            return false
        }
    }

    /// The reason a split pane gets when it is torn down because its tab ended this way.
    ///
    /// A pane goes with its tab and shares what happened to it: closed with it, retired
    /// with it, lost with the same server, left running beside it, or as unknown as the
    /// tab is. A tab whose own shell ended closes its panes as closing the tab would: their
    /// rows end, and their tmux sessions are reclaimed, since an ended row leaves a running
    /// pane-scoped session no way back (#1232).
    public var collateralExit: TerminalSessionExit {
        switch self {
        case .shellExited:
            return .userClosed
        case .userClosed, .retired, .holderLost, .detached, .undetermined:
            return self
        }
    }

    /// The reason a process exit gets, from what tmux says once the client is gone.
    ///
    /// `tmuxHolder` is `nil` for a tile that did not launch through tmux — its shell was
    /// the process, so its exit is the shell's.
    ///
    /// For a tmux tile, what is left decides, and only an answer that rules the other
    /// cases out ends the row:
    ///
    /// - **No server.** The app's launch script turns `exit-empty` off, so on a tmux that
    ///   honours it (`serverKeepsRunningWhenEmpty`) the server outlives its last session
    ///   and a server that is gone was killed or crashed: the holder was lost. On a tmux
    ///   without the option (before 2.7), or before a launch has learned which, the last
    ///   shell ending also takes the server down, so the exit is undetermined.
    /// - **A server that answers.** `launchServerPID` is the server the tile launched on,
    ///   once the app recorded it. A server with another pid was started after the tile's
    ///   own died, so the holder was lost whatever it holds now. The same server still
    ///   holding the session is a detach; the same server without it is the shell ending.
    ///   Without both pids the server cannot be told from a replacement, so a missing
    ///   session is undetermined, and a present one is still a detach.
    public static func classifyProcessExit(
        tmuxHolder: TmuxHolderState?,
        launchServerPID: Int?,
        serverKeepsRunningWhenEmpty: Bool?
    ) -> TerminalSessionExit {
        guard let tmuxHolder else { return .shellExited }
        switch tmuxHolder {
        case .unanswered:
            return .undetermined
        case .serverGone:
            return serverKeepsRunningWhenEmpty == true ? .holderLost : .undetermined
        case .sessionPresent(let serverPID):
            if let launchServerPID, let serverPID, serverPID != launchServerPID {
                return .holderLost
            }
            return .detached
        case .sessionGone(let serverPID):
            guard let launchServerPID, let serverPID else { return .undetermined }
            return serverPID == launchServerPID ? .shellExited : .holderLost
        }
    }
}

/// What a tmux socket says about one session after a client left it.
public enum TmuxHolderState: Sendable, Equatable {
    /// The server answered and still holds the session. `serverPID` is the answering
    /// server's pid, when tmux reported it.
    case sessionPresent(serverPID: Int?)
    /// The server answered and the session is gone.
    case sessionGone(serverPID: Int?)
    /// No server is running on the socket.
    case serverGone
    /// tmux did not answer: missing, wedged, or an error this probe does not read.
    case unanswered
}

/// Asks one tmux socket whether its server and a named session are still there.
///
/// It reads and never starts anything: on a socket with no server, the commands exit
/// non-zero without creating one. The label is a parameter so a test can point it at an
/// isolated server.
public struct TmuxHolderProbe: Sendable {
    public let socketLabel: String
    private let environment: [String: String]

    public init(
        socketLabel: String = TmuxSessionProbe.socketLabel,
        environment: [String: String] = TmuxSessionProbe.defaultEnvironment
    ) {
        self.socketLabel = socketLabel
        self.environment = environment
    }

    /// The tmux session a probe asks after: its name, and tmux's own id for it (`$7`) when
    /// the app recorded one. The id still finds the session after a rename. The name still
    /// counts too, since a record outlives a relaunch that landed on a newer session of
    /// that name, and missing a held session would read a detach as the shell ending.
    public struct Session: Sendable, Equatable {
        public let name: String
        public let id: String?

        public init(name: String, id: String? = nil) {
            self.name = name
            self.id = id
        }
    }

    /// One tmux call: the server's pid, then every session's id and name. A server with no
    /// sessions still answers the pid, which `exit-empty off` makes an ordinary state.
    public func holderState(for session: Session) async -> TmuxHolderState {
        let arguments = [
            "tmux", "-L", socketLabel,
            "display-message", "-p", "#{pid}", ";",
            "list-sessions", "-F", "#{session_id}\t#{session_name}",
        ]
        guard TmuxLiveSocketGuard.permits(tmuxArguments: arguments) else { return .unanswered }
        do {
            let result = try await ProcessRunner.run(
                executable: "/usr/bin/env",
                arguments: arguments,
                environment: environment,
                timeout: 5
            )
            return Self.holderState(
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr,
                session: session
            )
        } catch {
            return .unanswered
        }
    }

    /// The pid of the server holding `sessionName` with a client from the process group
    /// `foregroundGroup` attached to it, or `nil` when no server answers with such a client.
    ///
    /// This is how a launch proves which server it landed on. A session name alone cannot:
    /// a server started after the launch's own died can hold the same name, with or without
    /// clients of its own. The surface's tmux client runs in its pty's foreground process
    /// group, which `login` leads and no other terminal's processes join, so a server listing
    /// a client from that group on the session is the one the surface attached to.
    public func serverPID(
        attachingClientInGroup foregroundGroup: Int, toSessionNamed sessionName: String
    ) async -> Int? {
        let arguments = [
            "tmux", "-L", socketLabel,
            "display-message", "-p", "#{pid}", ";",
            "list-clients", "-F", "#{client_pid}\t#{session_name}",
        ]
        guard TmuxLiveSocketGuard.permits(tmuxArguments: arguments) else { return nil }
        do {
            let result = try await ProcessRunner.run(
                executable: "/usr/bin/env",
                arguments: arguments,
                environment: environment,
                timeout: 5
            )
            guard result.exitCode == 0 else { return nil }
            return Self.serverPID(
                listing: result.stdout, attachingClientInGroup: foregroundGroup, toSessionNamed: sessionName)
        } catch {
            return nil
        }
    }

    /// Reads `display-message -p '#{pid}' ; list-clients -F '#{client_pid}<tab>#{session_name}'`:
    /// the server's pid, then one line per client. `processGroup` reads a live client's group.
    static func serverPID(
        listing stdout: String,
        attachingClientInGroup foregroundGroup: Int,
        toSessionNamed sessionName: String,
        processGroup: (Int) -> Int? = { pid in
            let group = getpgid(pid_t(pid))
            return group > 0 ? Int(group) : nil
        }
    ) -> Int? {
        var lines = stdout.split(separator: "\n").map(String.init)
        guard !lines.isEmpty, let serverPID = Int(lines.removeFirst().trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let attached = lines.contains { line in
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2, fields[1] == sessionName, let clientPID = Int(fields[0]) else { return false }
            return processGroup(clientPID) == foregroundGroup
        }
        return attached ? serverPID : nil
    }

    /// What tmux prints when no server holds the socket. "no server running on <path>"
    /// and "error connecting to <path>" come from a socket with no server or no socket
    /// file. A probe that reaches a server as it dies reads "server exited unexpectedly"
    /// or "lost server" instead; the server is gone all the same.
    static let serverGoneMessages = [
        "no server running",
        "error connecting to",
        "server exited unexpectedly",
        "lost server",
    ]

    /// Reads `display-message -p '#{pid}' ; list-sessions -F '#{session_id}<tab>#{session_name}'`:
    /// the first line is the server's pid, the rest are sessions. The session asked after
    /// is held when a line carries its id or its name.
    static func holderState(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        session: Session
    ) -> TmuxHolderState {
        guard exitCode == 0 else {
            let serverGone = serverGoneMessages.contains { stderr.contains($0) }
            return serverGone ? .serverGone : .unanswered
        }
        var lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let serverPID = lines.isEmpty ? nil : Int(lines.removeFirst().trimmingCharacters(in: .whitespaces))
        let held = lines.contains { line in
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { return false }
            return fields[0] == session.id || fields[1] == session.name
        }
        return held
            ? .sessionPresent(serverPID: serverPID)
            : .sessionGone(serverPID: serverPID)
    }
}

/// Whether a tmux server keeps running once its last session ends.
///
/// The launch script sets `exit-empty off` on its socket's server; tmux before 2.7 rejects
/// the option, and a server someone set back to `on` exits when empty. Either way a server
/// that is gone cannot be told killed from emptied (`TerminalSessionExit.classifyProcessExit`).
/// The answer belongs to one server, so it is kept by that server's pid and asked again
/// when a launch lands on another.
public actor TmuxExitEmptyCapability {
    /// One server's answer: its pid, and whether its `exit-empty` is off.
    public struct Reading: Sendable, Equatable {
        public let serverPID: Int
        public let keepsRunningWhenEmpty: Bool

        public init(serverPID: Int, keepsRunningWhenEmpty: Bool) {
            self.serverPID = serverPID
            self.keepsRunningWhenEmpty = keepsRunningWhenEmpty
        }
    }

    /// Asks a label's server, answering `nil` when no server answered.
    public typealias Reader = @Sendable (_ socketLabel: String) async -> Reading?

    private let read: Reader
    private var known: [String: Reading] = [:]
    private var inFlight: [String: Task<Reading?, Never>] = [:]

    public init(read: @escaping Reader = TmuxExitEmptyCapability.readFromServer) {
        self.read = read
    }

    /// Asks the label's server unless `serverPID` has already answered. Concurrent asks for
    /// one label share a single read.
    public func learn(onSocket socketLabel: String, serverPID: Int) async {
        guard known[socketLabel]?.serverPID != serverPID else { return }
        if let pending = inFlight[socketLabel] {
            _ = await pending.value
            return
        }
        let read = read
        let pending = Task { await read(socketLabel) }
        inFlight[socketLabel] = pending
        let reading = await pending.value
        inFlight[socketLabel] = nil
        if let reading {
            known[socketLabel] = reading
        }
    }

    /// Whether the server with `serverPID` keeps running when empty, or `nil` when that
    /// server has not answered.
    public func keepsRunningWhenEmpty(onSocket socketLabel: String, serverPID: Int?) -> Bool? {
        guard let serverPID, let reading = known[socketLabel], reading.serverPID == serverPID else { return nil }
        return reading.keepsRunningWhenEmpty
    }

    /// `display-message -p '#{pid}' ; show-options -s exit-empty` on the label's server. It
    /// starts no server, and the pid prints even when the option is rejected.
    public static let readFromServer: Reader = { socketLabel in
        let arguments = [
            "tmux", "-L", socketLabel,
            "display-message", "-p", "#{pid}", ";",
            "show-options", "-s", "exit-empty",
        ]
        guard TmuxLiveSocketGuard.permits(tmuxArguments: arguments) else { return nil }
        do {
            let result = try await ProcessRunner.run(
                executable: "/usr/bin/env",
                arguments: arguments,
                environment: TmuxSessionProbe.defaultEnvironment,
                timeout: 5
            )
            return reading(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        } catch {
            return nil
        }
    }

    /// Only `exit-empty off` keeps a server running when empty. tmux before 2.7 rejects the
    /// name ("unknown option" there, "invalid option" in later releases for any name they
    /// lack). Any other failure, such as no server running, answers nothing.
    static func reading(exitCode: Int32, stdout: String, stderr: String) -> Reading? {
        let lines = stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let serverPID = lines.first.flatMap({ Int($0) }) else { return nil }
        if exitCode == 0 {
            return Reading(serverPID: serverPID, keepsRunningWhenEmpty: lines.contains("exit-empty off"))
        }
        let rejected = ["unknown option", "invalid option"].contains { stderr.contains($0) }
        return rejected ? Reading(serverPID: serverPID, keepsRunningWhenEmpty: false) : nil
    }
}
