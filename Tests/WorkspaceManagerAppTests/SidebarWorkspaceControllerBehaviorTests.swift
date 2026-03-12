import Foundation
import SwiftData
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("SidebarWorkspaceControllerBehavior")
struct SidebarWorkspaceControllerBehaviorTests {
    @Test("Local request routes through WorkspaceService")
    @MainActor
    func localRequestRoutesThroughWorkspaceService() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(name: "api", localPath: URL(fileURLWithPath: "/tmp/api"))
        context.insert(repo)

        let workspaceService = MockWorkspaceService()
        workspaceService.createWorkspaceResult = NewWorkspaceInfo(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/api/workspaces/feature-a"),
            gitBranch: "workspace/feature-a"
        )
        let controller = SidebarWorkspaceController(
            modelContext: context,
            workspaceService: workspaceService,
            remoteBackendRegistry: MockRemoteBackendRegistry()
        )

        let workspace = try await controller.createWorkspace(
            from: repo,
            request: NewWorkspaceRequest(name: "feature-a", backend: .local)
        )

        #expect(workspaceService.createWorkspaceCalls.count == 1)
        #expect(workspace.backendIdentifier == "local")
        #expect(workspace.gitBranch == "workspace/feature-a")
        #expect(workspace.remoteId == nil)
    }

    @Test("Daytona request routes through provisionable backend")
    @MainActor
    func daytonaRequestRoutesThroughProvisionableBackend() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(
            name: "api",
            localPath: URL(fileURLWithPath: "/tmp/api"),
            remoteURL: "git@github.com:acme/api.git"
        )
        context.insert(repo)

        let backend = MockRemoteBackend(
            identifier: DaytonaBackend.identifier,
            runtimeCapabilities: RuntimeCapabilities(
                supportsCreate: true,
                supportsDelete: true,
                supportsStartStop: true,
                supportsArchive: true,
                supportsList: true
            )
        )
        await backend.setCreateSandboxResult(
            RemoteSandboxInfo(
                sandboxId: "daytona-123",
                sshCommand: "ssh daytona"
            )
        )
        let controller = SidebarWorkspaceController(
            modelContext: context,
            workspaceService: MockWorkspaceService(),
            remoteBackendRegistry: MockRemoteBackendRegistry(
                creationBackendIdentifiers: [DaytonaBackend.identifier],
                backends: [DaytonaBackend.identifier: backend]
            )
        )

        let workspace = try await controller.createWorkspace(
            from: repo,
            request: NewWorkspaceRequest(name: "feature-a", backend: .daytona)
        )

        #expect(await backend.createSandboxCallCount() == 1)
        #expect(workspace.backendIdentifier == DaytonaBackend.identifier)
        #expect(workspace.remoteId == "daytona-123")
    }

    @Test("SSH request creates a persisted local record with metadata")
    @MainActor
    func sshRequestCreatesPersistedLocalRecord() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(
            name: "api",
            localPath: URL(fileURLWithPath: "/tmp/api"),
            remoteURL: "git@github.com:acme/api.git"
        )
        context.insert(repo)

        let controller = SidebarWorkspaceController(
            modelContext: context,
            workspaceService: MockWorkspaceService(),
            remoteBackendRegistry: MockRemoteBackendRegistry(
                creationBackendIdentifiers: [SSHBackend.identifier],
                backends: [SSHBackend.identifier: SSHBackend()]
            )
        )
        let ssh = SSHWorkspaceMetadata(
            host: "ssh.example.com",
            user: "alice",
            port: 2222,
            authMode: "ssh-agent",
            workingDir: "/srv/workspaces/feature-a"
        )
        let compose = ComposeWorkspaceMetadata(
            composeFiles: ["compose.yml"],
            service: "web"
        )

        let workspace = try await controller.createWorkspace(
            from: repo,
            request: NewWorkspaceRequest(
                name: "feature-a",
                backend: .sshHost(
                    SSHHostWorkspaceRequest(
                        ssh: ssh,
                        compose: compose
                    )
                )
            )
        )

        #expect(workspace.backendIdentifier == SSHBackend.identifier)
        #expect(workspace.remoteId != nil)
        #expect(workspace.sshMetadata == ssh)
        #expect(workspace.composeMetadata == compose)
    }

    @Test("SSH request rejects invalid names after sanitization")
    @MainActor
    func sshRequestRejectsInvalidNames() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(
            name: "api",
            localPath: URL(fileURLWithPath: "/tmp/api"),
            remoteURL: "git@github.com:acme/api.git"
        )
        context.insert(repo)

        let controller = SidebarWorkspaceController(
            modelContext: context,
            workspaceService: MockWorkspaceService(),
            remoteBackendRegistry: MockRemoteBackendRegistry(
                creationBackendIdentifiers: [SSHBackend.identifier],
                backends: [SSHBackend.identifier: SSHBackend()]
            )
        )

        await #expect(throws: WorkspaceError.self) {
            _ = try await controller.createWorkspace(
                from: repo,
                request: NewWorkspaceRequest(
                    name: "..",
                    backend: .sshHost(
                        SSHHostWorkspaceRequest(
                            ssh: SSHWorkspaceMetadata(host: "ssh.example.com"),
                            compose: nil
                        )
                    )
                )
            )
        }

        let fetchedWorkspaces = try context.fetch(FetchDescriptor<Workspace>())
        #expect(fetchedWorkspaces.isEmpty)
    }

    @Test("SSH request rejects invalid ports")
    @MainActor
    func sshRequestRejectsInvalidPorts() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(
            name: "api",
            localPath: URL(fileURLWithPath: "/tmp/api"),
            remoteURL: "git@github.com:acme/api.git"
        )
        context.insert(repo)

        let controller = SidebarWorkspaceController(
            modelContext: context,
            workspaceService: MockWorkspaceService(),
            remoteBackendRegistry: MockRemoteBackendRegistry(
                creationBackendIdentifiers: [SSHBackend.identifier],
                backends: [SSHBackend.identifier: SSHBackend()]
            )
        )

        await #expect(throws: RemoteWorkspaceError.self) {
            _ = try await controller.createWorkspace(
                from: repo,
                request: NewWorkspaceRequest(
                    name: "feature-a",
                    backend: .sshHost(
                        SSHHostWorkspaceRequest(
                            ssh: SSHWorkspaceMetadata(host: "ssh.example.com", port: 0),
                            compose: nil
                        )
                    )
                )
            )
        }

        let fetchedWorkspaces = try context.fetch(FetchDescriptor<Workspace>())
        #expect(fetchedWorkspaces.isEmpty)
    }

    @Test("Lifecycle operations are capability-gated per backend")
    @MainActor
    func lifecycleOperationsAreCapabilityGatedPerBackend() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(
            name: "api",
            localPath: URL(fileURLWithPath: "/tmp/api"),
            remoteURL: "git@github.com:acme/api.git"
        )
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/api/workspaces/feature-a"),
            sourceRepo: repo,
            backendIdentifier: SSHBackend.identifier,
            remoteId: "remote-123"
        )
        workspace.sshMetadata = SSHWorkspaceMetadata(host: "ssh.example.com")
        context.insert(repo)
        context.insert(workspace)
        try context.save()

        let controller = SidebarWorkspaceController(
            modelContext: context,
            workspaceService: MockWorkspaceService(),
            remoteBackendRegistry: MockRemoteBackendRegistry(
                backends: [SSHBackend.identifier: SSHBackend()]
            )
        )

        await #expect(throws: SidebarWorkspaceController.ControllerError.self) {
            try await controller.start(workspace)
        }
    }

    @Test("Deleting SSH workspace removes only the local record")
    @MainActor
    func deletingSSHWorkspaceRemovesOnlyLocalRecord() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(
            name: "api",
            localPath: URL(fileURLWithPath: "/tmp/api"),
            remoteURL: "git@github.com:acme/api.git"
        )
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/api/workspaces/feature-a"),
            sourceRepo: repo,
            backendIdentifier: SSHBackend.identifier,
            remoteId: "remote-123"
        )
        workspace.sshMetadata = SSHWorkspaceMetadata(host: "ssh.example.com")
        context.insert(repo)
        context.insert(workspace)
        try context.save()

        let workspaceService = MockWorkspaceService()
        let controller = SidebarWorkspaceController(
            modelContext: context,
            workspaceService: workspaceService,
            remoteBackendRegistry: MockRemoteBackendRegistry(
                backends: [SSHBackend.identifier: SSHBackend()]
            )
        )

        try await controller.deleteWorkspace(workspace, deleteFiles: true)

        let fetchedWorkspaces = try context.fetch(FetchDescriptor<Workspace>())
        #expect(fetchedWorkspaces.isEmpty)
        #expect(workspaceService.deleteWorkspaceCalls.isEmpty)
    }

    @Test("Deleting Daytona workspace preserves the record when provider deletion fails")
    @MainActor
    func deletingDaytonaWorkspacePreservesRecordWhenProviderDeletionFails() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(
            name: "api",
            localPath: URL(fileURLWithPath: "/tmp/api"),
            remoteURL: "git@github.com:acme/api.git"
        )
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/api/workspaces/feature-a"),
            sourceRepo: repo,
            backendIdentifier: DaytonaBackend.identifier,
            remoteId: "daytona-123"
        )
        context.insert(repo)
        context.insert(workspace)
        try context.save()

        let backend = MockRemoteBackend(
            identifier: DaytonaBackend.identifier,
            runtimeCapabilities: RuntimeCapabilities(
                supportsCreate: true,
                supportsDelete: true,
                supportsStartStop: true,
                supportsArchive: true,
                supportsList: true
            )
        )
        await backend.setDeleteSandboxError(TestBackendError.deleteFailed)
        let controller = SidebarWorkspaceController(
            modelContext: context,
            workspaceService: MockWorkspaceService(),
            remoteBackendRegistry: MockRemoteBackendRegistry(
                backends: [DaytonaBackend.identifier: backend]
            )
        )

        await #expect(throws: TestBackendError.self) {
            try await controller.deleteWorkspace(workspace, deleteFiles: false)
        }

        let fetchedWorkspaces = try context.fetch(FetchDescriptor<Workspace>())
        #expect(fetchedWorkspaces.count == 1)
        #expect(await backend.deleteSandboxCallCount() == 1)
    }

    @Test("Deleting Daytona workspace fails closed when remote identifier is missing")
    @MainActor
    func deletingDaytonaWorkspaceFailsClosedWhenRemoteIdentifierIsMissing() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(
            name: "api",
            localPath: URL(fileURLWithPath: "/tmp/api"),
            remoteURL: "git@github.com:acme/api.git"
        )
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/api/workspaces/feature-a"),
            sourceRepo: repo,
            backendIdentifier: DaytonaBackend.identifier
        )
        context.insert(repo)
        context.insert(workspace)
        try context.save()

        let backend = MockRemoteBackend(
            identifier: DaytonaBackend.identifier,
            runtimeCapabilities: RuntimeCapabilities(
                supportsCreate: true,
                supportsDelete: true,
                supportsStartStop: true,
                supportsArchive: true,
                supportsList: true
            )
        )
        let controller = SidebarWorkspaceController(
            modelContext: context,
            workspaceService: MockWorkspaceService(),
            remoteBackendRegistry: MockRemoteBackendRegistry(
                backends: [DaytonaBackend.identifier: backend]
            )
        )

        do {
            try await controller.deleteWorkspace(workspace, deleteFiles: false)
            Issue.record("Expected delete to fail when remoteId is missing")
        } catch let error as RemoteWorkspaceError {
            #expect(
                error.localizedDescription
                    == RemoteWorkspaceError.missingRemoteIdentifier.localizedDescription
            )
        } catch {
            Issue.record("Expected RemoteWorkspaceError.missingRemoteIdentifier, got \(error)")
        }

        let fetchedWorkspaces = try context.fetch(FetchDescriptor<Workspace>())
        #expect(fetchedWorkspaces.count == 1)
        #expect(await backend.deleteSandboxCallCount() == 0)
    }

    @Test("Managed lifecycle operations fail closed when remote identifier is missing")
    @MainActor
    func managedLifecycleOperationsFailClosedWhenRemoteIdentifierIsMissing() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(
            name: "api",
            localPath: URL(fileURLWithPath: "/tmp/api"),
            remoteURL: "git@github.com:acme/api.git"
        )
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/api/workspaces/feature-a"),
            sourceRepo: repo,
            backendIdentifier: DaytonaBackend.identifier
        )
        context.insert(repo)
        context.insert(workspace)
        try context.save()

        let backend = MockRemoteBackend(
            identifier: DaytonaBackend.identifier,
            runtimeCapabilities: RuntimeCapabilities(
                supportsCreate: true,
                supportsDelete: true,
                supportsStartStop: true,
                supportsArchive: true,
                supportsList: true
            )
        )
        let controller = SidebarWorkspaceController(
            modelContext: context,
            workspaceService: MockWorkspaceService(),
            remoteBackendRegistry: MockRemoteBackendRegistry(
                backends: [DaytonaBackend.identifier: backend]
            )
        )

        await #expect(throws: RemoteWorkspaceError.self) {
            try await controller.stop(workspace)
        }
        await #expect(throws: RemoteWorkspaceError.self) {
            try await controller.start(workspace)
        }
        await #expect(throws: RemoteWorkspaceError.self) {
            try await controller.archive(workspace)
        }

        let fetchedWorkspace = try #require(
            context.fetch(FetchDescriptor<Workspace>()).first
        )
        #expect(fetchedWorkspace.status == .active)
        #expect(await backend.stopSandboxCallCount() == 0)
        #expect(await backend.startSandboxCallCount() == 0)
        #expect(await backend.archiveSandboxCallCount() == 0)
    }

    @MainActor
    private func makeModelContext() throws -> ModelContextFixture {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContextFixture(
            container: container,
            context: container.mainContext
        )
    }
}

