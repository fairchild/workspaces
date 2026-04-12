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

    public func initialize(workspace: LocalWorkspaceContext) async throws {
        try FileManager.default.createDirectory(
            at: workspace.directoryURL,
            withIntermediateDirectories: true
        )
    }

    public func start(workspace: LocalWorkspaceContext) async throws {
        // Nothing to do for local backend
    }

    public func stop(workspace: LocalWorkspaceContext) async throws {
        terminals[workspace.workspaceID]?.close()
        terminals.removeValue(forKey: workspace.workspaceID)
    }

    public func destroy(workspace: LocalWorkspaceContext) async throws {
        try await stop(workspace: workspace)
    }

    public func isRunning(workspace: LocalWorkspaceContext) async -> Bool {
        true
    }

    public func execute(
        command: [String],
        in workspace: LocalWorkspaceContext,
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
            workDir = workspace.directoryURL.appendingPathComponent(dir)
        } else {
            workDir = workspace.directoryURL
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

    public func createTerminal(for workspace: LocalWorkspaceContext) async throws -> LocalTerminal {
        let terminal = try LocalTerminal(workingDirectory: workspace.directoryURL)
        terminals[workspace.workspaceID] = terminal
        return terminal
    }

    public func hostPath(for workspace: LocalWorkspaceContext) -> URL? {
        workspace.directoryURL
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
