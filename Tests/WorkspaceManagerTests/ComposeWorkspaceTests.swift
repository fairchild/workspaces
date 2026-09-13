// Tests the Compose isolation boundary with recorded Docker commands and real Git
// clones. A separate opt-in lane exercises the same provider against a local daemon.

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Compose sandbox")
struct ComposeWorkspaceTests {
    @Test("Old metadata keeps Bash and blank commands preserve the default")
    func legacyTerminalCommand() throws {
        let fixture = try ComposeTestFixture()
        defer { fixture.cleanup() }
        let metadata = fixture.metadata()
        let encoded = try JSONEncoder().encode(metadata)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["defaultTerminalCommand"] == nil)
        #expect(try JSONDecoder().decode(ComposeSandboxMetadata.self, from: encoded).defaultTerminalCommand == nil)
        try fixture.runtime.installSnapshot(fixture.template, metadata: metadata)
        try fixture.runtime.markReady(metadata)
        let launch = try #require(fixture.provider.reattachmentLaunchSpec(for: fixture.target(metadata)).customCommand)
        #expect(launch.contains("/bin/bash -l"))
        #expect(!launch.contains("workspaces-terminal"))
        for value in [nil, "", " \t\n"] as [String?] {
            #expect(try ComposeWorkspaceProvider.normalizedTerminalCommand(value) == nil)
        }
    }

    @Test("Terminal commands persist verbatim and reach Compose without entering the host launch string")
    func configuredTerminalCommandBoundary() async throws {
        let fixture = try ComposeTestFixture()
        defer { fixture.cleanup() }
        let source = try TestGitRepository.create()
        defer { source.cleanup() }
        try source.createFile("README", content: "fixture")
        try source.commit(message: "fixture")
        let command =
            " \nprintf '%s\\n' \"$(uname -s) $HOME\" '\(ComposeWorkspaceProvider.terminalSessionPlaceholder)'; exit 37\n"
        let persistence = await MainActor.run { ComposeResultRecorder() }
        let result = try await fixture.provider.createWorkspace(
            request: fixture.request(source: source.url, defaultTerminalCommand: command),
            workspaceService: fixture.workspaceService, progress: nil,
            persist: { persistence.results.append($0) }
        )
        for result in await persistence.results {
            let metadata = try JSONDecoder().decode(
                ComposeSandboxMetadata.self, from: Data(result.backendMetadataRaw.utf8)
            )
            #expect(metadata.defaultTerminalCommand == command)
        }
        let commands = await fixture.recorder.commands
        let start = try #require(commands.first { $0.arguments.contains("up") })
        #expect(start.environment["SANDBOX_TERMINAL_COMMAND"] == command)
        #expect(commands.allSatisfy { !$0.arguments.contains(command) })
        #expect(
            commands.filter { $0.executable == "/usr/bin/git" }
                .allSatisfy { $0.environment["SANDBOX_TERMINAL_COMMAND"] == nil }
        )
        let target = fixture.target(result)
        let spec = try await fixture.provider.terminalLaunchSpec(for: target)
        let launch = try #require(spec.customCommand)
        #expect(launch.contains("/usr/local/bin/workspaces-terminal"))
        #expect(!launch.contains("SANDBOX_TERMINAL_COMMAND"))
        #expect(!launch.contains("uname"))
        #expect(!launch.contains("$HOME"))
        #expect(launch.components(separatedBy: ComposeWorkspaceProvider.terminalSessionPlaceholder).count == 2)
        #expect(try fixture.provider.reattachmentLaunchSpec(for: target) == spec)

        var object = try #require(
            JSONSerialization.jsonObject(with: Data(result.backendMetadataRaw.utf8)) as? [String: Any]
        )
        object["defaultTerminalCommand"] = "different-command"
        let changed = try JSONDecoder().decode(
            ComposeSandboxMetadata.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(throws: ComposeSandboxError.self) { try fixture.runtime.validateSnapshot(changed) }
    }

    @Test("Unrepresentable terminal commands fail before persistence or external commands")
    func rejectsNullTerminalCommandBeforeSideEffects() async throws {
        let fixture = try ComposeTestFixture()
        defer { fixture.cleanup() }
        let persistence = await MainActor.run { ComposeResultRecorder() }
        await #expect(throws: ComposeSandboxError.self) {
            try await fixture.provider.createWorkspace(
                request: fixture.request(source: fixture.root, defaultTerminalCommand: "echo before\0after"),
                workspaceService: fixture.workspaceService, progress: nil,
                persist: { persistence.results.append($0) }
            )
        }
        #expect(await persistence.results.isEmpty)
        #expect(await fixture.recorder.commands.isEmpty)
    }

    @Test("Terminal commands are limited to 16 KiB of UTF-8 before side effects", arguments: ["a", "é"])
    func terminalCommandSizeLimit(character: String) async throws {
        let fixture = try ComposeTestFixture()
        defer { fixture.cleanup() }
        let accepted = String(repeating: character, count: 16 * 1024 / character.utf8.count)
        let oversized = accepted + "x"
        #expect(accepted.utf8.count == 16 * 1024)
        #expect(try ComposeWorkspaceProvider.normalizedTerminalCommand(accepted) == accepted)
        try fixture.runtime.validateMetadata(fixture.metadata(defaultTerminalCommand: accepted))
        #expect(throws: ComposeSandboxError.self) {
            try fixture.runtime.validateMetadata(fixture.metadata(defaultTerminalCommand: oversized))
        }
        let persistence = await MainActor.run { ComposeResultRecorder() }
        await #expect(
            throws: ComposeSandboxError.invalidMetadata("Terminal command must be 16 KiB or smaller.")
        ) {
            try await fixture.provider.createWorkspace(
                request: fixture.request(source: fixture.root, defaultTerminalCommand: oversized),
                workspaceService: fixture.workspaceService, progress: nil,
                persist: { persistence.results.append($0) }
            )
        }
        #expect(await persistence.results.isEmpty)
        #expect(await fixture.recorder.commands.isEmpty)
    }

    @Test("Repository remotes never forward embedded host credentials")
    func rejectsRemoteCredentials() throws {
        for remote in [
            "https://fake-secret@example.com/repo.git", "https://user:fake-secret@example.com/repo.git",
            "https://example.com/repo.git?token=fake-secret", "ssh://git:fake-secret@example.com/repo.git",
        ] {
            #expect(throws: ComposeSandboxError.self) { try ComposeWorkspaceProvider.sandboxRemote(remote) }
        }
        #expect(
            try ComposeWorkspaceProvider.sandboxRemote("ssh://git@example.com/repo.git")
                == "ssh://git@example.com/repo.git")
        #expect(try ComposeWorkspaceProvider.sandboxRemote("git@example.com:repo.git") == "git@example.com:repo.git")
        #expect(try ComposeWorkspaceProvider.sandboxRemote("/local/repository") == nil)
    }

    @Test("Configuration rejects a checkout containing its trusted runtime directory")
    func configurationCannotLiveInCheckout() throws {
        let fixture = try ComposeTestFixture()
        defer { fixture.cleanup() }
        let metadata = fixture.metadata(hostPath: fixture.root.path)
        #expect(throws: ComposeSandboxError.self) { try fixture.runtime.validateMetadata(metadata) }
    }

    @Test("Template changes and symlinks are rejected before Docker is invoked")
    func snapshotTamperingFailsClosed() async throws {
        let fixture = try ComposeTestFixture()
        defer { fixture.cleanup() }
        let metadata = fixture.metadata()
        try fixture.runtime.installSnapshot(fixture.template, metadata: metadata)
        let config = URL(fileURLWithPath: metadata.configDirectory).appendingPathComponent("compose.yaml")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        try Data("services: { agent: { privileged: true } }".utf8).write(to: config)
        await #expect(throws: ComposeSandboxError.self) {
            try await fixture.runtime.compose(metadata, arguments: ["up"], operation: "test")
        }
        #expect(await fixture.recorder.commands.isEmpty)
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: fixture.templateDirectory)
        #expect(throws: ComposeSandboxError.self) { try fixture.runtime.validateSnapshot(metadata) }
    }

    @Test("Compose commands pin their context and ignore inherited configuration and credentials")
    func commandIsolation() async throws {
        let fixture = try ComposeTestFixture()
        defer { fixture.cleanup() }
        let metadata = fixture.metadata()
        try fixture.runtime.installSnapshot(fixture.template, metadata: metadata)
        _ = try await fixture.runtime.compose(metadata, arguments: ["ps"], operation: "test")
        let command = try #require(await fixture.recorder.commands.last)
        #expect(command.arguments.prefix(4) == ["--context", "test-local", "compose", "--project-name"])
        #expect(command.arguments.contains(metadata.projectName))
        #expect(command.currentDirectory.path == metadata.configDirectory)
        #expect(command.arguments.contains("/dev/null"))
        #expect(command.environment["WORKSPACE_DIR"] == metadata.hostPath)
        #expect(command.environment["COMPOSE_DISABLE_ENV_FILE"] == "1")
        for key in [
            "DOCKER_HOST", "COMPOSE_FILE", "COMPOSE_PROJECT_NAME", "GH_TOKEN", "OPENAI_API_KEY", "SSH_AUTH_SOCK",
        ] {
            #expect(command.environment[key] == nil)
        }
        #expect(command.timeout > 0)
    }

    @Test("A repointed context cannot operate on another Docker daemon")
    func contextEndpointCannotDrift() async throws {
        let fixture = try ComposeTestFixture()
        defer { fixture.cleanup() }
        let metadata = fixture.metadata()
        try fixture.runtime.installSnapshot(fixture.template, metadata: metadata)
        try fixture.runtime.markReady(metadata)
        await fixture.recorder.setEndpoint("unix:///other/docker.sock")
        await #expect(throws: ComposeSandboxError.self) {
            try await fixture.provider.startWorkspace(fixture.target(metadata))
        }
        #expect(await !fixture.recorder.commands.contains { $0.arguments.contains("up") })
        let launch = try fixture.provider.reattachmentLaunchSpec(for: fixture.target(metadata))
        #expect(launch.customCommand?.contains("unix:///private/tmp/docker.sock") == true)
        await fixture.recorder.setEndpoint("ssh://remote.example")
        #expect(await !fixture.provider.availability().isAvailable)
    }

    @Test("Git worktree files and shared object stores cannot become sandbox clones")
    func rejectsLinkedGitMetadata() throws {
        let fixture = try ComposeTestFixture()
        defer { fixture.cleanup() }
        let checkout = fixture.root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let git = checkout.appendingPathComponent(".git")
        try Data("gitdir: /host/repository/.git/worktrees/example".utf8).write(to: git)
        #expect(throws: ComposeSandboxError.self) {
            try ComposeWorkspaceProvider.validateIndependentClone(at: checkout)
        }
        try FileManager.default.removeItem(at: git)
        try FileManager.default.createDirectory(
            at: git.appendingPathComponent("objects/info"), withIntermediateDirectories: true
        )
        try Data("/host/repository/.git/objects".utf8).write(to: git.appendingPathComponent("objects/info/alternates"))
        #expect(throws: ComposeSandboxError.self) {
            try ComposeWorkspaceProvider.validateIndependentClone(at: checkout)
        }
    }

    @Test("Creation persists identity before clone and executes checkout and setup only inside the agent")
    func creationBoundaryAndTerminalIdentity() async throws {
        let fixture = try ComposeTestFixture()
        defer { fixture.cleanup() }
        let source = try TestGitRepository.create()
        defer { source.cleanup() }
        try source.createFile("setup.sh", content: "touch host-must-not-run\n")
        try source.commit(message: "fixture")
        let persistence = await MainActor.run { ComposeResultRecorder() }
        let result = try await fixture.provider.createWorkspace(
            request: fixture.request(source: source.url), workspaceService: fixture.workspaceService,
            progress: nil,
            persist: { result in
                persistence.results.append(result)
                await fixture.recorder.markPersisted()
            }
        )
        #expect(await fixture.recorder.persistedBeforeClone)
        let results = await persistence.results
        #expect(results.map(\.status) == [.provisioning, .active])
        #expect(results.first?.remoteId == result.remoteId)
        let provisionalMetadata = try JSONDecoder().decode(
            ComposeSandboxMetadata.self, from: Data(try #require(results.first).backendMetadataRaw.utf8)
        )
        let finalMetadata = try JSONDecoder().decode(
            ComposeSandboxMetadata.self, from: Data(result.backendMetadataRaw.utf8)
        )
        #expect(provisionalMetadata == finalMetadata)
        let commands = await fixture.recorder.commands
        let hostCommands = commands.filter { $0.executable == "/usr/bin/git" }
        #expect(hostCommands.count == 2)
        #expect(hostCommands.last?.arguments.contains("--no-checkout") == true)
        #expect(hostCommands.last?.arguments.contains("--no-hardlinks") == true)
        #expect(!FileManager.default.fileExists(atPath: result.path.appendingPathComponent("setup.sh").path))
        #expect(commands.contains { $0.arguments.contains("checkout") && $0.arguments.contains("agent") })
        #expect(commands.contains { $0.arguments.contains("https://example.com/repository.git") })
        let target = fixture.target(result)
        let spec = try await fixture.provider.terminalLaunchSpec(for: target)
        #expect(spec.sessionKey == .backendSession(providerID: "compose", instanceID: try #require(result.remoteId)))
        let terminal = try #require(spec.customCommand)
        #expect(terminal.contains(ComposeWorkspaceProvider.terminalSessionPlaceholder))
        #expect(terminal.hasPrefix("'/usr/bin/env' '-i'"))
        #expect(terminal.contains("'/bin/sh' '-c'"))
        #expect(terminal.contains("tmux"))
        #expect(terminal.contains("'TERM=xterm-256color'"))
        #expect(!terminal.contains("'up'"))
        let restored = try fixture.provider.reattachmentLaunchSpec(for: target)
        #expect(restored == spec)
    }

    @Test("Failed setup retains identity, stops only its project, and cannot be resumed as ready")
    func failedSetupIsRecoverableButNeverReady() async throws {
        let fixture = try ComposeTestFixture()
        defer { fixture.cleanup() }
        await fixture.recorder.failSetup()
        let source = try TestGitRepository.create()
        defer { source.cleanup() }
        try source.createFile("README", content: "fixture")
        try source.commit(message: "fixture")
        let persistence = await MainActor.run { ComposeResultRecorder() }
        await #expect(throws: ComposeSandboxError.self) {
            try await fixture.provider.createWorkspace(
                request: fixture.request(source: source.url), workspaceService: fixture.workspaceService,
                progress: nil, persist: { persistence.results.append($0) }
            )
        }
        let provisional = try #require(await persistence.results.first)
        let target = fixture.target(provisional)
        #expect(FileManager.default.fileExists(atPath: provisional.path.path))
        await #expect(throws: ComposeSandboxError.incompleteCreation) {
            try await fixture.provider.startWorkspace(target)
        }
        #expect(throws: ComposeSandboxError.incompleteCreation) {
            try fixture.provider.reattachmentLaunchSpec(for: target)
        }
        let commands = await fixture.recorder.commands
        #expect(commands.last?.arguments.contains("stop") == true)
        #expect(commands.last?.arguments.contains(provisional.remoteId ?? "") == true)
        #expect(!commands.contains { $0.arguments.contains("--volumes") })
    }

    @Test("Daemon failures remain unavailable and never become deleted or archived")
    func unavailableDaemonPreservesState() async throws {
        let fixture = try ComposeTestFixture()
        defer { fixture.cleanup() }
        let metadata = fixture.metadata()
        try fixture.runtime.installSnapshot(fixture.template, metadata: metadata)
        try fixture.runtime.markReady(metadata)
        await fixture.recorder.failDaemon()
        await #expect(throws: ComposeSandboxError.self) {
            try await fixture.provider.syncStatuses(for: [fixture.target(metadata)])
        }
        #expect(try ComposeWorkspaceProvider.status(from: "[]") == .stopped)
        #expect(try ComposeWorkspaceProvider.status(from: "{\"Service\":\"agent\",\"State\":\"running\"}") == .active)
        #expect(
            try ComposeWorkspaceProvider.status(
                from: "[{\"Service\":\"agent\",\"State\":\"running\",\"Health\":\"unhealthy\"}]"
            ) == .active
        )
        #expect(throws: ComposeSandboxError.self) { try ComposeWorkspaceProvider.status(from: "unavailable") }
    }

    @Test("Removing runtime retains data; deleting owned data never runs host Git")
    func deletionScope() async throws {
        let fixture = try ComposeTestFixture()
        defer { fixture.cleanup() }
        let metadata = fixture.metadata()
        try fixture.runtime.installSnapshot(fixture.template, metadata: metadata)
        try FileManager.default.createDirectory(atPath: metadata.hostPath, withIntermediateDirectories: true)
        try Data("gitdir: /host/other-repository".utf8).write(
            to: URL(fileURLWithPath: metadata.hostPath).appendingPathComponent(".git")
        )
        let target = try fixture.target(metadata)
        try await fixture.provider.deleteWorkspace(target, deleteFiles: false)
        #expect(FileManager.default.fileExists(atPath: metadata.hostPath))
        let retained = try #require(await fixture.recorder.commands.last)
        #expect(retained.arguments.contains("down"))
        #expect(!retained.arguments.contains("--volumes"))
        try await fixture.provider.deleteWorkspace(target, deleteFiles: true)
        #expect(!FileManager.default.fileExists(atPath: metadata.hostPath))
        #expect(!FileManager.default.fileExists(atPath: metadata.configDirectory))
        let commands = await fixture.recorder.commands
        #expect(commands.last?.arguments.contains("--volumes") == true)
        #expect(!commands.contains { $0.executable == "/usr/bin/git" })
    }
}

