//
//  LocalBackend.swift
//  WorkspaceManager
//
//  Local workspace backend - no isolation, runs directly on host
//

import Foundation

public actor LocalBackend {
    public static let identifier = "local"
    public static let displayName = "Local (No Isolation)"
    public static let description = "Runs directly on your Mac. Fastest option but no isolation."

    private var terminals: [UUID: LocalTerminal] = [:]

    public init() {}

    public static func isAvailable() async -> Bool {
        true
    }

    public func initialize(workspace: Workspace) async throws {
        try FileManager.default.createDirectory(
            at: workspace.workspaceURL,
            withIntermediateDirectories: true
        )
    }

    public func start(workspace: Workspace) async throws {
        // Nothing to do for local backend
    }

    public func stop(workspace: Workspace) async throws {
        terminals[workspace.id]?.close()
        terminals.removeValue(forKey: workspace.id)
    }

    public func destroy(workspace: Workspace) async throws {
        try await stop(workspace: workspace)
    }

    public func isRunning(workspace: Workspace) async -> Bool {
        true
    }

    public func execute(
        command: [String],
        in workspace: Workspace,
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) async throws -> ProcessResult {
        guard !command.isEmpty else {
            throw BackendError.executionFailed("Empty command")
        }

        // Find executable
        let executableURL: URL
        if command[0].hasPrefix("/") {
            executableURL = URL(fileURLWithPath: command[0])
        } else {
            let resolvedPath = try await resolveExecutable(command[0])
            executableURL = URL(fileURLWithPath: resolvedPath)
        }

        let workDir: URL
        if let dir = workingDirectory {
            workDir = workspace.workspaceURL.appendingPathComponent(dir)
        } else {
            workDir = workspace.workspaceURL
        }

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }

        return try await ProcessRunner.run(
            executable: executableURL.path,
            arguments: Array(command.dropFirst()),
            currentDirectory: workDir,
            environment: env
        )
    }

    public func createTerminal(for workspace: Workspace) async throws -> LocalTerminal {
        let terminal = try LocalTerminal(workingDirectory: workspace.workspaceURL)
        terminals[workspace.id] = terminal
        return terminal
    }

    public func hostPath(for workspace: Workspace) -> URL? {
        workspace.workspaceURL
    }

    // MARK: - Private

    private func resolveExecutable(_ name: String) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/which",
            arguments: [name]
        )

        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.success, !path.isEmpty {
            return path
        }

        let fallbackPath =
            ProcessInfo.processInfo.environment["PATH"]
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in fallbackPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        throw BackendError.commandNotFound(name)
    }
}
