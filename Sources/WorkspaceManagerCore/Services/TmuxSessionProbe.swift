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

    private let run: CommandRunner
    private let environment: [String: String]

    public init(
        run: @escaping CommandRunner = TmuxSessionProbe.defaultRunner,
        environment: [String: String] = TmuxSessionProbe.defaultEnvironment
    ) {
        self.run = run
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
