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

        let process = Process()

        // Find executable
        if command[0].hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: command[0])
        } else {
            let whichProcess = Process()
            whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            whichProcess.arguments = [command[0]]
            let pipe = Pipe()
            whichProcess.standardOutput = pipe
            try whichProcess.run()
            whichProcess.waitUntilExit()

            let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let execPath = path, !execPath.isEmpty else {
                throw BackendError.commandNotFound(command[0])
            }
            process.executableURL = URL(fileURLWithPath: execPath)
        }

        process.arguments = Array(command.dropFirst())

        if let workDir = workingDirectory {
            process.currentDirectoryURL = workspace.workspaceURL.appendingPathComponent(workDir)
        } else {
            process.currentDirectoryURL = workspace.workspaceURL
        }

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    public func createTerminal(for workspace: Workspace) async throws -> LocalTerminal {
        let terminal = LocalTerminal(workingDirectory: workspace.workspaceURL)
        terminals[workspace.id] = terminal
        return terminal
    }

    public func hostPath(for workspace: Workspace) -> URL? {
        workspace.workspaceURL
    }
}
