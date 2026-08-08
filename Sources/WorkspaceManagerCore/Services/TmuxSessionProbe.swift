//
//  TmuxSessionProbe.swift
//  WorkspaceManagerCore
//
//  Asks the installed tmux what the app needs to know before it launches: whether
//  a deterministic Workspaces session is still alive on the dedicated
//  `-L workspaces` socket (so cold-start restore can reattach instead of
//  relaunching), what its active pane is running, and which command flags this
//  tmux understands. Command execution is injected so every answer is unit-testable
//  without a real tmux server.
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

    /// Same contract as `OutputCommandRunner`, without the suspension point.
    /// A terminal surface composes its launch command synchronously, so the
    /// capability question that command's shape depends on has to be answerable
    /// without awaiting.
    public typealias SynchronousOutputRunner =
        @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]?) -> String?

    private let run: CommandRunner
    private let runForOutput: OutputCommandRunner
    private let runSynchronouslyForOutput: SynchronousOutputRunner
    private let environment: [String: String]

    public init(
        run: @escaping CommandRunner = TmuxSessionProbe.defaultRunner,
        runForOutput: @escaping OutputCommandRunner = TmuxSessionProbe.defaultOutputRunner,
        runSynchronouslyForOutput: @escaping SynchronousOutputRunner =
            TmuxSessionProbe.defaultSynchronousOutputRunner,
        environment: [String: String] = TmuxSessionProbe.defaultEnvironment
    ) {
        self.run = run
        self.runForOutput = runForOutput
        self.runSynchronouslyForOutput = runSynchronouslyForOutput
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

    /// First release whose `new-session` accepts `-e KEY=VALUE`. Older tmux rejects
    /// the flag outright, so a launch that emits it there loses the whole pane.
    public static let sessionEnvironmentFlagVersion = (major: 3, minor: 2)

    /// The installed tmux's `major.minor`, or `nil` when tmux is absent, wedged, or
    /// prints a version line naming no number (`tmux master`). `tmux -V` answers
    /// from the binary and never contacts a server, so this is safe to run before
    /// deciding what to launch.
    public func version() -> (major: Int, minor: Int)? {
        Self.parseVersion(
            fromVersionOutput: runSynchronouslyForOutput(
                "/usr/bin/env",
                ["tmux", "-V"],
                environment
            ))
    }

    /// Whether the installed tmux understands `new-session -e`, which is how a
    /// launch gives a session its own environment *before* the created session's
    /// first pane spawns.
    ///
    /// An unreadable version reads as too old. The two failure modes are not
    /// symmetric: emitting the flag at a tmux that rejects it costs the whole pane,
    /// while assuming it is missing costs a freshly created session's first pane
    /// its seeded environment until a new shell starts there.
    public func supportsSessionEnvironmentFlag() -> Bool {
        Self.supportsSessionEnvironmentFlag(version: version())
    }

    public static func supportsSessionEnvironmentFlag(version: (major: Int, minor: Int)?) -> Bool {
        guard let version else { return false }
        let minimum = sessionEnvironmentFlagVersion
        return (version.major, version.minor) >= (minimum.major, minimum.minor)
    }

    /// Pulls `major.minor` out of a `tmux -V` line. tmux writes `tmux 3.5a`,
    /// `tmux next-3.6`, `tmux 3.2-rc3`; the first number-and-dot run wins, and a
    /// bare major (`tmux 3`) reads as `.0`.
    public static func parseVersion(fromVersionOutput output: String?) -> (major: Int, minor: Int)? {
        guard let output else { return nil }
        for candidate in output.split(whereSeparator: { !$0.isNumber && $0 != "." }) {
            let components = candidate.split(separator: ".", omittingEmptySubsequences: true)
            guard let major = components.first.flatMap({ Int($0) }) else { continue }
            let minor = components.count > 1 ? Int(components[1]) ?? 0 : 0
            return (major: major, minor: minor)
        }
        return nil
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

    /// Production synchronous runner: a bounded `Process` run yielding stdout on a
    /// zero exit. The watchdog kills the child at the deadline, which closes the
    /// pipe, so neither the read nor the wait is open-ended.
    public static let defaultSynchronousOutputRunner: SynchronousOutputRunner = { executable, arguments, environment in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A PATH value with the common Homebrew/system bin paths prepended (an absent
    /// or empty PATH still yields the tool paths). One resolution shared by the
    /// probe environment and the launch-time tmux gate, so a session the probe
    /// reports alive is one launch can also see tmux for.
    public static func pathPrependingToolPaths(_ existing: String?) -> String {
        let toolPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        guard let existing, !existing.isEmpty else { return toolPaths }
        return "\(toolPaths):\(existing)"
    }

    /// Process environment with the common Homebrew/system bin paths prepended so
    /// `/usr/bin/env tmux` resolves regardless of the launch PATH.
    public static let defaultEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = pathPrependingToolPaths(environment["PATH"])
        return environment
    }()
}
