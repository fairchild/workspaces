//
//  TmuxSessionControl.swift
//  WorkspaceManagerCore
//
//  Creates, reads, and writes detached terminal sessions on the dedicated
//  `-L workspaces` tmux socket — the same substrate the app launches its own
//  terminals on, so a session the CLI starts headlessly is one the app can adopt.
//  Command composition is pure and separately testable; execution is injected so
//  every answer is reachable without a real tmux server.
//

import Foundation

public struct TmuxSessionControl: Sendable {
    /// Runs a command and yields its exit code plus captured output, or `nil` on
    /// launch failure or timeout.
    public typealias CommandRunner =
        @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]?) async
        -> ProcessResult?

    /// The socket label every command carries. Defaults to the app's own
    /// `workspaces` server; an isolated run (a test, a second checkout) names its
    /// own so it cannot reach into a live desktop's sessions.
    public static let defaultSocketLabel = TmuxSessionProbe.socketLabel

    /// Names the socket label for a launch that must not touch the desktop's
    /// server. Read by the CLI, not by the app.
    public static let socketLabelEnvironmentKey = "WORKSPACES_TMUX_SOCKET_LABEL"

    /// Scrollback lines `read` returns when the caller names no bound.
    public static let defaultCaptureLines = 200

    /// Geometry a detached session is created at. tmux would otherwise default to
    /// 80x24, and an agent that renders into 80 columns keeps that wrapping in the
    /// scrollback `read` returns — a client attaching later resizes the session but
    /// cannot unwrap what was already written.
    public static let detachedPaneWidth = 200
    public static let detachedPaneHeight = 50

    public let socketLabel: String
    private let run: CommandRunner
    private let environment: [String: String]

    public init(
        socketLabel: String = TmuxSessionControl.defaultSocketLabel,
        run: @escaping CommandRunner = TmuxSessionControl.defaultRunner,
        environment: [String: String] = TmuxSessionProbe.defaultEnvironment
    ) {
        self.socketLabel = socketLabel
        self.run = run
        self.environment = environment
    }

    /// Resolves the socket label from a launch environment, falling back to the
    /// app's server. An empty override reads as unset rather than as a nameless
    /// socket.
    public static func socketLabel(from environment: [String: String]) -> String {
        guard
            let override = environment[socketLabelEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        else {
            return defaultSocketLabel
        }
        return override
    }

    // MARK: - Failure

    public enum ControlError: Error, LocalizedError, Equatable {
        case tmuxUnavailable
        case handleAlreadyLive(handle: String)
        case handleNotLive(handle: String)
        case commandFailed(verb: String, handle: String, stderr: String)

        public var errorDescription: String? {
            switch self {
            case .tmuxUnavailable:
                return "tmux is not available on PATH. Install tmux (brew install tmux) and try again."
            case .handleAlreadyLive(let handle):
                return
                    "A terminal session named '\(handle)' is already running. Read it with "
                    + "'workspaces ws read \(handle)', or pass --name <label> to launch a sibling session."
            case .handleNotLive(let handle):
                return
                    "No terminal session named '\(handle)' is running. It either never started or its "
                    + "command has exited; 'workspaces ws launch' starts a new one."
            case .commandFailed(let verb, let handle, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = detail.isEmpty ? "" : ": \(detail)"
                return "tmux \(verb) failed for '\(handle)'\(suffix)"
            }
        }
    }

    // MARK: - Command composition

    /// `new-session -d` with the pane's command run through a login shell, so a
    /// launched agent resolves the same PATH an interactive `workspaces open`
    /// would give it. Without a command the pane is a plain login shell.
    ///
    /// The session's lifetime is its command's: no `remain-on-exit`, matching both
    /// the app's own launches and what a person typing tmux by hand would get.
    public static func newSessionArguments(
        socketLabel: String,
        handle: String,
        directory: URL,
        command: String?
    ) -> [String] {
        var arguments = [
            "tmux", "-L", socketLabel, "new-session", "-d",
            "-s", handle,
            "-c", directory.path,
            "-x", String(detachedPaneWidth), "-y", String(detachedPaneHeight),
        ]
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--", "/bin/zsh", "-lc", command])
        }
        return arguments
    }

    /// `capture-pane -p` over the last `lines` rows of scrollback. `-S -<n>` starts
    /// the capture `n` lines above the visible pane, so a caller asking for more
    /// than a screenful gets history rather than padding.
    public static func capturePaneArguments(
        socketLabel: String,
        handle: String,
        lines: Int
    ) -> [String] {
        [
            "tmux", "-L", socketLabel, "capture-pane", "-p",
            "-t", paneTarget(handle),
            "-S", "-\(max(1, lines))",
        ]
    }

    /// `send-keys -l` writes the text literally, so a payload containing `Enter`,
    /// `C-c`, or a stray semicolon reaches the agent as characters rather than as
    /// key names tmux would interpret.
    public static func sendTextArguments(
        socketLabel: String,
        handle: String,
        text: String
    ) -> [String] {
        ["tmux", "-L", socketLabel, "send-keys", "-t", paneTarget(handle), "-l", "--", text]
    }

    /// The submit keystroke, sent as a separate call precisely because the text
    /// before it is literal.
    public static func sendEnterArguments(socketLabel: String, handle: String) -> [String] {
        ["tmux", "-L", socketLabel, "send-keys", "-t", paneTarget(handle), "Enter"]
    }

    public static func hasSessionArguments(socketLabel: String, handle: String) -> [String] {
        ["tmux", "-L", socketLabel, "has-session", "-t", "=\(handle)"]
    }

    /// The pane every session verb addresses: the active pane of the exactly-named
    /// session's current window. `=` forces the exact session match `has-session`
    /// already uses; the trailing colon is what makes the string a *pane* target —
    /// `-t =name` alone is a session target and `capture-pane` rejects it.
    static func paneTarget(_ handle: String) -> String {
        "=\(handle):"
    }

    /// Drops the trailing blank rows `capture-pane` pads to the pane's height, so a
    /// young session reads as the few lines it has produced rather than as those
    /// lines followed by a screenful of nothing.
    static func trimmingTrailingBlankLines(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Verbs

    public func isLive(handle: String) async -> Bool {
        let result = await run(
            "/usr/bin/env",
            Self.hasSessionArguments(socketLabel: socketLabel, handle: handle),
            environment
        )
        return result?.success == true
    }

    /// Starts a detached session and returns its handle. Fails closed when the
    /// handle is taken: `new-session` without `-A` would error anyway, and naming
    /// the live session is the answer a caller needs.
    @discardableResult
    public func launch(
        handle: String,
        directory: URL,
        command: String?
    ) async throws -> String {
        if await isLive(handle: handle) {
            throw ControlError.handleAlreadyLive(handle: handle)
        }
        guard
            let result = await run(
                "/usr/bin/env",
                Self.newSessionArguments(
                    socketLabel: socketLabel,
                    handle: handle,
                    directory: directory,
                    command: command
                ),
                environment
            )
        else {
            throw ControlError.tmuxUnavailable
        }
        guard result.success else {
            throw ControlError.commandFailed(verb: "new-session", handle: handle, stderr: result.stderr)
        }
        return handle
    }

    /// The session's scrollback, newest content last — the shape a person reading a
    /// terminal expects, and the shape `tail` already speaks.
    public func read(handle: String, lines: Int = TmuxSessionControl.defaultCaptureLines) async throws -> String {
        guard await isLive(handle: handle) else {
            throw ControlError.handleNotLive(handle: handle)
        }
        guard
            let result = await run(
                "/usr/bin/env",
                Self.capturePaneArguments(socketLabel: socketLabel, handle: handle, lines: lines),
                environment
            )
        else {
            throw ControlError.tmuxUnavailable
        }
        guard result.success else {
            throw ControlError.commandFailed(verb: "capture-pane", handle: handle, stderr: result.stderr)
        }
        return Self.trimmingTrailingBlankLines(result.stdout)
    }

    /// Types `text` into the session, optionally submitting it. Returns the number
    /// of UTF-8 bytes written so a caller can tell a silent no-op from a delivery.
    @discardableResult
    public func send(handle: String, text: String, submit: Bool) async throws -> Int {
        guard await isLive(handle: handle) else {
            throw ControlError.handleNotLive(handle: handle)
        }
        guard
            let textResult = await run(
                "/usr/bin/env",
                Self.sendTextArguments(socketLabel: socketLabel, handle: handle, text: text),
                environment
            )
        else {
            throw ControlError.tmuxUnavailable
        }
        guard textResult.success else {
            throw ControlError.commandFailed(verb: "send-keys", handle: handle, stderr: textResult.stderr)
        }
        if submit {
            guard
                let enterResult = await run(
                    "/usr/bin/env",
                    Self.sendEnterArguments(socketLabel: socketLabel, handle: handle),
                    environment
                )
            else {
                throw ControlError.tmuxUnavailable
            }
            guard enterResult.success else {
                throw ControlError.commandFailed(verb: "send-keys Enter", handle: handle, stderr: enterResult.stderr)
            }
        }
        return text.utf8.count
    }

    /// Production runner: `ProcessRunner.run` with the same short deadline the
    /// probe uses, so a wedged tmux server surfaces as no answer instead of a
    /// stalled CLI.
    public static let defaultRunner: CommandRunner = { executable, arguments, environment in
        do {
            return try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: 5
            )
        } catch {
            return nil
        }
    }
}

