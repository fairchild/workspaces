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

public actor DaytonaBackend: ProvisionCapable, StartStopCapable, Archivable, Listable {
    public nonisolated static let identifier = "daytona"
    public static let shared = DaytonaBackend()

    public nonisolated var identifier: String { Self.identifier }
    public nonisolated var runtimeCapabilities: RuntimeCapabilities {
        RuntimeCapabilities(
            supportsCreate: true,
            supportsDelete: true,
            supportsStartStop: true,
            supportsArchive: true,
            supportsList: true
        )
    }

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

    public func healthCheck() async -> Bool {
        guard ProcessInfo.processInfo.environment["DAYTONA_API_KEY"] != nil else {
            return false
        }
        return resolveUV() != nil
    }

    // MARK: - Sandbox Lifecycle

    public func openSession(for request: RemoteWorkspaceSessionRequest) async throws -> RemoteSandboxInfo {
        guard let sandboxId = request.remoteId?.trimmingCharacters(in: .whitespacesAndNewlines), !sandboxId.isEmpty
        else {
            throw RemoteWorkspaceError.missingRemoteIdentifier
        }

        switch request.status {
        case .active:
            return try await resolveCommand(sandboxId: sandboxId)
        case .stopped, .archived:
            return try await startSandbox(sandboxId: sandboxId)
        case .provisioning:
            throw RemoteWorkspaceError.commandFailed(
                "Workspace '\(request.name)' is still provisioning."
            )
        }
    }

    public func createSandbox(name: String, cloneURL: String? = nil) async throws -> RemoteSandboxInfo {
        var args = ["create", "--name", name]
        if let url = cloneURL {
            args += ["--clone-url", url]
        }
        return try await runCommand(args)
    }

    public func resolveCommand(sandboxId: String) async throws -> RemoteSandboxInfo {
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
        guard let uvPath = resolveUV() else {
            throw DaytonaError.uvNotFound
        }

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

    private func resolveUV() -> String? {
        let candidates = [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        let fallbackPath =
            ProcessInfo.processInfo.environment["PATH"]
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in fallbackPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("uv").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
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
