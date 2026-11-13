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
    /// tmux gave no answer about what is left, so nothing is known about the tile's
    /// work. Ending the row cannot be undone and keeping it costs one restore offer, so
    /// the row stays open.
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
    /// For a tmux tile the answer alone decides. The app's launch script turns
    /// `exit-empty` off on its socket's server, so the server outlives its last session
    /// and a server that is gone was killed or crashed: the holder was lost. A server
    /// that answers names the session as still there (a detach) or gone (the shell
    /// ended). `launchServerPID` is the server the tile launched on, when the app
    /// recorded it; a server answering with another pid was started after the tile's
    /// own died, so the holder was lost whatever that server holds now.
    public static func classifyProcessExit(
        tmuxHolder: TmuxHolderState?,
        launchServerPID: Int?
    ) -> TerminalSessionExit {
        guard let tmuxHolder else { return .shellExited }
        switch tmuxHolder {
        case .unanswered:
            return .undetermined
        case .serverGone:
            return .holderLost
        case .sessionPresent(let serverPID), .sessionGone(let serverPID):
            if let launchServerPID, let serverPID, serverPID != launchServerPID {
                return .holderLost
            }
            if case .sessionPresent = tmuxHolder {
                return .detached
            }
            return .shellExited
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

    /// One tmux call: the server's pid, then every session name. A server with no
    /// sessions still answers the pid, which `exit-empty off` makes an ordinary state.
    public func holderState(forSessionNamed sessionName: String) async -> TmuxHolderState {
        let arguments = [
            "tmux", "-L", socketLabel,
            "display-message", "-p", "#{pid}", ";",
            "list-sessions", "-F", "#{session_name}",
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
                sessionName: sessionName
            )
        } catch {
            return .unanswered
        }
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

    /// Reads `display-message -p '#{pid}' ; list-sessions -F '#{session_name}'`: the
    /// first line is the server's pid, the rest are session names.
    static func holderState(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        sessionName: String
    ) -> TmuxHolderState {
        guard exitCode == 0 else {
            let serverGone = serverGoneMessages.contains { stderr.contains($0) }
            return serverGone ? .serverGone : .unanswered
        }
        var lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let serverPID = lines.isEmpty ? nil : Int(lines.removeFirst().trimmingCharacters(in: .whitespaces))
        return lines.contains(sessionName)
            ? .sessionPresent(serverPID: serverPID)
            : .sessionGone(serverPID: serverPID)
    }
}
