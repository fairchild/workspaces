//
//  DaytonaBackend.swift
//  WorkspaceManager
//
//  Daytona remote VM backend — manages sandbox lifecycle via Python CLI helper.
//

import Foundation

public struct RemoteSandboxInfo: Decodable, Sendable {
    public let sandboxId: String
    public let sshCommand: String

    public init(sandboxId: String, sshCommand: String) {
        self.sandboxId = sandboxId
        self.sshCommand = sshCommand
    }
}

public struct RemoteSandboxStatus: Decodable, Sendable {
    public let sandboxId: String
    public let state: String
}

public actor DaytonaBackend: RemoteBackendProtocol {
    public static let shared = DaytonaBackend()

    public nonisolated var identifier: String { "daytona" }

    private let scriptPath: String

    public init() {
        // Resolve script path relative to the app bundle or fallback to known location
        let bundlePath = Bundle.main.bundlePath
        let appDir = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
        let candidates = [
            appDir.appendingPathComponent("scripts/daytona-sandbox-manager.py").path,
            // Development: script is in the repo
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Services/
                .deletingLastPathComponent()  // WorkspaceManagerCore/
                .deletingLastPathComponent()  // Sources/
                .deletingLastPathComponent()  // repo root
                .appendingPathComponent("scripts/daytona-sandbox-manager.py").path,
        ]

        self.scriptPath =
            candidates.first {
                FileManager.default.fileExists(atPath: $0)
            } ?? "scripts/daytona-sandbox-manager.py"
    }

    public func isAvailable() async -> Bool {
        (try? await resolveUV()) != nil
    }

    // MARK: - Sandbox Lifecycle

    public func createSandbox(name: String, cloneURL: String? = nil) async throws -> RemoteSandboxInfo {
        var args = ["create", "--name", name]
        if let url = cloneURL {
            args += ["--clone-url", url]
        }
        return try await runCommand(args)
    }

    public func getSSHCommand(sandboxId: String) async throws -> RemoteSandboxInfo {
        try await runCommand(["ssh-command", "--sandbox-id", sandboxId])
    }

    public func stopSandbox(sandboxId: String) async throws {
        let _: StopResponse = try await runCommand(["stop", "--sandbox-id", sandboxId])
    }

    public func startSandbox(sandboxId: String) async throws -> RemoteSandboxInfo {
        try await runCommand(["start", "--sandbox-id", sandboxId])
    }

    public func archiveSandbox(sandboxId: String) async throws {
        let _: ArchiveResponse = try await runCommand(["archive", "--sandbox-id", sandboxId])
    }

    public func deleteSandbox(sandboxId: String) async throws {
        let _: DeleteResponse = try await runCommand(["delete", "--sandbox-id", sandboxId])
    }

    public func listSandboxes() async throws -> [RemoteSandboxStatus] {
        try await runCommand(["list"])
    }

    // MARK: - Private

    private func runCommand<T: Decodable>(_ args: [String]) async throws -> T {
        let uvPath = try await resolveUV()

        let result = try await ProcessRunner.run(
            executable: uvPath,
            arguments: ["run", "--script", scriptPath] + args,
            environment: ProcessInfo.processInfo.environment
        )

        guard result.success else {
            let errorMsg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DaytonaError.commandFailed(errorMsg.isEmpty ? "Exit code \(result.exitCode)" : errorMsg)
        }

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = stdout.data(using: .utf8) else {
            throw DaytonaError.invalidResponse("Empty response")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private func resolveUV() async throws -> String {
        let candidates = [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        let result = try await ProcessRunner.run(
            executable: "/usr/bin/which",
            arguments: ["uv"]
        )
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.success, !path.isEmpty else {
            throw DaytonaError.uvNotFound
        }
        return path
    }
}

// MARK: - Internal Response Types

private struct StopResponse: Decodable {
    let stopped: Bool
}

private struct ArchiveResponse: Decodable {
    let archived: Bool
}

private struct DeleteResponse: Decodable {
    let deleted: Bool
}

// MARK: - Errors

public enum DaytonaError: LocalizedError {
    case uvNotFound
    case commandFailed(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .uvNotFound:
            return "uv is required for Daytona backend but was not found"
        case .commandFailed(let reason):
            return "Daytona command failed: \(reason)"
        case .invalidResponse(let reason):
            return "Invalid response from Daytona: \(reason)"
        }
    }
}
