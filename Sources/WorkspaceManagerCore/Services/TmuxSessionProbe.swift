//
//  TmuxSessionProbe.swift
//  WorkspaceManagerCore
//
//  Probes whether a deterministic Workspaces tmux session is still alive on the
//  dedicated `-L workspaces` socket, so cold-start restore can reattach to a
//  surviving session instead of relaunching it. Command execution is injected so
//  the probe is unit-testable without a real tmux server.
//

import Foundation

public struct TmuxSessionProbe: Sendable {
    /// Matches the `-L workspaces` socket the app launches sessions on.
    public static let socketLabel = "workspaces"

    /// Runs a command and yields its exit code, or `nil` on launch failure/timeout.
    public typealias CommandRunner =
        @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]?) async -> Int32?

    /// Runs a command and yields its stdout on success, or `nil` on non-zero exit,
    /// launch failure, or timeout.
    public typealias OutputCommandRunner =
        @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]?) async -> String?

    private let run: CommandRunner
    private let runForOutput: OutputCommandRunner
    private let environment: [String: String]

    public init(
        run: @escaping CommandRunner = TmuxSessionProbe.defaultRunner,
        runForOutput: @escaping OutputCommandRunner = TmuxSessionProbe.defaultOutputRunner,
        environment: [String: String] = TmuxSessionProbe.defaultEnvironment
    ) {
        self.run = run
        self.runForOutput = runForOutput
        self.environment = environment
    }

    /// True when `tmux -L workspaces has-session -t =<name>` exits 0. The `=`
    /// prefix forces an exact match so a hash-suffixed name cannot prefix-match a
    /// different live session.
    public func isSessionAlive(_ tmuxSessionName: String) async -> Bool {
        let exitCode = await run(
            "/usr/bin/env",
            ["tmux", "-L", Self.socketLabel, "has-session", "-t", "=\(tmuxSessionName)"],
            environment
        )
        return exitCode == 0
    }

    /// The foreground command running in the session's active pane (its
    /// `pane_current_command`, e.g. `vim`, `python`, `zsh`), or `nil` when the
    /// session is not live or tmux is unavailable. Names what a plain terminal tab
    /// is actually running, which the terminal title only approximates. The `=`
    /// prefix forces an exact session-name match.
    public func foregroundCommand(forSessionNamed tmuxSessionName: String) async -> String? {
        let output = await runForOutput(
            "/usr/bin/env",
            [
                "tmux", "-L", Self.socketLabel, "list-panes",
                "-t", "=\(tmuxSessionName)",
                "-F", "#{pane_active} #{pane_current_command}",
            ],
            environment
        )
        return Self.parseForegroundCommand(fromListPanes: output)
    }

    /// Picks the foreground command from `tmux list-panes -F '#{pane_active}
    /// #{pane_current_command}'` output: the active pane wins; otherwise the first
    /// pane with a non-empty command. Returns `nil` for empty/absent output.
    static func parseForegroundCommand(fromListPanes output: String?) -> String? {
        guard let output else { return nil }
        var firstCommand: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let spaceIndex = line.firstIndex(of: " ") else { continue }
            let isActive = line[..<spaceIndex] == "1"
            let command = line[line.index(after: spaceIndex)...]
                .trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { continue }
            if isActive { return command }
            if firstCommand == nil { firstCommand = command }
        }
        return firstCommand
    }

    /// Kill an exactly-named session (`=` prefix, as in `isSessionAlive`) so a
    /// relaunch that carries an initial command cannot `new-session -A`-attach
    /// to a same-name survivor and silently drop the command. Restore uses this
    /// just before a resume launch: the planner only picks resume when the prior
    /// session is gone, so a live session with that name can only be an artifact
    /// of the current launch's seeding. Returns true when a session was killed.
    @discardableResult
    public func killSession(_ tmuxSessionName: String) async -> Bool {
        let exitCode = await run(
            "/usr/bin/env",
            ["tmux", "-L", Self.socketLabel, "kill-session", "-t", "=\(tmuxSessionName)"],
            environment
        )
        return exitCode == 0
    }

    /// Production runner: `ProcessRunner.run` with a short timeout so a wedged
    /// tmux server cannot stall restore; any throw maps to `nil` (not alive).
    public static let defaultRunner: CommandRunner = { executable, arguments, environment in
        do {
            let result = try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: 5
            )
            return result.exitCode
        } catch {
            return nil
        }
    }

    /// Production output runner: `ProcessRunner.run` with a short timeout; returns
    /// stdout only on success so a wedged/missing tmux server maps to `nil`.
    public static let defaultOutputRunner: OutputCommandRunner = { executable, arguments, environment in
        do {
            let result = try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: 5
            )
            return result.success ? result.stdout : nil
        } catch {
            return nil
        }
    }

    /// Process environment with the common Homebrew/system bin paths prepended so
    /// `/usr/bin/env tmux` resolves regardless of the launch PATH.
    public static let defaultEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        let toolPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let existing = environment["PATH"], !existing.isEmpty {
            environment["PATH"] = "\(toolPaths):\(existing)"
        } else {
            environment["PATH"] = toolPaths
        }
        return environment
    }()
}