private struct ModelContextFixture {
    let container: ModelContainer
    let context: ModelContext
}

private final class MockWorkspaceService: WorkspaceServiceProtocol, @unchecked Sendable {
    struct CreateWorkspaceCall: Sendable {
        let repoName: String
        let repoLocalURL: URL
        let name: String
    }

    var workspacesRoot: URL {
        get async { URL(fileURLWithPath: "/tmp/workspaces") }
    }

    var createWorkspaceResult = NewWorkspaceInfo(
        name: "feature-a",
        path: URL(fileURLWithPath: "/tmp/workspaces/feature-a"),
        gitBranch: "workspace/feature-a"
    )
    var createWorkspaceCalls: [CreateWorkspaceCall] = []
    var deleteWorkspaceCalls: [(workspaceURL: URL, deleteFiles: Bool)] = []

    func createWorkspace(
        repoName: String,
        repoLocalURL: URL,
        name: String,
        progress: WorkspaceCreationProgressHandler?
    ) async throws -> NewWorkspaceInfo {
        createWorkspaceCalls.append(
            CreateWorkspaceCall(repoName: repoName, repoLocalURL: repoLocalURL, name: name)
        )
        return createWorkspaceResult
    }

    func archiveWorkspace(at workspaceURL: URL) async throws {}

