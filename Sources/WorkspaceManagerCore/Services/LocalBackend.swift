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

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = Array(command.dropFirst())
            process.currentDirectoryURL = workDir
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { _ in
                continuation.resume(
                    returning: ProcessResult(
                        exitCode: process.terminationStatus,
                        stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                            ?? "",
                        stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                            ?? ""
                    ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
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
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [name]
            let pipe = Pipe()
            process.standardOutput = pipe

            process.terminationHandler = { _ in
                let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if let execPath = path, !execPath.isEmpty {
                    continuation.resume(returning: execPath)
                } else {
                    continuation.resume(throwing: BackendError.commandNotFound(name))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