@MainActor
private final class ComposeResultRecorder {
    var results: [WorkspaceProviderCreationResult] = []
}

private actor ComposeCommandRecorder {
    private(set) var commands: [ComposeSandboxCommand] = []
    private(set) var persistedBeforeClone = false
    private var persisted = false
    private var setupFailure = false
    private var daemonFailure = false
    private var endpoint = "unix:///private/tmp/docker.sock"

    func markPersisted() { persisted = true }
    func failSetup() { setupFailure = true }
    func failDaemon() { daemonFailure = true }
    func setEndpoint(_ value: String) { endpoint = value }

    func run(_ command: ComposeSandboxCommand) async throws -> ProcessResult {
        commands.append(command)
        let arguments = command.arguments
        if command.executable == "/usr/bin/git" {
            if arguments.contains("clone") { persistedBeforeClone = persisted }
            return try await ProcessRunner.run(
                executable: command.executable, arguments: arguments, currentDirectory: command.currentDirectory,
                environment: command.environment, timeout: command.timeout
            )
        }
        var stdout = ""
        if arguments == ["context", "show"] { stdout = "test-local\n" }
        if arguments.contains("inspect") { stdout = endpoint + "\n" }
        if arguments.contains("info") {
            if daemonFailure { return ProcessResult(exitCode: 1, stdout: "", stderr: "daemon unavailable") }
            stdout = "linux\n"
        }
        if arguments.contains("version") { stdout = "2.39.0\n" }
        if arguments.contains("ps") {
            stdout = "[{\"Service\":\"agent\",\"State\":\"running\",\"Health\":\"healthy\"}]"
        }
        if setupFailure, arguments.contains(where: { $0.contains("for script in 'scripts/setup'") }) {
            return ProcessResult(exitCode: 42, stdout: "", stderr: "fixture setup failed")
        }
        return ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}

private final class ComposeTestFixture: @unchecked Sendable {
    let root: URL
    let templateDirectory: URL
    let template: [String: Data]
    let recorder = ComposeCommandRecorder()
    let runtime: ComposeWorkspaceRuntime
    let provider: ComposeWorkspaceProvider
    let workspaceService: WorkspaceService

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("compose-tests-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        templateDirectory = root.appendingPathComponent("template")
        try FileManager.default.createDirectory(at: templateDirectory, withIntermediateDirectories: true)
        template = [
            "compose.yaml": Data("services: {}\n".utf8), "Dockerfile": Data("FROM scratch\n".utf8),
            ".dockerignore": Data("*\n".utf8),
        ]
        for (name, data) in template { try data.write(to: templateDirectory.appendingPathComponent(name)) }
        let recorder = self.recorder
        runtime = ComposeWorkspaceRuntime(
            runtimeRoot: root.appendingPathComponent("runtime"), templateDirectory: templateDirectory,
            executablePath: "/test/docker", dockerContext: "test-local",
            runner: { try await recorder.run($0) }
        )
        provider = ComposeWorkspaceProvider(runtime: runtime)
        workspaceService = WorkspaceService(
            materializer: GitCloneWorkspaceMaterializer(),
            environment: [SyntheticRunRoot.environmentKey: root.appendingPathComponent("workspaces").path]
        )
    }

    func metadata(hostPath: String? = nil, defaultTerminalCommand: String? = nil) -> ComposeSandboxMetadata {
        let name = "ws-\(UUID().uuidString.lowercased())"
        return ComposeSandboxMetadata(
            projectName: name, dockerContext: "test-local", dockerEndpoint: "unix:///private/tmp/docker.sock",
            hostPath: hostPath ?? root.appendingPathComponent("clone").path,
            configDirectory: runtime.runtimeRoot.appendingPathComponent(name).path,
            templateHashes: ComposeWorkspaceRuntime.hashes(for: template),
            defaultTerminalCommand: defaultTerminalCommand
        )
    }

    func request(
        source: URL, name: String = "sandbox", defaultTerminalCommand: String? = nil
    ) -> WorkspaceProviderCreationRequest {
        WorkspaceProviderCreationRequest(
            repoName: "fixture", repoLocalURL: source, repoRemoteURL: "https://example.com/repository.git",
            workspaceName: name, guestOS: .linux, defaultTerminalCommand: defaultTerminalCommand
        )
    }

    func target(_ result: WorkspaceProviderCreationResult) -> WorkspaceProviderTarget {
        WorkspaceProviderTarget(
            id: UUID(), name: result.name, path: result.path.path, gitBranch: result.gitBranch, status: result.status,
            backendIdentifier: "compose", remoteId: result.remoteId, sessionRoutingID: result.sessionRoutingID,
            backendMetadataRaw: result.backendMetadataRaw
        )
    }

    func target(_ metadata: ComposeSandboxMetadata) throws -> WorkspaceProviderTarget {
        WorkspaceProviderTarget(
            id: UUID(), name: "fixture", path: metadata.hostPath, gitBranch: "workspace/fixture", status: .active,
            backendIdentifier: "compose", remoteId: metadata.projectName, sessionRoutingID: metadata.projectName,
            backendMetadataRaw: String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
