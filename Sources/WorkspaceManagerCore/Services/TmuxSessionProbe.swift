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
    /// The `-L` socket the app launches sessions on when nothing overrides it.
    public static let defaultSocketLabel = "workspaces"

    /// Names a socket for a run that must not touch the desktop's server. The CLI
    /// already honored this (`TmuxSessionControl`); the app honors it too, so the
    /// whole tmux lane — launch script, probe, and every kill — can be exercised
    /// against an isolated server instead of the shared one this app's users keep
    /// live sessions on (#1267).
    public static let socketLabelEnvironmentKey = "WORKSPACES_TMUX_SOCKET_LABEL"

    /// Where a run lands when it asked for an isolated socket and named one this app
    /// will not use. Never the shared socket: the request itself is the signal that
    /// nothing here should touch the desktop's sessions.
    public static let quarantineSocketLabel = "workspaces-rejected-label"

    /// Resolves the socket label from a launch environment.
    ///
    /// Three cases, and the third is the one worth reading. No override at all means
    /// the app's own server. An override that is blank after trimming reads as unset,
    /// not as a nameless socket — a variable someone cleared is a variable they are not
    /// using. But an override that is *present and unusable* is an operator who asked
    /// for isolation and mistyped it, and answering that with the shared socket would
    /// point a run that was trying to stay away from the desktop's live sessions
    /// straight at them. That request is honoured with a socket that is definitely not
    /// the shared one, so the mistake costs an empty server rather than someone's work.
    public static func resolvedSocketLabel(from environment: [String: String]) -> String {
        guard
            let override = environment[socketLabelEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        else {
            return defaultSocketLabel
        }
        return isSafeSocketLabel(override) ? override : quarantineSocketLabel
    }

    /// Whether `value` is a socket label this app is willing to use.
    ///
    /// A label reaches two very different places: an argv slot in this file's own
    /// commands, where anything is safe, and — through
    /// `GhosttyTerminalConfig.tmuxLaunchScript` — the *text of a shell script* a
    /// terminal execs, where it is not. Making the label configurable is what put a
    /// value someone else chooses on that second path, so it is checked at the one
    /// place it enters the app rather than quoted at each place it leaves.
    ///
    /// A whitelist rather than an escape, because the set is small and known: tmux
    /// makes the label a filename in its socket directory, so a legitimate one needs
    /// letters, digits, and a little punctuation. Anything else is a mistake or an
    /// attempt, and both are better answered with the default socket than with a
    /// faithful reproduction of the input.
    public static func isSafeSocketLabel(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber
                    || character == "-" || character == "_" || character == ".")
        }
    }

    /// The socket every command in this file carries, resolved once from the launch
    /// environment. Reading `ProcessInfo` here is the same cheap dictionary lookup
    /// `defaultEnvironment` already makes from a static initializer; it starts no
    /// run loop, so the `swift_once` re-entrancy hazard `synchronousOutput`
    /// documents does not apply.
    public static let socketLabel = resolvedSocketLabel(from: ProcessInfo.processInfo.environment)

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
    /// without awaiting. An implementation blocks the calling thread and leaves
    /// its run loop alone — see `defaultSynchronousOutputRunner` for why that
    /// second half is load-bearing.
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

    /// True when `tmux has-session -t =<name>` exits 0 on the resolved socket. The `=`
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

    /// True when the tmux binary itself answers. Distinguishes "tmux says no such
    /// session" from "tmux never answered", which `isSessionAlive` alone cannot: it
    /// collapses a timeout, a launch failure, and a real absent session into one
    /// `false`. A caller about to act on absence has to know which it got.
    public func isCommandAvailable() async -> Bool {
        await runForOutput("/usr/bin/env", ["tmux", "-V"], environment) != nil
    }

    /// How many clients are attached to `tmuxSessionName`, or `nil` when tmux did
    /// not answer — a failed command, a missing binary, or a session that is not
    /// there to have clients.
    ///
    /// This is restore's launch-contract signal (#1478). A tmux-mode surface execs
    /// `new-session -A`, which must leave the session live *and* attached, so a
    /// confirmed zero means the surface never ran its launch command. The `nil` is
    /// load-bearing: a caller that repairs on "not attached" would, on a transient
    /// probe failure, type a shell command into a pane that is actually attached and
    /// running an agent. Unknown must never be read as zero.
    public func attachedClientCount(forSessionNamed tmuxSessionName: String) async -> Int? {
        let output = await runForOutput(
            "/usr/bin/env",
            [
                "tmux", "-L", Self.socketLabel, "list-clients",
                "-t", "=\(tmuxSessionName)",
                "-F", "#{client_name}",
            ],
            environment
        )
        return Self.parseAttachedClientCount(fromListClients: output)
    }

    /// Counts non-empty lines of `tmux list-clients -F '#{client_name}'` output.
    /// Empty output is a real zero (a live session nobody is attached to); `nil`
    /// output is "tmux did not answer" and stays `nil`.
    static func parseAttachedClientCount(fromListClients output: String?) -> Int? {
        guard let output else { return nil }
        return
            output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
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

    /// The name of the one live session with a pane whose current working directory is
    /// `directoryPath`, or `nil` when zero or more than one session matches. Every pane of
    /// every session is scanned, not just each session's first — a match anywhere in a session
    /// is enough to name it.
    ///
    /// Adopting a worktree the app did not create (#1390) needs this because such a session was
    /// never named by the app's own deterministic derivation (`wm-<dir>-<hash>`) — it could be
    /// anything, e.g. a session a person or another tool started by hand. Matching on the live
    /// working directory is the only signal that ties an arbitrary session name back to a
    /// specific worktree. More than one match is deliberately treated as "no answer": guessing
    /// wrong would bind the workspace to the wrong session's live shell, so ambiguity falls back
    /// to a fresh one instead of picking either candidate.
    public func sessionName(withCurrentDirectory directoryPath: String) async -> String? {
        let output = await runForOutput(
            "/usr/bin/env",
            [
                "tmux", "-L", Self.socketLabel, "list-panes", "-a",
                "-F", "#{session_name}\t#{pane_current_path}",
            ],
            environment
        )
        return Self.parseSessionName(fromListPanes: output, matchingDirectory: directoryPath)
    }

    /// Picks the session name from `tmux list-panes -a -F '#{session_name}\t#{pane_current_path}'`
    /// output whose pane directory resolves to the same path as `directoryPath`, symlinks
    /// resolved on both sides so a worktree reached through a symlinked parent still matches.
    /// Returns `nil` for no match or more than one distinct session matching.
    static func parseSessionName(
        fromListPanes output: String?,
        matchingDirectory directoryPath: String
    ) -> String? {
        guard let output else { return nil }
        let target = normalizedPath(directoryPath)
        var matchedSessionNames: Set<String> = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let sessionName = fields[0].trimmingCharacters(in: .whitespaces)
            let paneDirectory = fields[1].trimmingCharacters(in: .whitespaces)
            guard !sessionName.isEmpty, !paneDirectory.isEmpty else { continue }
            if normalizedPath(paneDirectory) == target {
                matchedSessionNames.insert(sessionName)
            }
        }
        return matchedSessionNames.count == 1 ? matchedSessionNames.first : nil
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Every session live on the socket, or `nil` when tmux did not answer. Read
    /// only: it enumerates so a caller can *attribute* a name, and nothing here
    /// acts on what it finds.
    ///
    /// This is the lookup a kill resolves through, and it is deliberately taken
    /// fresh at kill time rather than remembered from plan time: a name can change
    /// hands between the two, which is the narrower version of the same defect
    /// killing by name has.
    public func liveSessions() async -> [TmuxLiveSession]? {
        let output = await runForOutput(
            "/usr/bin/env",
            [
                "tmux", "-L", Self.socketLabel, "list-sessions",
                "-F", "#{session_id}\t#{session_name}\t#{session_created}\t#{pid}",
            ],
            environment
        )
        return Self.parseLiveSessions(fromListSessions: output)
    }

    /// Parses `list-sessions -F '#{session_id}\t#{session_name}\t#{session_created}\t#{pid}'`.
    /// A socket with no server answers non-zero, which the runner maps to `nil`; a
    /// server with no sessions cannot exist, so empty output also reads as no answer
    /// only when the runner said so — an empty string parses to an empty list.
    /// Malformed rows are skipped rather than failing the whole read.
    static func parseLiveSessions(fromListSessions output: String?) -> [TmuxLiveSession]? {
        guard let output else { return nil }
        var sessions: [TmuxLiveSession] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let sessionID = fields[0].trimmingCharacters(in: .whitespaces)
            let name = String(fields[1])
            guard TmuxLiveSession.isWellFormedSessionID(sessionID), !name.isEmpty else { continue }
            guard let createdEpoch = Double(fields[2].trimmingCharacters(in: .whitespaces)) else { continue }
            let serverPID = fields.count >= 4 ? Int(fields[3].trimmingCharacters(in: .whitespaces)) : nil
            sessions.append(
                TmuxLiveSession(
                    sessionID: sessionID,
                    name: name,
                    createdAt: Date(timeIntervalSince1970: createdEpoch),
                    serverPID: serverPID
                )
            )
        }
        return sessions
    }

    /// Kill the one session tmux assigned `sessionID` (`$3`), whoever holds its name.
    ///
    /// A session id is the only handle on this socket a second party cannot arrive at
    /// by accident: names here are directory derivations, so two tools working in one
    /// directory agree on a name without ever agreeing on a session. tmux never reuses
    /// an id within a server's lifetime, which also closes the window where a session
    /// exits and something else takes its name between the decision and the kill.
    ///
    /// A malformed id is refused rather than passed through, because tmux reads a
    /// missing or empty `-t` as *the current session* and kills it with exit 0 —
    /// verified on an isolated socket. The one input that must never reach `kill-session`
    /// is the one an optional collapses to.
    @discardableResult
    public func killSession(id sessionID: String) async -> Bool {
        guard TmuxLiveSession.isWellFormedSessionID(sessionID) else { return false }
        let exitCode = await run(
            "/usr/bin/env",
            ["tmux", "-L", Self.socketLabel, "kill-session", "-t", sessionID],
            environment
        )
        return exitCode == 0
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

    /// Production synchronous runner: `synchronousOutput` at the standard deadline.
    public static let defaultSynchronousOutputRunner: SynchronousOutputRunner = { executable, arguments, environment in
        synchronousOutput(executable: executable, arguments: arguments, environment: environment)
    }

    /// Scores a run against its deadline: true when the child exited before it.
    /// Production waits on the child's own termination semaphore; the seam is a
    /// parameter so the deadline-exceeded verdict can be driven without racing a
    /// real deadline.
    typealias ExitWaiter = @Sendable (DispatchSemaphore, TimeInterval) -> Bool

    static let defaultExitWaiter: ExitWaiter = { exited, timeout in
        exited.wait(timeout: .now() + timeout) == .success
    }

    /// How long a synchronous run may take before its child is killed and the run
    /// scored as no answer. It bounds a main-thread stall, so it is short.
    static let synchronousRunTimeout: TimeInterval = 5

    /// A bounded `Process` run yielding stdout on a zero exit. The watchdog kills the
    /// child at the deadline and the exit wait carries the same deadline; the read
    /// ends when the last writer closes the pipe, which for a `tmux -V` child — it
    /// forks nothing — is that kill. A run whose child outlives the deadline yields
    /// no answer: whatever reached the pipe is not a version this tmux stands behind,
    /// and `terminationStatus` is only defined once the child has exited.
    ///
    /// It blocks the calling thread outright and never runs that thread's run loop.
    /// Callers reach this from inside a lazy static initializer on the main thread —
    /// a `swift_once` — and running the main run loop there re-enters AppKit: a
    /// nested SwiftUI layout pass composes another terminal surface, re-enters the
    /// same `swift_once`, and libdispatch traps the recursive lock. Hence the
    /// termination semaphore rather than `Process.waitUntilExit()`, which runs the
    /// caller's run loop by design.
    static func synchronousOutput(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval = TmuxSessionProbe.synchronousRunTimeout,
        awaitExit: ExitWaiter = TmuxSessionProbe.defaultExitWaiter
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Signalled from Process's own queue, so waiting on it parks this thread
        // instead of servicing it. Captures only the semaphore: the process is the
        // handler's parameter, so the handler cannot retain the process it belongs to.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let exitedBeforeDeadline = awaitExit(exited, timeout)
        watchdog.cancel()

        // `terminationStatus` is only defined once the child has exited, which the
        // wait is what establishes.
        guard exitedBeforeDeadline, process.terminationStatus == 0 else { return nil }
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
