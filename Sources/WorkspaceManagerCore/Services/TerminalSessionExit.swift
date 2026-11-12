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

    /// What a tile ending this way leaves on its continuity row.
    public enum RowOutcome: Sendable, Equatable {
        /// Set `ended_at`: the row leaves every restore set.
        case end
        /// Set `holder_lost_at` and leave the row open.
        case markHolderLost
        /// Write nothing; the row stays open as it is.
        case keepOpen
    }

    public var rowOutcome: RowOutcome {
        switch self {
        case .userClosed, .shellExited:
            return .end
        case .holderLost:
            return .markHolderLost
        case .detached:
            return .keepOpen
        }
    }

    /// The reason a process exit gets, from what tmux says once the client is gone.
    ///
    /// `tmuxHolder` is `nil` for a tile that did not launch through tmux — its shell was
    /// the process, so its exit is the shell's. A tmux client exits for one of three
    /// reasons, and the server and session that remain say which.
    ///
    /// A server that is gone has two causes tmux does not tell apart from outside: it
    /// was killed, or its last session ended and it exited because it was empty. Only
    /// the first is a lost holder. `serverHeldOtherSessions` separates them — a server
    /// that also held another tile's session was not empty when this one ended — and
    /// without it the exit reads as the shell's, which is what ending a lone tile
    /// usually is.
    ///
    /// A probe that got no answer reads as the shell's exit too: keeping the row on a
    /// guess would bring back tiles nobody can account for.
    public static func classifyProcessExit(
        tmuxHolder: TmuxHolderState?,
        serverHeldOtherSessions: Bool
    ) -> TerminalSessionExit {
        switch tmuxHolder {
        case nil, .sessionGone, .unanswered:
            return .shellExited
        case .sessionPresent:
            return .detached
        case .serverGone:
            return serverHeldOtherSessions ? .holderLost : .shellExited
        }
    }
}

/// What a tmux socket says about one session after a client left it.
public enum TmuxHolderState: Sendable, Equatable {
    /// The server answered and still holds the session.
    case sessionPresent
    /// The server answered and the session is gone.
    case sessionGone
    /// No server is running on the socket.
    case serverGone
    /// tmux did not answer: missing, wedged, or an error this probe does not read.
    case unanswered
}

/// Asks one tmux socket whether its server and a named session are still there.
///
/// It reads and never starts anything: `list-sessions` on a socket with no server
/// exits non-zero without creating one. The label is a parameter so a test can point
/// it at an isolated server.
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

    public func holderState(forSessionNamed sessionName: String) async -> TmuxHolderState {
        do {
            let result = try await ProcessRunner.run(
                executable: "/usr/bin/env",
                arguments: ["tmux", "-L", socketLabel, "list-sessions", "-F", "#{session_name}"],
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

    /// Reads `list-sessions -F '#{session_name}'`. tmux reports a socket with no server
    /// as "no server running on <path>", or "error connecting to <path>" when the socket
    /// file is missing or refuses; both mean nothing holds sessions there.
    static func holderState(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        sessionName: String
    ) -> TmuxHolderState {
        guard exitCode == 0 else {
            let noServer = stderr.contains("no server running") || stderr.contains("error connecting to")
            return noServer ? .serverGone : .unanswered
        }
        let names = stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return names.contains(sessionName) ? .sessionPresent : .sessionGone
    }
}
