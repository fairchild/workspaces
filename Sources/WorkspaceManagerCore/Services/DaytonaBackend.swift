//
//  DaytonaBackend.swift
//  WorkspaceManager
//
//  Daytona remote VM backend — manages sandbox lifecycle via Python CLI helper.
//

import Foundation

public struct DaytonaSandboxInfo: Codable, Sendable {
    public let sandboxId: String
    public let sshCommand: String
    public let sshToken: String
    public let expiresAt: String
    public let homeDir: String?
    public let workDir: String?
    public let state: String

    enum CodingKeys: String, CodingKey {
        case sandboxId = "sandbox_id"
        case sshCommand = "ssh_command"
        case sshToken = "ssh_token"
        case expiresAt = "expires_at"
        case homeDir = "home_dir"
        case workDir = "work_dir"
        case state
    }
}

public actor DaytonaBackend: DaytonaBackendProtocol {
    public static let identifier = "daytona"
    public static let displayName = "Remote VM (Daytona)"
    public static let shared = DaytonaBackend()

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

        self.scriptPath = candidates.first {
            FileManager.default.fileExists(atPath: $0)
        } ?? "scripts/daytona-sandbox-manager.py"
    }

    public static func isAvailable() async -> Bool {
        let candidates = [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return true
            }
        }
        // Fallback to which (works in terminal-launched builds)
        let result = try? await ProcessRunner.run(
            executable: "/usr/bin/which",
            arguments: ["uv"]
        )
        return result?.success ?? false
    }

    // MARK: - Sandbox Lifecycle

    public func createSandbox(name: String, cloneURL: String? = nil) async throws -> DaytonaSandboxInfo {
        var args = ["create", "--name", name]
        if let url = cloneURL {
            args += ["--clone-url", url]
        }
        return try await runCommand(args)
    }

    public func getSSHCommand(sandboxId: String) async throws -> DaytonaSandboxInfo {
        try await runCommand(["ssh-command", "--sandbox-id", sandboxId])
    }

    public func deleteSandbox(sandboxId: String) async throws {
        let _: DeleteResponse = try await runCommand(["delete", "--sandbox-id", sandboxId])
    }

    // MARK: - Private

    private func runCommand<T: Decodable>(_ args: [String]) async throws -> T {
        let uvPath = try await resolveUV()

        let result = try await ProcessRunner.run(
            executable: uvPath,
            arguments: ["run", "--with", "daytona", scriptPath] + args,
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

        return try JSONDecoder().decode(T.self, from: data)
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

private struct DeleteResponse: Decodable {
    let deleted: Bool
    let sandboxId: String

    enum CodingKeys: String, CodingKey {
        case deleted
        case sandboxId = "sandbox_id"
    }
}

// MARK: - Errors

public enum DaytonaError: LocalizedError {
    case uvNotFound
    case commandFailed(String)
    case invalidResponse(String)
    case sandboxNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .uvNotFound:
            return "uv is required for Daytona backend but was not found"
        case .commandFailed(let reason):
            return "Daytona command failed: \(reason)"
        case .invalidResponse(let reason):
            return "Invalid response from Daytona: \(reason)"
        case .sandboxNotFound(let id):
            return "Sandbox not found: \(id)"
        }
    }
}