// MARK: - Verb results

/// `workspaces ws launch --json`. `canonicalForWorkspace` distinguishes the
/// workspace's own session name — the one the app's workspace terminal attaches to
/// when it runs in tmux-per-session mode — from a `--name` sibling, which nothing
/// but this handle reaches.
public struct WorkspaceLaunchResult: Codable, Sendable, Equatable {
    public let handle: String
    public let workspace: String
    public let workspaceID: UUID
    public let path: String
    public let command: String?
    public let socketLabel: String
    public let canonicalForWorkspace: Bool

    public init(
        handle: String,
        workspace: String,
        workspaceID: UUID,
        path: String,
        command: String?,
        socketLabel: String,
        canonicalForWorkspace: Bool
    ) {
        self.handle = handle
        self.workspace = workspace
        self.workspaceID = workspaceID
        self.path = path
        self.command = command
        self.socketLabel = socketLabel
        self.canonicalForWorkspace = canonicalForWorkspace
    }
}

/// `workspaces ws read --json`. `lines` is what was asked for, not what came back:
/// a young session has less scrollback than the bound, and the difference is the
/// caller's to notice.
public struct WorkspaceReadResult: Codable, Sendable, Equatable {
    public let handle: String
    public let socketLabel: String
    public let lines: Int
    public let text: String

    public init(handle: String, socketLabel: String, lines: Int, text: String) {
        self.handle = handle
        self.socketLabel = socketLabel
        self.lines = lines
        self.text = text
    }
}

/// `workspaces ws send --json`. `bytes` is the UTF-8 length actually written, so a
/// caller can tell delivery from a silent no-op.
public struct WorkspaceSendResult: Codable, Sendable, Equatable {
    public let handle: String
    public let socketLabel: String
    public let bytes: Int
    public let submitted: Bool

    public init(handle: String, socketLabel: String, bytes: Int, submitted: Bool) {
        self.handle = handle
        self.socketLabel = socketLabel
        self.bytes = bytes
        self.submitted = submitted
    }
}
