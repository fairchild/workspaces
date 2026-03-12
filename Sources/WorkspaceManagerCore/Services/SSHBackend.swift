//
//  SSHBackend.swift
//  WorkspaceManagerCore
//
//  Non-managed SSH remote workspace backend with optional Docker Compose overlay.
//

import Foundation

public struct SSHSessionPlan: Sendable, Equatable {
    public let remoteId: String
    public let workingDirectory: String
    public let bootstrapArguments: [String]
    public let interactiveCommand: String

    public init(
        remoteId: String,
        workingDirectory: String,
        bootstrapArguments: [String],
        interactiveCommand: String
    ) {
        self.remoteId = remoteId
        self.workingDirectory = workingDirectory
        self.bootstrapArguments = bootstrapArguments
        self.interactiveCommand = interactiveCommand
    }
}

public actor SSHBackend: RemoteBackendProtocol {
    public typealias CommandRunner =
        @Sendable (_ executable: String, _ arguments: [String]) async throws -> ProcessResult

    public nonisolated static let identifier = "ssh"
    public static let shared = SSHBackend()

    public nonisolated var identifier: String { Self.identifier }
    public nonisolated var runtimeCapabilities: RuntimeCapabilities {
        RuntimeCapabilities(
            supportsCompose: true
        )
    }

    private let runCommand: CommandRunner

    public init(
        runCommand: CommandRunner? = nil
    ) {
        self.runCommand =
            runCommand
            ?? { executable, arguments in
                try await ProcessRunner.run(
                    executable: executable,
                    arguments: arguments,
                    environment: ProcessInfo.processInfo.environment
                )
            }
    }

    public func healthCheck() async -> Bool {
        Self.resolveExecutable(named: "ssh") != nil
    }

    public func openSession(for request: RemoteWorkspaceSessionRequest) async throws -> RemoteSandboxInfo {
        guard let sshExecutable = Self.resolveExecutable(named: "ssh") else {
            throw BackendError.commandNotFound("ssh")
        }

        let plan = try Self.sessionPlan(for: request, sshExecutable: sshExecutable)
        let bootstrap = try await runCommand(sshExecutable, plan.bootstrapArguments)
        guard bootstrap.success else {
            let stderr = bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = bootstrap.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = stderr.isEmpty ? stdout : stderr
            throw RemoteWorkspaceError.commandFailed(
                reason.isEmpty ? "SSH bootstrap exited with code \(bootstrap.exitCode)." : reason
            )
        }

        return RemoteSandboxInfo(
            sandboxId: plan.remoteId,
            sshCommand: plan.interactiveCommand
        )
    }

    static func sessionPlan(
        for request: RemoteWorkspaceSessionRequest,
        sshExecutable: String = "/usr/bin/ssh"
    ) throws -> SSHSessionPlan {
        guard let remoteId = request.remoteId?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteId.isEmpty
        else {
            throw RemoteWorkspaceError.missingRemoteIdentifier
        }

        guard let ssh = request.sshMetadata else {
            throw RemoteWorkspaceError.missingSSHMetadata
        }
        guard (1...65535).contains(ssh.port) else {
            throw RemoteWorkspaceError.invalidSSHConfiguration(
                "port must be between 1 and 65535"
            )
        }

        guard
            let remoteURL = request.repoRemoteURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !remoteURL.isEmpty
        else {
            throw RemoteWorkspaceError.missingRemoteURL
        }

        let workingDirectory = resolvedWorkingDirectory(for: request, ssh: ssh)
        let bootstrapScript = try bootstrapScript(
            workingDirectory: workingDirectory,
            remoteURL: remoteURL,
            compose: request.composeMetadata
        )
        let interactiveScript = try interactiveScript(
            workingDirectory: workingDirectory,
            compose: request.composeMetadata
        )
        let sshOptions = sshOptionArguments(for: ssh)
        let destination = connectionTarget(for: ssh)

        return SSHSessionPlan(
            remoteId: remoteId,
            workingDirectory: workingDirectory,
            bootstrapArguments: sshOptions + [destination, "sh", "-lc", bootstrapScript],
            interactiveCommand: ([sshExecutable] + sshOptions + ["-t", destination, "sh", "-lc", interactiveScript])
                .map(shellQuoted)
                .joined(separator: " ")
        )
    }

    static func resolvedWorkingDirectory(
        for request: RemoteWorkspaceSessionRequest,
        ssh: SSHWorkspaceMetadata
    ) -> String {
        if let configured = ssh.workingDir?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            return configured
        }

        let resolvedRepoName = sanitizedDefaultPathComponent(
            request.repoName,
            fallback: "repo"
        )
        let resolvedWorkspaceName = sanitizedDefaultPathComponent(
            request.name,
            fallback: "workspace"
        )
        return "~/workspaces/\(resolvedRepoName)/\(resolvedWorkspaceName)"
    }

    private static func bootstrapScript(
        workingDirectory: String,
        remoteURL: String,
        compose: ComposeWorkspaceMetadata?
    ) throws -> String {
        let shellWorkingDirectory = shellPath(workingDirectory)
        let shellGitDirectory = shellPath("\(workingDirectory)/.git")

        var commands = [
            "set -e",
            "mkdir -p \(shellWorkingDirectory)",
            "if [ ! -d \(shellGitDirectory) ]; then git clone \(singleQuoted(remoteURL)) \(shellWorkingDirectory); fi",
        ]

        if let compose {
            let composeDirectory = composeProjectDirectory(compose: compose, workingDirectory: workingDirectory)
            let composeCommand = try composeCommandString(compose: compose)
            commands.append("cd \(shellPath(composeDirectory))")
            commands.append("\(composeCommand) config >/dev/null")
            commands.append("\(composeCommand) up -d")
        }

        return commands.joined(separator: "; ")
    }

    private static func interactiveScript(
        workingDirectory: String,
        compose: ComposeWorkspaceMetadata?
    ) throws -> String {
        if let compose {
            let composeDirectory = composeProjectDirectory(compose: compose, workingDirectory: workingDirectory)
            let composeCommand = try composeCommandString(compose: compose)
            return
                "cd \(shellPath(composeDirectory)) && exec \(composeCommand) exec "
                + "\(singleQuoted(compose.service)) ${SHELL:-/bin/bash} -l"
        }

        return "cd \(shellPath(workingDirectory)) && exec ${SHELL:-/bin/bash} -l"
    }

    private static func composeProjectDirectory(
        compose: ComposeWorkspaceMetadata,
        workingDirectory: String
    ) -> String {
        if let configured = compose.workdir?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            return configured
        }
        return workingDirectory
    }

    private static func composeCommandString(compose: ComposeWorkspaceMetadata) throws -> String {
        let composeFiles = compose.composeFiles.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !composeFiles.isEmpty else {
            throw RemoteWorkspaceError.invalidComposeConfiguration(
                "at least one compose file is required"
            )
        }

        let service = compose.service.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !service.isEmpty else {
            throw RemoteWorkspaceError.invalidComposeConfiguration(
                "a compose service is required"
            )
        }

        var parts = ["docker", "compose"]
        if let projectName = compose.projectName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !projectName.isEmpty {
            parts += ["-p", projectName]
        }
        for file in composeFiles {
            parts += ["-f", file]
        }

        return parts.map(shellQuoted).joined(separator: " ")
    }

    private static func sshOptionArguments(for ssh: SSHWorkspaceMetadata) -> [String] {
        [
            "-A",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-p", String(ssh.port),
        ]
    }

    private static func connectionTarget(for ssh: SSHWorkspaceMetadata) -> String {
        if let user = ssh.user?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty {
            return "\(user)@\(ssh.host)"
        }
        return ssh.host
    }

    private static func sanitizedDefaultPathComponent(
        _ value: String?,
        fallback: String
    ) -> String {
        guard let value else { return fallback }
        let sanitized = WorkspaceService.sanitizeWorkspaceNameComponent(
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard WorkspaceService.isValidWorkspaceNameComponent(sanitized) else {
            return fallback
        }
        return sanitized
    }

    private static func resolveExecutable(named name: String) -> String? {
        let candidates = [
            "/usr/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let path =
            ProcessInfo.processInfo.environment["PATH"]
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(name)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func shellQuoted(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }

        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/:~@"
        )
        if value.rangeOfCharacter(from: allowed.inverted) == nil {
            return value
        }

        return singleQuoted(value)
    }

    private static func singleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private static func shellPath(_ path: String) -> String {
        if path == "~" {
            return "$HOME"
        }

        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(1))
            return "$HOME" + singleQuoted(suffix)
        }

        return singleQuoted(path)
    }
}
