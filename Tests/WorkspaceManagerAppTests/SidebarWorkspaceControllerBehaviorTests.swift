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
        let controller = makeController(
            context: context,
            workspaceService: workspaceService,
            providers: [LocalWorkspaceProvider()]
        )

        let workspace = try await controller.createWorkspace(
            from: repo,
            name: "feature-a",
            providerID: LocalWorkspaceProvider.identifier
        )

        #expect(workspaceService.createWorkspaceCalls.count == 1)
        #expect(workspace.backendIdentifier == LocalWorkspaceProvider.identifier)
        #expect(workspace.gitBranch == "workspace/feature-a")
        #expect(workspace.remoteId == nil)
    }

    @Test("Remote request routes through workspace provider")
    @MainActor
    func remoteRequestRoutesThroughWorkspaceProvider() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(
            name: "api",
            localPath: URL(fileURLWithPath: "/tmp/api"),
            remoteURL: "git@github.com:acme/api.git"
        )
        context.insert(repo)

        let provider = MockWorkspaceProvider(
            descriptor: WorkspaceProviderDescriptor(
                id: DaytonaWorkspaceProvider.identifier,
                displayName: "Daytona",
                description: "Remote Linux workspaces.",
                supportsArchive: true,
                requiresRemoteRepository: true
            )
        )
        await provider.setCreateResult(
            WorkspaceProviderCreationResult(
                name: "feature-a",
                path: URL(fileURLWithPath: "/tmp/api/workspaces/feature-a"),
                status: .active,
                backendIdentifier: DaytonaWorkspaceProvider.identifier,
                remoteId: "daytona-123"
            )
        )
        let controller = makeController(
            context: context,
            workspaceService: MockWorkspaceService(),
            providers: [LocalWorkspaceProvider(), provider]
        )

        let workspace = try await controller.createWorkspace(
            from: repo,
            name: "feature-a",
            providerID: DaytonaWorkspaceProvider.identifier
        )

        #expect(await provider.createCallCount() == 1)
        #expect(workspace.backendIdentifier == DaytonaWorkspaceProvider.identifier)
        #expect(workspace.remoteId == "daytona-123")
    }

    @Test("Generated local names auto-adjust when a tracked workspace already exists")
    @MainActor
    func generatedLocalNamesAutoAdjustForTrackedDuplicates() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(name: "api", localPath: URL(fileURLWithPath: "/tmp/api"))
        let existingWorkspace = Workspace(
            name: "solar-otter",
            path: URL(fileURLWithPath: "/tmp/workspaces/api/solar-otter"),
            sourceRepo: repo
        )
        context.insert(repo)
        context.insert(existingWorkspace)
        try context.save()

        let workspaceService = MockWorkspaceService()
        let controller = makeController(
            context: context,
            workspaceService: workspaceService,
            providers: [LocalWorkspaceProvider()]
        )

        let workspace = try await controller.createWorkspace(
            from: repo,
            name: "solar-otter",
            nameSource: .generatedDefault,
            providerID: LocalWorkspaceProvider.identifier
        )

        #expect(workspace.name == "solar-otter-2")
        #expect(workspaceService.createWorkspaceCalls.map(\.name) == ["solar-otter-2"])
    }

    @Test("Generated local names auto-adjust when only the directory exists on disk")
    @MainActor
    func generatedLocalNamesAutoAdjustForDirectoryDuplicates() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let tempRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repo = Repo(name: "api", localPath: URL(fileURLWithPath: "/tmp/api"))
        context.insert(repo)
        try context.save()

        let occupiedDirectory =
            tempRoot
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("solar-otter", isDirectory: true)
        try FileManager.default.createDirectory(
            at: occupiedDirectory,
            withIntermediateDirectories: true
        )

        let workspaceService = MockWorkspaceService()
        workspaceService.workspacesRootValue = tempRoot
        let controller = makeController(
            context: context,
            workspaceService: workspaceService,
            providers: [LocalWorkspaceProvider()]
        )

        let workspace = try await controller.createWorkspace(
            from: repo,
            name: "solar-otter",
            nameSource: .generatedDefault,
            providerID: LocalWorkspaceProvider.identifier
        )

        #expect(workspace.name == "solar-otter-2")
        #expect(workspaceService.createWorkspaceCalls.map(\.name) == ["solar-otter-2"])
    }

    @Test("Manual duplicate names fail before local creation starts")
    @MainActor
    func manualDuplicateNamesFailBeforeLocalCreation() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(name: "api", localPath: URL(fileURLWithPath: "/tmp/api"))
        let existingWorkspace = Workspace(
            name: "My Feature",
            path: URL(fileURLWithPath: "/tmp/workspaces/api/my-feature"),
            sourceRepo: repo
        )
        context.insert(repo)
        context.insert(existingWorkspace)
        try context.save()

        let workspaceService = MockWorkspaceService()
        let controller = makeController(
            context: context,
            workspaceService: workspaceService,
            providers: [LocalWorkspaceProvider()]
        )

        await #expect(throws: WorkspaceError.self) {
            _ = try await controller.createWorkspace(
                from: repo,
                name: "my-feature",
                nameSource: .manual,
                providerID: LocalWorkspaceProvider.identifier
            )
        }

        #expect(workspaceService.createWorkspaceCalls.isEmpty)
    }

    @Test("Generated provider names are resolved before provider creation")
    @MainActor
    func generatedProviderNamesResolveBeforeProviderCreation() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(
            name: "api",
            localPath: URL(fileURLWithPath: "/tmp/api"),
            remoteURL: "git@github.com:acme/api.git"
        )
        let existingWorkspace = Workspace(
            name: "solar-otter",
            path: URL(fileURLWithPath: "/tmp/workspaces/api/solar-otter"),
            sourceRepo: repo
        )
        context.insert(repo)
        context.insert(existingWorkspace)
        try context.save()

        let provider = MockWorkspaceProvider(
            descriptor: WorkspaceProviderDescriptor(
                id: DaytonaWorkspaceProvider.identifier,
                displayName: "Daytona",
                description: "Remote Linux workspaces.",
                supportsArchive: true,
                requiresRemoteRepository: true
            )
        )
        let controller = makeController(
            context: context,
            workspaceService: MockWorkspaceService(),
            providers: [LocalWorkspaceProvider(), provider]
        )

        let workspace = try await controller.createWorkspace(
            from: repo,
            name: "solar-otter",
            nameSource: .generatedDefault,
            providerID: DaytonaWorkspaceProvider.identifier
        )

        let createRequests = await provider.createRequestsSnapshot()
        #expect(createRequests.map(\.workspaceName) == ["solar-otter-2"])
        #expect(workspace.name == "solar-otter-2")
    }

    @Test("Concurrent generated local creates reserve distinct names")
    @MainActor
    func concurrentGeneratedLocalCreatesReserveDistinctNames() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(name: "api", localPath: URL(fileURLWithPath: "/tmp/api"))
        context.insert(repo)
        try context.save()

        let workspaceService = MockWorkspaceService()
        let gate = NameReservationGate(targetCount: 2)
        workspaceService.createWorkspaceDelay = {
            await gate.wait()
        }
        let controller = makeController(
            context: context,
            workspaceService: workspaceService,
            providers: [LocalWorkspaceProvider()]
        )

        async let firstWorkspace = controller.createWorkspace(
            from: repo,
            name: "solar-otter",
            nameSource: .generatedDefault,
            providerID: LocalWorkspaceProvider.identifier
        )
        async let secondWorkspace = controller.createWorkspace(
            from: repo,
            name: "solar-otter",
            nameSource: .generatedDefault,
            providerID: LocalWorkspaceProvider.identifier
        )

        let first = try await firstWorkspace
        let second = try await secondWorkspace
        let names = [first.name, second.name].sorted()

        #expect(names == ["solar-otter", "solar-otter-2"])
        #expect(workspaceService.createWorkspaceCalls.map(\.name).sorted() == names)
    }

    @Test("Deleting host-backed provider workspace removes local files after provider cleanup")
    @MainActor
    func deletingHostBackedProviderWorkspaceRemovesLocalFilesAfterProviderCleanup() async throws {
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
            backendIdentifier: LumeWorkspaceProvider.identifier,
            remoteId: "lume-123"
        )
        context.insert(repo)
        context.insert(workspace)
        try context.save()

        let workspaceService = MockWorkspaceService()
        let provider = MockWorkspaceProvider(
            descriptor: WorkspaceProviderDescriptor(
                id: LumeWorkspaceProvider.identifier,
                displayName: "Lume",
                description: "Local macOS and Linux VMs.",
                supportedGuestOS: [.macOS, .linux],
                supportsDesktop: true,
                usesHostWorkspaceFiles: true
            )
        )
        let controller = makeController(
            context: context,
            workspaceService: workspaceService,
            providers: [LocalWorkspaceProvider(), provider]
        )

        try await controller.deleteWorkspace(workspace, deleteFiles: true)

        let fetchedWorkspaces = try context.fetch(FetchDescriptor<Workspace>())
        #expect(fetchedWorkspaces.isEmpty)
        #expect(await provider.deleteCallCount() == 1)
        #expect(workspaceService.deleteWorkspaceCalls.count == 1)
        #expect(workspaceService.deleteWorkspaceCalls.first?.deleteFiles == true)
    }

    @Test("Deleting remote workspace preserves the record when provider deletion fails")
    @MainActor
    func deletingRemoteWorkspacePreservesRecordWhenProviderDeletionFails() async throws {
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
            backendIdentifier: DaytonaWorkspaceProvider.identifier,
            remoteId: "daytona-123"
        )
        context.insert(repo)
        context.insert(workspace)
        try context.save()

        let provider = MockWorkspaceProvider(
            descriptor: WorkspaceProviderDescriptor(
                id: DaytonaWorkspaceProvider.identifier,
                displayName: "Daytona",
                description: "Remote Linux workspaces.",
                supportsArchive: true,
                requiresRemoteRepository: true
            )
        )
        await provider.setDeleteError(TestWorkspaceProviderError.deleteFailed)
        let controller = makeController(
            context: context,
            workspaceService: MockWorkspaceService(),
            providers: [LocalWorkspaceProvider(), provider]
        )

        await #expect(throws: TestWorkspaceProviderError.self) {
            try await controller.deleteWorkspace(workspace, deleteFiles: false)
        }

        let fetchedWorkspaces = try context.fetch(FetchDescriptor<Workspace>())
        #expect(fetchedWorkspaces.count == 1)
        #expect(await provider.deleteCallCount() == 1)
    }

    @Test("Deleting remote workspace fails closed when remote identifier is missing")
    @MainActor
    func deletingRemoteWorkspaceFailsClosedWhenRemoteIdentifierIsMissing() async throws {
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
            backendIdentifier: DaytonaWorkspaceProvider.identifier
        )
        context.insert(repo)
        context.insert(workspace)
        try context.save()

        let provider = MockWorkspaceProvider(
            descriptor: WorkspaceProviderDescriptor(
                id: DaytonaWorkspaceProvider.identifier,
                displayName: "Daytona",
                description: "Remote Linux workspaces.",
                supportsArchive: true,
                requiresRemoteRepository: true
            ),
            requiresRemoteIdentifier: true
        )
        let controller = makeController(
            context: context,
            workspaceService: MockWorkspaceService(),
            providers: [LocalWorkspaceProvider(), provider]
        )

        do {
            try await controller.deleteWorkspace(workspace, deleteFiles: false)
            Issue.record("Expected delete to fail when remoteId is missing")
        } catch let error as WorkspaceProviderError {
            guard case .invalidWorkspace(let message) = error else {
                Issue.record("Expected invalidWorkspace error, got \(error)")
                return
            }
            #expect(message.contains("remote identifier"))
        } catch {
            Issue.record("Expected WorkspaceProviderError.invalidWorkspace, got \(error)")
        }

        let fetchedWorkspaces = try context.fetch(FetchDescriptor<Workspace>())
        #expect(fetchedWorkspaces.count == 1)
        #expect(await provider.deleteCallCount() == 0)
    }

    @Test("Lifecycle operations update status through provider")
    @MainActor
    func lifecycleOperationsUpdateStatusThroughProvider() async throws {
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
            status: .stopped,
            backendIdentifier: DaytonaWorkspaceProvider.identifier,
            remoteId: "daytona-123"
        )
        context.insert(repo)
        context.insert(workspace)
        try context.save()

        let provider = MockWorkspaceProvider(
            descriptor: WorkspaceProviderDescriptor(
                id: DaytonaWorkspaceProvider.identifier,
                displayName: "Daytona",
                description: "Remote Linux workspaces.",
                supportsArchive: true,
                requiresRemoteRepository: true
            ),
            requiresRemoteIdentifier: true
        )
        let controller = makeController(
            context: context,
            workspaceService: MockWorkspaceService(),
            providers: [LocalWorkspaceProvider(), provider]
        )

        try await controller.start(workspace)
        #expect(workspace.status == .active)
        try await controller.stop(workspace)
        #expect(workspace.status == .stopped)
        try await controller.archive(workspace)
        #expect(workspace.status == .archived)
        #expect(await provider.startCallCount() == 1)
        #expect(await provider.stopCallCount() == 1)
        #expect(await provider.archiveCallCount() == 1)
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
            backendIdentifier: DaytonaWorkspaceProvider.identifier
        )
        context.insert(repo)
        context.insert(workspace)
        try context.save()

        let provider = MockWorkspaceProvider(
            descriptor: WorkspaceProviderDescriptor(
                id: DaytonaWorkspaceProvider.identifier,
                displayName: "Daytona",
                description: "Remote Linux workspaces.",
                supportsArchive: true,
                requiresRemoteRepository: true
            ),
            requiresRemoteIdentifier: true
        )
        let controller = makeController(
            context: context,
            workspaceService: MockWorkspaceService(),
            providers: [LocalWorkspaceProvider(), provider]
        )

        await #expect(throws: WorkspaceProviderError.self) {
            try await controller.stop(workspace)
        }
        await #expect(throws: WorkspaceProviderError.self) {
            try await controller.start(workspace)
        }
        await #expect(throws: WorkspaceProviderError.self) {
            try await controller.archive(workspace)
        }

        let fetchedWorkspace = try #require(context.fetch(FetchDescriptor<Workspace>()).first)
        #expect(fetchedWorkspace.status == .active)
        #expect(await provider.stopCallCount() == 0)
        #expect(await provider.startCallCount() == 0)
        #expect(await provider.archiveCallCount() == 0)
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

    @MainActor
    private func makeController(
        context: ModelContext,
        workspaceService: MockWorkspaceService,
        providers: [any WorkspaceProviderProtocol]
    ) -> SidebarWorkspaceController {
        SidebarWorkspaceController(
            modelContext: context,
            workspaceService: workspaceService,
            workspaceProviderRegistry: WorkspaceProviderRegistry(providers: providers),
            telemetryService: .disabled
        )
    }

    @MainActor
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarWorkspaceControllerBehaviorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    var workspacesRootValue = URL(fileURLWithPath: "/tmp/workspaces")
    var workspacesRoot: URL {
        get async { workspacesRootValue }
    }

    var createWorkspaceResult: NewWorkspaceInfo?
    var createWorkspaceCalls: [CreateWorkspaceCall] = []
    var deleteWorkspaceCalls: [(workspaceURL: URL, deleteFiles: Bool)] = []
    var createWorkspaceDelay: @Sendable () async -> Void = {}

    func createWorkspace(
        repoName: String,
        repoLocalURL: URL,
        name: String,
        progress: WorkspaceCreationProgressHandler?
    ) async throws -> NewWorkspaceInfo {
        createWorkspaceCalls.append(
            CreateWorkspaceCall(repoName: repoName, repoLocalURL: repoLocalURL, name: name)
        )
        await createWorkspaceDelay()
        if let createWorkspaceResult {
            return createWorkspaceResult
        }

        let sanitizedName = WorkspaceService.sanitizeWorkspaceNameComponent(name)
        return NewWorkspaceInfo(
            name: name,
            path:
                workspacesRootValue
                .appendingPathComponent(repoName, isDirectory: true)
                .appendingPathComponent(sanitizedName, isDirectory: true),
            gitBranch: "workspace/\(sanitizedName)"
        )
    }

    func archiveWorkspace(at workspaceURL: URL) async throws {}

    func deleteWorkspace(at workspaceURL: URL, deleteFiles: Bool) async throws {
        deleteWorkspaceCalls.append((workspaceURL, deleteFiles))
    }

    func runLifecycleScript(
        _ scriptName: String,
        in directory: URL
    ) async throws -> WorkspaceService.ScriptResult {
        WorkspaceService.ScriptResult(exitCode: 0, stdout: "", stderr: "")
    }

    func getWorkspaceSize(at workspaceURL: URL) async throws -> Int64 { 0 }

    func sanitizeFilename(_ name: String) async -> String { name }
}

