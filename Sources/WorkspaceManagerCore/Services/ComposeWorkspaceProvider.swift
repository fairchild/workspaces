//
//  ComposeWorkspaceProvider.swift
//  WorkspaceManagerCore
//
//  Creates one independent Linux Compose project per workspace. Git checkout,
//  repository lifecycle scripts, and terminal sessions execute inside the agent service.
//

import Foundation

public actor ComposeWorkspaceProvider: WorkspaceProviderProtocol {
    public static let identifier = "compose"
    public static let shared = ComposeWorkspaceProvider()
    public static let terminalSessionPlaceholder = "__WORKSPACES_COMPOSE_TERMINAL_SESSION_ID__"
    public static let providerDescriptor = WorkspaceProviderDescriptor(
        id: identifier,
        displayName: "Docker Compose",
        description: "Run a Linux agent sandbox with an independent working copy on this Mac.",
        sheetStatusPolicy: .deferred,
        supportedGuestOS: [.linux],
        usesHostWorkspaceFiles: true
    )

    public nonisolated let descriptor = providerDescriptor
    private let runtime: ComposeWorkspaceRuntime

    public init(runtime: ComposeWorkspaceRuntime = ComposeWorkspaceRuntime()) {
        self.runtime = runtime
    }

    public func availability() async -> WorkspaceProviderAvailability {
        do {
            _ = try await runtime.checkedContext()
            _ = try runtime.loadTemplate()
            return .available
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    public nonisolated func sessionKey(for workspace: WorkspaceProviderTarget) -> HostTerminalSessionKey {
        .backendSession(providerID: Self.identifier, instanceID: workspace.terminalSessionIdentifier)
    }

    public func createWorkspace(
        request: WorkspaceProviderCreationRequest,
        workspaceService: any WorkspaceServiceProtocol,
        progress: WorkspaceProviderProgressHandler?,
        persist: WorkspaceProviderPersistenceHandler?
    ) async throws -> WorkspaceProviderCreationResult {
        guard request.guestOS == nil || request.guestOS == .linux else {
            throw ComposeSandboxError.unavailable("Docker Compose workspaces support Linux only.")
        }
        let remote = try Self.sandboxRemote(request.repoRemoteURL)
        let terminalCommand = try Self.normalizedTerminalCommand(request.defaultTerminalCommand)
        let workspaceName = WorkspaceService.sanitizeWorkspaceNameComponent(request.workspaceName)
        let repoName = WorkspaceService.sanitizeWorkspaceNameComponent(request.repoName)
        guard Self.validName(workspaceName), Self.validName(repoName) else {
            throw WorkspaceError.invalidName(name: request.workspaceName)
        }
        let root = await workspaceService.workspacesRoot.standardizedFileURL.resolvingSymlinksInPath()
        let destination = root.appendingPathComponent(repoName).appendingPathComponent(workspaceName)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard ComposeWorkspaceRuntime.contains(root, destination), destination != root else {
            throw WorkspaceError.invalidName(name: request.workspaceName)
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorkspaceError.alreadyExists(name: workspaceName)
        }

        await progress?("Checking Docker Compose...")
        let context = try await runtime.checkedContext()
        let template = try runtime.loadTemplate()
        let fromRef = try WorkspaceCreationRefValidator.normalizedValue(request.fromRef) ?? "HEAD"
        let commit = try await runtime.runGit(
            arguments: ["rev-parse", "--verify", "--end-of-options", "\(fromRef)^{commit}"],
            directory: request.repoLocalURL
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.count == 40 || commit.count == 64,
            commit.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) })
        else {
            throw ComposeSandboxError.invalidMetadata("The selected repository reference is not a commit.")
        }
        let projectName = "ws-\(UUID().uuidString.lowercased())"
        let metadata = ComposeSandboxMetadata(
            projectName: projectName,
            dockerContext: context,
            dockerEndpoint: try await runtime.localEndpoint(context: context),
            hostPath: destination.path,
            configDirectory: runtime.runtimeRoot.appendingPathComponent(projectName).path,
            templateHashes: ComposeWorkspaceRuntime.hashes(for: template),
            defaultTerminalCommand: terminalCommand
        )
        try runtime.validateMetadata(metadata)
        let branch = "workspace/\(workspaceName)"
        let provisional = try Self.creationResult(
            request: request, metadata: metadata, branch: branch, status: .provisioning
        )
        // The caller owns its database row; the host-only snapshot below also preserves
        // the same identity for standalone callers and failed creation recovery.
        try await persist?(provisional)
        try runtime.installSnapshot(template, metadata: metadata)

        do {
            await progress?("Creating an independent repository clone...")
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            _ = try await runtime.runGit(
                arguments: [
                    "clone", "--local", "--no-hardlinks", "--no-checkout", "--template=", "--",
                    request.repoLocalURL.path, destination.path,
                ],
                directory: destination.deletingLastPathComponent()
            )
            try Self.validateIndependentClone(at: destination)

            await progress?("Building the agent sandbox...")
            _ = try await runtime.compose(metadata, arguments: ["config", "--quiet"], operation: "Validate sandbox")
            _ = try await runtime.compose(
                metadata, arguments: ["build"], operation: "Build agent sandbox", timeout: 600
            )
            await progress?("Starting the agent sandbox...")
            _ = try await runtime.compose(
                metadata, arguments: ["up", "--detach", "--wait", "--wait-timeout", "60", "--no-build"],
                operation: "Start agent sandbox", timeout: 90
            )
            let probe = try await execute(
                metadata: metadata,
                arguments: [
                    "/bin/bash", "-lc",
                    "test \"$(id -u)\" != 0 && test -w /workspace && test -w /home/agent && command -v tmux >/dev/null",
                ]
            )
            try Self.requireSuccess(probe, operation: "Verify agent sandbox")
            let checkout = try await execute(
                metadata: metadata,
                arguments: ["git", "-c", "core.hooksPath=/dev/null", "checkout", "-b", branch, commit]
            )
            try Self.requireSuccess(checkout, operation: "Check out sandbox repository")
            let remoteArguments: [String]
            if let remote {
                remoteArguments = ["git", "remote", "set-url", "origin", remote]
            } else {
                remoteArguments = ["git", "remote", "remove", "origin"]
            }
            try Self.requireSuccess(
                try await execute(metadata: metadata, arguments: remoteArguments), operation: "Configure sandbox remote"
            )
            await progress?("Running setup inside the sandbox...")
            try Self.requireSuccess(
                try await lifecycle("setup", metadata: metadata), operation: "Sandbox setup"
            )
            try runtime.markReady(metadata)
            let result = try Self.creationResult(request: request, metadata: metadata, branch: branch, status: .active)
            try await persist?(result)
            await progress?("Sandbox ready.")
            return result
        } catch {
            // Retain the persisted identity and clone for explicit cleanup. Stop only
            // this project; never remove a user's files as a creation side effect.
            _ = try? await runtime.compose(
                metadata, arguments: ["stop", "--timeout", "10"], operation: "Stop incomplete sandbox", timeout: 30
            )
            throw error
        }
    }

    public func terminalLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> TerminalLaunchSpec {
        let metadata = try metadata(for: workspace)
        try runtime.requireReady(metadata)
        try await runtime.checkDaemon(context: metadata.dockerContext)
        let workspaceStatus = try await status(metadata)
        guard workspaceStatus == .active else {
            throw ComposeSandboxError.unavailable("Start this Docker Compose workspace before opening its terminal.")
        }
        return try reattachmentLaunchSpec(for: workspace)
    }

    static func normalizedTerminalCommand(_ value: String?) throws -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard !value.contains("\0") else {
            throw ComposeSandboxError.invalidMetadata("The terminal command cannot contain a null character.")
        }
        guard value.utf8.count <= ComposeWorkspaceRuntime.maximumTerminalCommandBytes else {
            throw ComposeSandboxError.invalidMetadata("Terminal command must be 16 KiB or smaller.")
        }
        return value
    }

    /// Restores a terminal command from trusted workspace metadata, never from a saved shell string.
    public nonisolated func reattachmentLaunchSpec(
        for workspace: WorkspaceProviderTarget
    ) throws -> TerminalLaunchSpec {
        let metadata = try metadata(for: workspace)
        try runtime.requireReady(metadata)
        return TerminalLaunchSpec(
            sessionKey: sessionKey(for: workspace),
            workingDirectory: URL(fileURLWithPath: metadata.configDirectory),
            customCommand: try runtime.terminalCommand(metadata, sessionID: Self.terminalSessionPlaceholder)
        )
    }

    public func startWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        let metadata = try metadata(for: workspace)
        try runtime.requireReady(metadata)
        _ = try await runtime.compose(
            metadata, arguments: ["up", "--detach", "--wait", "--wait-timeout", "60", "--no-build"],
            operation: "Start sandbox", timeout: 90
        )
    }

    public func stopWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        let metadata = try metadata(for: workspace)
        var scriptResult: ProcessResult?
        if runtime.isReady(metadata), try await status(metadata) == .active {
            scriptResult = try? await lifecycle("stop", metadata: metadata)
        }
        _ = try await runtime.compose(
            metadata, arguments: ["stop", "--timeout", "10"], operation: "Stop sandbox", timeout: 30
        )
        if let scriptResult { try Self.requireSuccess(scriptResult, operation: "Sandbox stop script") }
    }

    public func rebuildWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        let metadata = try metadata(for: workspace)
        try runtime.requireReady(metadata)
        _ = try await runtime.compose(metadata, arguments: ["build"], operation: "Rebuild agent sandbox", timeout: 600)
        _ = try await runtime.compose(
            metadata,
            arguments: ["up", "--detach", "--force-recreate", "--wait", "--wait-timeout", "60", "--no-build"],
            operation: "Recreate agent sandbox", timeout: 90
        )
    }

    public func deleteWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        try await deleteWorkspace(workspace, deleteFiles: false)
    }

    public func deleteWorkspace(_ workspace: WorkspaceProviderTarget, deleteFiles: Bool) async throws {
        let metadata = try metadata(for: workspace)
        // Missing snapshot after a disk failure may precede any Docker side effects.
        // Refuse to guess: a modified or missing trusted config needs operator repair.
        try runtime.validateSnapshot(metadata)
        if runtime.isReady(metadata), try await status(metadata) == .active {
            _ = try? await lifecycle("stop", metadata: metadata)
            if deleteFiles { _ = try? await lifecycle("archive", metadata: metadata) }
        }
        var arguments = ["down", "--timeout", "10", "--remove-orphans"]
        if deleteFiles { arguments += ["--volumes", "--rmi", "all"] }
        _ = try await runtime.compose(metadata, arguments: arguments, operation: "Remove sandbox", timeout: 60)
        if deleteFiles {
            // FileManager unlinks symlinks without invoking agent-controlled Git configuration.
            // Do not use WorkspaceDirectoryRemover, which can run host Git.
            try runtime.validateMetadata(metadata, workspacePath: workspace.path)
            if FileManager.default.fileExists(atPath: metadata.hostPath) {
                try FileManager.default.removeItem(at: URL(fileURLWithPath: metadata.hostPath))
            }
            try FileManager.default.removeItem(at: URL(fileURLWithPath: metadata.configDirectory))
        }
    }

    public func syncStatuses(
        for workspaces: [WorkspaceProviderTarget]
    ) async throws -> [WorkspaceProviderStatusSnapshot] {
        var snapshots: [WorkspaceProviderStatusSnapshot] = []
        for workspace in workspaces {
            let metadata = try metadata(for: workspace)
            // A daemon error throws and preserves the caller's last observed status.
            try await runtime.checkDaemon(context: metadata.dockerContext)
            let workspaceStatus = runtime.isReady(metadata) ? try await status(metadata) : .stopped
            snapshots.append(WorkspaceProviderStatusSnapshot(remoteId: metadata.projectName, status: workspaceStatus))
        }
        return snapshots
    }

    public func execute(
        in workspace: WorkspaceProviderTarget, arguments: [String], timeout: TimeInterval = 60
    ) async throws -> ProcessResult {
        let metadata = try metadata(for: workspace)
        try runtime.requireReady(metadata)
        return try await execute(metadata: metadata, arguments: arguments, timeout: timeout)
    }

    public func executeGit(arguments: [String], for workspace: WorkspaceProviderTarget) async throws -> String {
        let result = try await execute(in: workspace, arguments: ["git"] + arguments)
        try Self.requireSuccess(result, operation: "Git in sandbox")
        return result.stdout
    }

    private func execute(
        metadata: ComposeSandboxMetadata, arguments: [String], timeout: TimeInterval = 60
    ) async throws -> ProcessResult {
        try await runtime.compose(
            metadata,
            arguments: ["exec", "-T", "--workdir", metadata.containerWorkingDirectory, metadata.terminalService]
                + arguments,
            operation: "Execute in sandbox", timeout: timeout, requireSuccess: false
        )
    }

    private func lifecycle(_ action: String, metadata: ComposeSandboxMetadata) async throws -> ProcessResult {
        let candidates: [String]
        switch action {
        case "setup": candidates = ["scripts/setup", "scripts/setup.sh", "setup.sh"]
        case "stop": candidates = ["scripts/stop", "scripts/stop.sh"]
        case "archive": candidates = ["scripts/archive", "scripts/archive.sh", "archive.sh"]
        default: throw ComposeSandboxError.invalidMetadata("Unsupported sandbox lifecycle action.")
        }
        let script =
            "for script in \(candidates.map(ComposeWorkspaceRuntime.shellQuote).joined(separator: " ")); "
            + "do if [ -f \"$script\" ]; then /bin/bash \"$script\"; exit $?; fi; done"
        return try await execute(metadata: metadata, arguments: ["/bin/bash", "-lc", script], timeout: 600)
    }

    private func status(_ metadata: ComposeSandboxMetadata) async throws -> WorkspaceStatus {
        let result = try await runtime.compose(
            metadata, arguments: ["ps", "--all", "--format", "json"], operation: "Read sandbox status", timeout: 15
        )
        return try Self.status(from: result.stdout, terminalService: metadata.terminalService)
    }

    static func status(from json: String, terminalService: String = "agent") throws -> WorkspaceStatus {
        struct Service: Decodable {
            let Service: String
            let State: String
            let Health: String?
        }
        let data = Data(json.utf8)
        let services: [Service]
        if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            services = []
        } else if let array = try? JSONDecoder().decode([Service].self, from: data) {
            services = array
        } else {
            do {
                services = try json.split(separator: "\n").map {
                    try JSONDecoder().decode(Service.self, from: Data($0.utf8))
                }
            } catch {
                throw ComposeSandboxError.unavailable("Docker returned an unreadable workspace status.")
            }
        }
        guard let agent = services.first(where: { $0.Service == terminalService }) else { return .stopped }
        switch agent.State.lowercased() {
        case "running":
            switch agent.Health?.lowercased() {
            case "starting": return .provisioning
            // Keep a running but unhealthy service reachable for terminal repair.
            case "unhealthy": return .active
            default: return .active
            }
        case "created", "restarting": return .provisioning
        case "exited", "dead", "removing", "paused": return .stopped
        default: throw ComposeSandboxError.unavailable("Docker returned an unknown agent service state.")
        }
    }

    private nonisolated func metadata(for workspace: WorkspaceProviderTarget) throws -> ComposeSandboxMetadata {
        guard workspace.backendIdentifier == Self.identifier,
            let metadata = workspace.decodeBackendMetadata(ComposeSandboxMetadata.self),
            workspace.remoteId == metadata.projectName
        else {
            throw ComposeSandboxError.invalidMetadata("Docker Compose workspace identity is missing or invalid.")
        }
        try runtime.validateMetadata(metadata, workspacePath: workspace.path)
        return metadata
    }

    private static func creationResult(
        request: WorkspaceProviderCreationRequest, metadata: ComposeSandboxMetadata, branch: String,
        status: WorkspaceStatus
    ) throws -> WorkspaceProviderCreationResult {
        WorkspaceProviderCreationResult(
            name: request.workspaceName,
            path: URL(fileURLWithPath: metadata.hostPath),
            gitBranch: branch,
            status: status,
            backendIdentifier: identifier,
            remoteId: metadata.projectName,
            sessionRoutingID: metadata.projectName,
            backendMetadataRaw: String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        )
    }

    static func validateIndependentClone(at directory: URL) throws {
        let gitDirectory = directory.appendingPathComponent(".git")
        let attributes = try gitDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true,
            !FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent("objects/info/alternates").path)
        else {
            throw ComposeSandboxError.invalidMetadata(
                "Sandbox Git metadata must be independent of the source repository.")
        }
    }

    private static func validName(_ name: String) -> Bool {
        WorkspaceService.isValidWorkspaceNameComponent(name)
            && name.rangeOfCharacter(from: .controlCharacters) == nil
            && !name.hasPrefix("-") && name.count <= 100
    }

    static func sandboxRemote(_ remote: String?) throws -> String? {
        guard let remote else { return nil }
        guard remote.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw ComposeSandboxError.invalidMetadata("The repository remote is not a valid network URL.")
        }
        if remote.hasPrefix("https://") || remote.hasPrefix("ssh://") {
            guard let url = URLComponents(string: remote), let host = url.host, !host.isEmpty,
                url.password == nil, url.query == nil, url.fragment == nil,
                url.scheme != "https" || url.user == nil
            else {
                throw ComposeSandboxError.invalidMetadata(
                    "Use a repository remote without embedded credentials or URL parameters for this sandbox."
                )
            }
            return remote
        }
        if remote.hasPrefix("git@"), remote.contains(":") { return remote }
        // Local source paths cannot be reached inside the container.
        return nil
    }

    private static func requireSuccess(_ result: ProcessResult, operation: String) throws {
        guard result.success else {
            throw ComposeSandboxError.commandFailed(operation: operation, exitCode: result.exitCode)
        }
    }
}
