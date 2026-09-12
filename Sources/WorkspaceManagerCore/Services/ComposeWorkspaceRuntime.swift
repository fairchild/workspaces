//
//  ComposeWorkspaceRuntime.swift
//  WorkspaceManagerCore
//
//  Runs Docker Compose against a pinned local context and a host-owned template
//  snapshot. Repository files never supply host commands or Compose configuration.
//

import CryptoKit
import Foundation

public struct ComposeSandboxMetadata: Codable, Sendable, Equatable {
    public let version: Int
    public let projectName: String
    public let dockerContext: String
    public let dockerEndpoint: String
    public let hostPath: String
    public let configDirectory: String
    public let terminalService: String
    public let containerWorkingDirectory: String
    public let templateVersion: Int
    public let templateHashes: [String: String]

    public init(
        projectName: String,
        dockerContext: String,
        dockerEndpoint: String,
        hostPath: String,
        configDirectory: String,
        templateHashes: [String: String],
        version: Int = 1,
        templateVersion: Int = 1,
        terminalService: String = "agent",
        containerWorkingDirectory: String = "/workspace"
    ) {
        self.version = version
        self.projectName = projectName
        self.dockerContext = dockerContext
        self.dockerEndpoint = dockerEndpoint
        self.hostPath = hostPath
        self.configDirectory = configDirectory
        self.terminalService = terminalService
        self.containerWorkingDirectory = containerWorkingDirectory
        self.templateVersion = templateVersion
        self.templateHashes = templateHashes
    }
}

public struct ComposeSandboxCommand: Sendable {
    public let executable: String
    public let arguments: [String]
    public let currentDirectory: URL
    public let environment: [String: String]
    public let timeout: TimeInterval
}

public enum ComposeSandboxError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case invalidMetadata(String)
    case commandFailed(operation: String, exitCode: Int32)
    case incompleteCreation

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .invalidMetadata(let reason): return reason
        case .commandFailed(let operation, let exitCode):
            return "\(operation) failed (exit \(exitCode))."
        case .incompleteCreation:
            return "This Docker Compose workspace did not finish creation. Delete it and create it again."
        }
    }
}

public struct ComposeWorkspaceRuntime: Sendable {
    public typealias CommandRunner = @Sendable (ComposeSandboxCommand) async throws -> ProcessResult
    public static let templateFiles = ["compose.yaml", "Dockerfile", ".dockerignore"]
    public let runtimeRoot: URL
    public let executablePath: String

    private let templateDirectory: URL?
    private let requestedContext: String?
    private let runner: CommandRunner
    private let homeDirectory: URL

    public init(
        runtimeRoot: URL? = nil,
        templateDirectory: URL? = nil,
        executablePath: String? = nil,
        dockerContext: String? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        runner: CommandRunner? = nil
    ) {
        self.runtimeRoot = (runtimeRoot ?? Self.defaultRuntimeRoot).standardizedFileURL.resolvingSymlinksInPath()
        self.templateDirectory = templateDirectory
        self.executablePath = executablePath ?? Self.findDockerExecutable()
        self.requestedContext = dockerContext
        self.homeDirectory = homeDirectory
        self.runner =
            runner ?? { command in
                try await ProcessRunner.run(
                    executable: command.executable,
                    arguments: command.arguments,
                    currentDirectory: command.currentDirectory,
                    environment: command.environment,
                    timeout: command.timeout
                )
            }
    }