    func deleteWorkspace(at workspaceURL: URL, deleteFiles: Bool) async throws {
        deleteWorkspaceCalls.append((workspaceURL, deleteFiles))
    }

    func runLifecycleScript(_ scriptName: String, in directory: URL) async throws -> WorkspaceService.ScriptResult {
        WorkspaceService.ScriptResult(exitCode: 0, stdout: "", stderr: "")
    }

    func getWorkspaceSize(at workspaceURL: URL) async throws -> Int64 { 0 }

    func sanitizeFilename(_ name: String) async -> String { name }
}

private actor MockRemoteBackend: ProvisionCapable, StartStopCapable, Archivable, Listable {
    nonisolated let identifier: String
    nonisolated let runtimeCapabilities: RuntimeCapabilities
    private let healthCheckResult: Bool

    var createSandboxResult = RemoteSandboxInfo(sandboxId: "remote-123", sshCommand: "ssh remote")
    var createSandboxCalls: [(name: String, cloneURL: String?)] = []
    var deleteSandboxCalls: [String] = []
    var stopSandboxCalls: [String] = []
    var startSandboxCalls: [String] = []
    var archiveSandboxCalls: [String] = []
    var deleteSandboxError: (any Error)?

    init(
        identifier: String,
        runtimeCapabilities: RuntimeCapabilities,
        healthCheckResult: Bool = true
    ) {
        self.identifier = identifier
        self.runtimeCapabilities = runtimeCapabilities
        self.healthCheckResult = healthCheckResult
    }

    func healthCheck() async -> Bool { healthCheckResult }

    func openSession(for request: RemoteWorkspaceSessionRequest) async throws -> RemoteSandboxInfo {
        createSandboxResult
    }

    func createSandbox(name: String, cloneURL: String?) async throws -> RemoteSandboxInfo {
        createSandboxCalls.append((name, cloneURL))
        return createSandboxResult
    }

    func setCreateSandboxResult(_ result: RemoteSandboxInfo) {
        createSandboxResult = result
    }

    func createSandboxCallCount() -> Int {
        createSandboxCalls.count
    }

    func setDeleteSandboxError(_ error: (any Error)?) {
        deleteSandboxError = error
    }

    func deleteSandboxCallCount() -> Int {
        deleteSandboxCalls.count
    }

    func stopSandboxCallCount() -> Int {
        stopSandboxCalls.count
    }

    func startSandboxCallCount() -> Int {
        startSandboxCalls.count
    }

    func archiveSandboxCallCount() -> Int {
        archiveSandboxCalls.count
    }

    func deleteSandbox(sandboxId: String) async throws {
        deleteSandboxCalls.append(sandboxId)
        if let deleteSandboxError {
            throw deleteSandboxError
        }
    }

    func stopSandbox(sandboxId: String) async throws {
        stopSandboxCalls.append(sandboxId)
    }

    func startSandbox(sandboxId: String) async throws -> RemoteSandboxInfo {
        startSandboxCalls.append(sandboxId)
        return createSandboxResult
    }

    func archiveSandbox(sandboxId: String) async throws {
        archiveSandboxCalls.append(sandboxId)
    }

    func listSandboxes() async throws -> [RemoteSandboxStatus] { [] }
}

private enum TestBackendError: Error {
    case deleteFailed
}

private final class MockRemoteBackendRegistry: RemoteBackendRegistryProtocol, @unchecked Sendable {
    let creationBackendIdentifiers: [String]
    private let backends: [String: any RemoteBackendProtocol]

    init(
        creationBackendIdentifiers: [String] = [],
        backends: [String: any RemoteBackendProtocol] = [:]
    ) {
        self.creationBackendIdentifiers = creationBackendIdentifiers
        self.backends = backends
    }

    func backend(for identifier: String) -> (any RemoteBackendProtocol)? {
        backends[identifier]
    }
}
