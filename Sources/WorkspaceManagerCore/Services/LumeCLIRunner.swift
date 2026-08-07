//
//  LumeCLIRunner.swift
//  WorkspaceManagerCore
//
//  Shared subprocess execution for the local `lume` CLI.
//

import Foundation

struct LumeCLIStreamingResult: Sendable {
    let exitCode: Int32
    let transcript: String
}

struct LumeCLIRunner: Sendable {
    let executablePath: String
    let currentDirectory: URL
    let environment: [String: String]

    init(
        executablePath: String,
        currentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = Self.defaultEnvironment()
    ) {
        self.executablePath = executablePath
        self.currentDirectory = currentDirectory
        self.environment = environment
    }

    func run(arguments: [String]) async throws -> ProcessResult {
        // Un-timed by design: lume operations (image pulls, VM lifecycle) are
        // long-running and bounded by the caller's outer deadline
        // (scripts/check-subprocess-timeouts.py allowlist).
        try await ProcessRunner.run(
            executable: executablePath,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment
        )
    }

    func runStreaming(
        arguments: [String],
        onLine: @escaping @Sendable (String) async -> Void
    ) async throws -> LumeCLIStreamingResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let outputHandle = outputPipe.fileHandleForReading
        var transcriptLines: [String] = []

        try process.run()
        defer {
            try? outputHandle.close()
        }

        for try await line in outputHandle.bytes.lines {
            transcriptLines.append(line)
            await onLine(line)
        }

        process.waitUntilExit()
        return LumeCLIStreamingResult(
            exitCode: process.terminationStatus,
            transcript: transcriptLines.joined(separator: "\n")
        )
    }

    func launchDetached(arguments: [String], logURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: logURL.path) {
            _ = fileManager.createFile(atPath: logURL.path, contents: nil)
        }

        let logHandle = try FileHandle(forWritingTo: logURL)
        let nullInputHandle = FileHandle(forReadingAtPath: "/dev/null")
        defer {
            try? logHandle.close()
            try? nullInputHandle?.close()
        }

        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardInput = nullInputHandle
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            throw LumeCLIRunnerError.launchFailed(
                "Failed to launch detached Lume process: \(error.localizedDescription)"
            )
        }
    }

    private static func defaultEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if environment["TERM"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            environment["TERM"] = "xterm-256color"
        }
        return environment
    }
}

enum LumeCLIRunnerError: LocalizedError, Sendable {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return message
        }
    }
}