    public static var defaultRuntimeRoot: URL {
        if let syntheticRoot = SyntheticRunRoot.url() {
            return syntheticRoot.appendingPathComponent(".compose", isDirectory: true)
        }
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".workspacemanager")
        return support.appendingPathComponent("WorkspaceManager/ComposeSandboxes", isDirectory: true)
    }

    private static func findDockerExecutable() -> String {
        let candidates = [
            "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }

    /// Deliberately excludes inherited Docker, Compose, Git, agent, and credential variables.
    func cleanEnvironment(metadata: ComposeSandboxMetadata? = nil) -> [String: String] {
        var environment = [
            "HOME": homeDirectory.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "COMPOSE_DISABLE_ENV_FILE": "1",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        if let metadata {
            environment["WORKSPACE_DIR"] = metadata.hostPath
            environment["SANDBOX_IMAGE"] = "\(metadata.projectName)-agent:v\(metadata.templateVersion)"
        }
        return environment
    }

    public func checkedContext() async throws -> String {
        let context: String
        if let requestedContext {
            context = requestedContext
        } else {
            let result = try await runDocker(arguments: ["context", "show"], operation: "Read Docker context")
            context = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard Self.isSafeIdentifier(context) else {
            throw ComposeSandboxError.unavailable("Docker did not return a valid context name.")
        }
        _ = try await localEndpoint(context: context)
        try await checkDaemon(context: context)
        _ = try await runDocker(
            arguments: ["--context", context, "compose", "version", "--short"],
            operation: "Check Docker Compose"
        )
        return context
    }

    func localEndpoint(context: String) async throws -> String {
        let endpoint = try await runDocker(
            arguments: ["context", "inspect", context, "--format", "{{.Endpoints.docker.Host}}"],
            operation: "Inspect Docker context"
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.hasPrefix("unix:///"), endpoint.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ComposeSandboxError.unavailable("Docker Compose workspaces require a local Docker context.")
        }
        return endpoint
    }

    func checkDaemon(context: String) async throws {
        let result = try await runDocker(
            arguments: ["--context", context, "info", "--format", "{{.OSType}}"],
            operation: "Connect to Docker"
        )
        guard result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "linux" else {
            throw ComposeSandboxError.unavailable("Docker Compose workspaces require Linux containers.")
        }
    }

    func loadTemplate() throws -> [String: Data] {
        let directory: URL
        if let templateDirectory {
            directory = templateDirectory
        } else if let resources = Bundle.main.resourceURL,
            FileManager.default.fileExists(atPath: resources.appendingPathComponent("ComposeSandbox/compose.yaml").path)
        {
            directory = resources.appendingPathComponent("ComposeSandbox")
        } else {
            #if DEBUG
                directory = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("examples/compose-agent-sandbox")
            #else
                throw ComposeSandboxError.unavailable("The Docker Compose sandbox template is missing from the app.")
            #endif
        }
        return try Dictionary(
            uniqueKeysWithValues: Self.templateFiles.map { name in
                let file = directory.appendingPathComponent(name)
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
                    throw ComposeSandboxError.invalidMetadata("Sandbox template files must be regular files.")
                }
                return (name, try Data(contentsOf: file))
            })
    }

    static func hashes(for template: [String: Data]) -> [String: String] {
        template.mapValues { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    func installSnapshot(_ template: [String: Data], metadata: ComposeSandboxMetadata) throws {
        try validateMetadata(metadata)
        let directory = URL(fileURLWithPath: metadata.configDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        for name in Self.templateFiles {
            guard let data = template[name] else {
                throw ComposeSandboxError.invalidMetadata("Sandbox template is incomplete.")
            }
            let file = directory.appendingPathComponent(name)
            try data.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        }
        try JSONEncoder().encode(metadata).write(
            to: directory.appendingPathComponent("workspace.json"), options: .withoutOverwriting
        )
    }

    func validateMetadata(_ metadata: ComposeSandboxMetadata, workspacePath: String? = nil) throws {
        let suffix = String(metadata.projectName.dropFirst(3))
        guard metadata.version == 1, metadata.templateVersion == 1,
            metadata.projectName.hasPrefix("ws-"), UUID(uuidString: suffix) != nil,
            metadata.projectName == metadata.projectName.lowercased(),
            Self.isSafeIdentifier(metadata.dockerContext), metadata.terminalService == "agent",
            metadata.dockerEndpoint.hasPrefix("unix:///"),
            metadata.dockerEndpoint.rangeOfCharacter(from: .controlCharacters) == nil,
            metadata.containerWorkingDirectory == "/workspace",
            Set(metadata.templateHashes.keys) == Set(Self.templateFiles)
        else {
            throw ComposeSandboxError.invalidMetadata("Docker Compose workspace metadata is invalid or unsupported.")
        }
        let directory = URL(fileURLWithPath: metadata.configDirectory).standardizedFileURL.resolvingSymlinksInPath()
        let expected = runtimeRoot.appendingPathComponent(metadata.projectName).standardizedFileURL
        let host = URL(fileURLWithPath: metadata.hostPath).standardizedFileURL.resolvingSymlinksInPath()
        guard metadata.hostPath.hasPrefix("/"), metadata.configDirectory == directory.path,
            directory.path == expected.path, host.path == metadata.hostPath,
            !Self.contains(directory, host), !Self.contains(host, directory),
            workspacePath == nil || workspacePath == metadata.hostPath
        else {
            throw ComposeSandboxError.invalidMetadata("Sandbox configuration must remain outside its working copy.")
        }
    }

    func validateSnapshot(_ metadata: ComposeSandboxMetadata) throws {
        try validateMetadata(metadata)
        let directory = URL(fileURLWithPath: metadata.configDirectory)
        for name in Self.templateFiles {
            let file = directory.appendingPathComponent(name)
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                let expected = metadata.templateHashes[name],
                Self.hashes(for: [name: try Data(contentsOf: file)])[name] == expected
            else {
                throw ComposeSandboxError.invalidMetadata(
                    "The trusted sandbox template changed. Delete this workspace and create it again."
                )
            }
        }
        let saved = try JSONDecoder().decode(
            ComposeSandboxMetadata.self, from: Data(contentsOf: directory.appendingPathComponent("workspace.json"))
        )
        guard saved == metadata else {
            throw ComposeSandboxError.invalidMetadata("Sandbox identity does not match its saved configuration.")
        }
    }

    func markReady(_ metadata: ComposeSandboxMetadata) throws {
        try Data("ready\n".utf8).write(
            to: URL(fileURLWithPath: metadata.configDirectory).appendingPathComponent("ready"), options: .atomic
        )
    }

    func isReady(_ metadata: ComposeSandboxMetadata) -> Bool {
        let marker = URL(fileURLWithPath: metadata.configDirectory).appendingPathComponent("ready")
        return (try? String(contentsOf: marker, encoding: .utf8)) == "ready\n"
    }

    func requireReady(_ metadata: ComposeSandboxMetadata) throws {
        try validateSnapshot(metadata)
        guard isReady(metadata) else { throw ComposeSandboxError.incompleteCreation }
    }

    func composeArguments(_ metadata: ComposeSandboxMetadata, arguments: [String]) -> [String] {
        [
            "--context", metadata.dockerContext, "compose",
            "--project-name", metadata.projectName,
            "--project-directory", metadata.configDirectory,
            "--env-file", "/dev/null",
            "--file", URL(fileURLWithPath: metadata.configDirectory).appendingPathComponent("compose.yaml").path,
        ] + arguments
    }

    @discardableResult
    func compose(
        _ metadata: ComposeSandboxMetadata,
        arguments: [String],
        operation: String,
        timeout: TimeInterval = 60,
        requireSuccess: Bool = true
    ) async throws -> ProcessResult {
        try validateSnapshot(metadata)
        guard try await localEndpoint(context: metadata.dockerContext) == metadata.dockerEndpoint else {
            throw ComposeSandboxError.unavailable(
                "The workspace's Docker context endpoint changed. Restore it before continuing."
            )
        }
        return try await run(
            executable: executablePath,
            arguments: composeArguments(metadata, arguments: arguments),
            directory: URL(fileURLWithPath: metadata.configDirectory),
            environment: cleanEnvironment(metadata: metadata),
            timeout: timeout,
            operation: operation,
            requireSuccess: requireSuccess
        )
    }

    func runGit(arguments: [String], directory: URL) async throws -> ProcessResult {
        try await run(
            executable: "/usr/bin/git",
            arguments: ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments,
            directory: directory,
            environment: cleanEnvironment(),
            timeout: 120,
            operation: "Prepare sandbox repository"
        )
    }

    func terminalCommand(_ metadata: ComposeSandboxMetadata, sessionID: String) throws -> String {
        try requireReady(metadata)
        let environment = cleanEnvironment(metadata: metadata).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let arguments = composeArguments(
            metadata,
            arguments: [
                "exec", "--env", "TERM=xterm-256color", "--env", "COLORTERM=truecolor",
                "--workdir", metadata.containerWorkingDirectory, metadata.terminalService,
                "tmux", "new-session", "-A", "-s", "ws-\(sessionID)", "-c", "/workspace", "/bin/bash -l",
            ]
        )
        let prefix = [executablePath]
        let probe = (prefix + ["context", "inspect", metadata.dockerContext, "--format", "{{.Endpoints.docker.Host}}"])
            .map(Self.shellQuote).joined(separator: " ")
        let launch = (prefix + arguments)
            .map(Self.shellQuote).joined(separator: " ")
        let script =
            "test \"$(\(probe))\" = \(Self.shellQuote(metadata.dockerEndpoint)) "
            + "|| { printf '%s\\n' 'Docker context changed; restore its endpoint before attaching.'; exit 1; }; exec \(launch)"
        // Ghostty launches a command as argv; it does not interpret shell operators.
        // Clear inherited state before invoking the explicit shell that owns the guard.
        return (["/usr/bin/env", "-i"] + environment + ["/bin/sh", "-c", script])
            .map(Self.shellQuote).joined(separator: " ")
    }

    private func runDocker(arguments: [String], operation: String) async throws -> ProcessResult {
        try await run(
            executable: executablePath,
            arguments: arguments,
            directory: homeDirectory,
            environment: cleanEnvironment(),
            timeout: 15,
            operation: operation
        )
    }

    private func run(
        executable: String,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        timeout: TimeInterval,
        operation: String,
        requireSuccess: Bool = true
    ) async throws -> ProcessResult {
        let result: ProcessResult
        do {
            result = try await runner(
                ComposeSandboxCommand(
                    executable: executable, arguments: arguments, currentDirectory: directory,
                    environment: environment, timeout: timeout
                )
            )
        } catch {
            // Do not echo command arguments or process output: lifecycle scripts may contain credentials.
            throw ComposeSandboxError.unavailable("\(operation) could not complete. Check that Docker is running.")
        }
        if requireSuccess, !result.success {
            throw ComposeSandboxError.commandFailed(operation: operation, exitCode: result.exitCode)
        }
        return result
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.first != "-"
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
                    .contains($0)
            }
    }

    static func contains(_ directory: URL, _ candidate: URL) -> Bool {
        candidate.path == directory.path || candidate.path.hasPrefix(directory.path + "/")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