private actor NameReservationGate {
    private let targetCount: Int
    private var arrivals = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(targetCount: Int) {
        self.targetCount = targetCount
    }

    func wait() async {
        arrivals += 1
        guard arrivals < targetCount else {
            let pendingContinuations = continuations
            continuations.removeAll()
            for continuation in pendingContinuations {
                continuation.resume()
            }
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private actor MockWorkspaceProvider: WorkspaceProviderProtocol {
    nonisolated let descriptor: WorkspaceProviderDescriptor

    private let requiresRemoteIdentifier: Bool
    private var createResult: WorkspaceProviderCreationResult?
    private var createError: (any Error)?
    private var deleteError: (any Error)?
    private var startError: (any Error)?
    private var stopError: (any Error)?
    private var archiveError: (any Error)?
    private var createRequests: [WorkspaceProviderCreationRequest] = []
    private var deleteTargets: [WorkspaceProviderTarget] = []
    private var startTargets: [WorkspaceProviderTarget] = []
    private var stopTargets: [WorkspaceProviderTarget] = []
    private var archiveTargets: [WorkspaceProviderTarget] = []

    init(
        descriptor: WorkspaceProviderDescriptor,
        requiresRemoteIdentifier: Bool = false
    ) {
        self.descriptor = descriptor
        self.requiresRemoteIdentifier = requiresRemoteIdentifier
    }

    func availability() async -> WorkspaceProviderAvailability {
        WorkspaceProviderAvailability(isAvailable: true)
    }

    nonisolated func sessionKey(for workspace: WorkspaceProviderTarget) -> HostTerminalSessionKey {
        .backendSession(providerID: descriptor.id, instanceID: workspace.terminalSessionIdentifier)
    }

    func createWorkspace(
        request: WorkspaceProviderCreationRequest,
        workspaceService: any WorkspaceServiceProtocol,
        progress: WorkspaceProviderProgressHandler?,
        persist: WorkspaceProviderPersistenceHandler?
    ) async throws -> WorkspaceProviderCreationResult {
        if let createError {
            throw createError
        }
        createRequests.append(request)
        if let createResult {
            return createResult
        }

        let sanitizedName = WorkspaceService.sanitizeWorkspaceNameComponent(request.workspaceName)
        return WorkspaceProviderCreationResult(
            name: request.workspaceName,
            path: URL(fileURLWithPath: "/tmp/workspaces/\(sanitizedName)"),
            status: .active,
            backendIdentifier: descriptor.id,
            remoteId: "\(descriptor.id)-123"
        )
    }

    func terminalLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> TerminalLaunchSpec {
        TerminalLaunchSpec(
            sessionKey: .backendSession(providerID: descriptor.id, instanceID: workspace.terminalSessionIdentifier),
            workingDirectory: workspace.workspaceURL
        )
    }

    func startWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        try requireRemoteIdentifierIfNeeded(for: workspace)
        startTargets.append(workspace)
        if let startError {
            throw startError
        }
    }

    func stopWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        try requireRemoteIdentifierIfNeeded(for: workspace)
        stopTargets.append(workspace)
        if let stopError {
            throw stopError
        }
    }

    func archiveWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        try requireRemoteIdentifierIfNeeded(for: workspace)
        archiveTargets.append(workspace)
        if let archiveError {
            throw archiveError
        }
    }

    func deleteWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        try requireRemoteIdentifierIfNeeded(for: workspace)
        deleteTargets.append(workspace)
        if let deleteError {
            throw deleteError
        }
    }

    func setCreateResult(_ result: WorkspaceProviderCreationResult) {
        createResult = result
    }

    func setDeleteError(_ error: (any Error)?) {
        deleteError = error
    }

    func createRequestsSnapshot() -> [WorkspaceProviderCreationRequest] {
        createRequests
    }

    func createCallCount() -> Int {
        createRequests.count
    }

    func deleteCallCount() -> Int {
        deleteTargets.count
    }

    func startCallCount() -> Int {
        startTargets.count
    }

    func stopCallCount() -> Int {
        stopTargets.count
    }

    func archiveCallCount() -> Int {
        archiveTargets.count
    }

    private func requireRemoteIdentifierIfNeeded(for workspace: WorkspaceProviderTarget) throws {
        if requiresRemoteIdentifier, workspace.remoteId == nil {
            throw WorkspaceProviderError.invalidWorkspace("Workspace is missing a remote identifier.")
        }
    }
}

private enum TestWorkspaceProviderError: Error {
    case deleteFailed
}
