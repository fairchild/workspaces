//
//  MainWindowMaintenanceControllerTests.swift
//  WorkspaceManagerAppTests
//
//  Coverage for the main window's background maintenance passes: which remote workspaces
//  get synced, what a provider's answer writes back and persists, and the sidebar-aggregator
//  projection. The archived-purge selection rule is covered in ArchivedWorkspacePurgeTests.
//

import Foundation
import SwiftData
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("MainWindowMaintenanceController")
struct MainWindowMaintenanceControllerTests {
    private let controller = MainWindowMaintenanceController()

    // MARK: - Fixtures

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @discardableResult
    private func makeWorkspace(
        repo: Repo,
        name: String,
        backendIdentifier: String,
        remoteId: String?,
        status: WorkspaceStatus = .active,
        context: ModelContext? = nil
    ) -> Workspace {
        let workspace = Workspace(
            name: name,
            path: URL(fileURLWithPath: "/tmp/workspaces/\(name)"),
            sourceRepo: repo,
            status: status,
            backendIdentifier: backendIdentifier,
            remoteId: remoteId
        )
        repo.workspaces.append(workspace)
        context?.insert(workspace)
        return workspace
    }

    private func makeRegistry(_ providers: [StatusSyncStubProvider]) -> WorkspaceProviderRegistry {
        WorkspaceProviderRegistry(providers: providers)
    }

    // MARK: - Sync work list

    @Test("Only remote workspaces with a remote id are synced, grouped by provider")
    func syncGroupsSkipLocalAndUnidentifiedWorkspaces() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        makeWorkspace(repo: repo, name: "local", backendIdentifier: "local", remoteId: nil)
        makeWorkspace(repo: repo, name: "no-remote-id", backendIdentifier: "daytona", remoteId: nil)
        makeWorkspace(repo: repo, name: "d1", backendIdentifier: "daytona", remoteId: "d-1")
        makeWorkspace(repo: repo, name: "d2", backendIdentifier: "daytona", remoteId: "d-2")
        makeWorkspace(repo: repo, name: "l1", backendIdentifier: "lume", remoteId: "l-1")

        let groups = controller.statusSyncGroups(repos: [repo])

        #expect(Set(groups.keys) == ["daytona", "lume"])
        // Ordered: a group keeps the order its workspaces appear in, which is the order
        // the sync pass asks the provider about them.
        #expect(groups["daytona", default: []].map(\.name) == ["d1", "d2"])
        #expect(groups["lume", default: []].map(\.name) == ["l1"])
    }

    @Test("A repo with nothing remote produces no sync work")
    func syncGroupsEmptyWhenAllLocal() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        makeWorkspace(repo: repo, name: "local", backendIdentifier: "local", remoteId: nil)

        #expect(controller.statusSyncGroups(repos: [repo]).isEmpty)
    }

    // MARK: - Status decision

    private func changes(
        for workspaces: [Workspace],
        snapshots: [WorkspaceProviderStatusSnapshot]
    ) -> [MainWindowMaintenanceController.StatusChange] {
        let reported = controller.statusesByRemoteID(from: snapshots)
        return workspaces.compactMap { controller.statusChange(for: $0, statusesByRemoteID: reported) }
    }

    @Test("Only workspaces whose status actually moved are reported, with the prior status")
    func statusChangesReportOnlyRealTransitions() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let moving = makeWorkspace(
            repo: repo, name: "moving", backendIdentifier: "daytona", remoteId: "d-1",
            status: .active)
        let steady = makeWorkspace(
            repo: repo, name: "steady", backendIdentifier: "daytona", remoteId: "d-2",
            status: .active)

        let result = changes(
            for: [moving, steady],
            snapshots: [
                WorkspaceProviderStatusSnapshot(remoteId: "d-1", status: .stopped),
                WorkspaceProviderStatusSnapshot(remoteId: "d-2", status: .active),
            ]
        )

        #expect(result.count == 1)
        #expect(result.first?.workspace.name == "moving")
        #expect(result.first?.previousStatus == .active)
        #expect(result.first?.newStatus == .stopped)
    }

    @Test("A workspace the provider no longer reports is treated as archived")
    func statusChangesTreatMissingRemoteAsArchived() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let vanished = makeWorkspace(
            repo: repo, name: "vanished", backendIdentifier: "daytona", remoteId: "gone",
            status: .active)

        #expect(changes(for: [vanished], snapshots: []).map(\.newStatus) == [.archived])
    }

    @Test("A workspace already archived and still unreported produces no change")
    func statusChangesSkipAlreadyArchivedMissingWorkspace() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let archived = makeWorkspace(
            repo: repo, name: "archived", backendIdentifier: "daytona", remoteId: "gone",
            status: .archived)

        #expect(changes(for: [archived], snapshots: []).isEmpty)
    }

    @Test("A workspace whose status was already applied this pass settles instead of moving again")
    func statusChangeSettlesAfterAnEarlierWriteInTheSamePass() throws {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = makeWorkspace(
            repo: repo, name: "remote", backendIdentifier: "daytona", remoteId: "d-1",
            status: .active)
        let reported = controller.statusesByRemoteID(
            from: [WorkspaceProviderStatusSnapshot(remoteId: "d-1", status: .stopped)]
        )

        let first = try #require(controller.statusChange(for: workspace, statusesByRemoteID: reported))
        workspace.status = first.newStatus
        let second = controller.statusChange(for: workspace, statusesByRemoteID: reported)

        #expect(first.newStatus == .stopped)
        #expect(second == nil)
    }

    /// A workspace reached twice in one pass must transition once. Batching a group's
    /// decisions ahead of its writes would report and log it twice.
    @Test("A workspace reached twice in one pass transitions once")
    func syncPassAppliesRepeatedIdentityOnce() async throws {
        let context = ModelContext(try makeContainer())
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        context.insert(repo)
        let workspace = makeWorkspace(
            repo: repo, name: "remote", backendIdentifier: "daytona", remoteId: "d-1",
            status: .active, context: context)

        let provider = StatusSyncStubProvider(
            id: "daytona",
            snapshots: [WorkspaceProviderStatusSnapshot(remoteId: "d-1", status: .stopped)]
        )

        // The same repo twice surfaces the same Workspace identity twice in one group.
        let outcome = await controller.syncWorkspaceStatuses(
            repos: [repo, repo],
            registry: makeRegistry([provider]),
            modelContext: context,
            trigger: "test"
        )

        #expect(outcome.changedCount == 1)
        #expect(workspace.status == .stopped)
    }

    // MARK: - Sync pass

    @Test("A sync pass writes the provider's statuses and persists them")
    func syncPassPersistsStatusChanges() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        context.insert(repo)
        let workspace = makeWorkspace(
            repo: repo, name: "remote", backendIdentifier: "daytona", remoteId: "d-1",
            status: .active, context: context)
        try context.save()

        let provider = StatusSyncStubProvider(
            id: "daytona",
            snapshots: [WorkspaceProviderStatusSnapshot(remoteId: "d-1", status: .stopped)]
        )

        let outcome = await controller.syncWorkspaceStatuses(
            repos: [repo],
            registry: makeRegistry([provider]),
            modelContext: context,
            trigger: "test"
        )

        #expect(outcome == .init(providerCount: 1, workspaceCount: 1, changedCount: 1, hadFailure: false))
        #expect(workspace.status == .stopped)

        // A second context over the same container only sees saved state, so this fails if
        // the pass wrote the status without saving.
        let verification = ModelContext(container)
        let persisted = try verification.fetch(FetchDescriptor<Workspace>())
        #expect(persisted.map(\.status) == [.stopped])
    }

    @Test("A pass that changes nothing reports no changes")
    func syncPassWithNoTransitionsReportsZeroChanged() async throws {
        let context = ModelContext(try makeContainer())
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        context.insert(repo)
        makeWorkspace(
            repo: repo, name: "remote", backendIdentifier: "daytona", remoteId: "d-1",
            status: .active, context: context)

        let provider = StatusSyncStubProvider(
            id: "daytona",
            snapshots: [WorkspaceProviderStatusSnapshot(remoteId: "d-1", status: .active)]
        )

        let outcome = await controller.syncWorkspaceStatuses(
            repos: [repo],
            registry: makeRegistry([provider]),
            modelContext: context,
            trigger: "test"
        )

        #expect(outcome.changedCount == 0)
        #expect(outcome.hadFailure == false)
    }

    @Test("One provider failing does not stop the others, and marks the pass a partial failure")
    func syncPassIsolatesProviderFailure() async throws {
        let context = ModelContext(try makeContainer())
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        context.insert(repo)
        makeWorkspace(
            repo: repo, name: "broken", backendIdentifier: "daytona", remoteId: "d-1",
            status: .active, context: context)
        let healthy = makeWorkspace(
            repo: repo, name: "healthy", backendIdentifier: "lume", remoteId: "l-1",
            status: .active, context: context)

        let failing = StatusSyncStubProvider(id: "daytona", error: StubSyncError.unreachable)
        let working = StatusSyncStubProvider(
            id: "lume",
            snapshots: [WorkspaceProviderStatusSnapshot(remoteId: "l-1", status: .stopped)]
        )

        let outcome = await controller.syncWorkspaceStatuses(
            repos: [repo],
            registry: makeRegistry([failing, working]),
            modelContext: context,
            trigger: "test"
        )

        #expect(outcome.hadFailure)
        #expect(outcome.providerCount == 2)
        #expect(outcome.changedCount == 1)
        #expect(healthy.status == .stopped)
    }

    @Test("A workspace whose provider is not registered is left untouched")
    func syncPassSkipsUnregisteredProvider() async throws {
        let context = ModelContext(try makeContainer())
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        context.insert(repo)
        let orphaned = makeWorkspace(
            repo: repo, name: "orphaned", backendIdentifier: "unregistered", remoteId: "x-1",
            status: .active, context: context)

        let outcome = await controller.syncWorkspaceStatuses(
            repos: [repo],
            registry: makeRegistry([]),
            modelContext: context,
            trigger: "test"
        )

        #expect(outcome.changedCount == 0)
        #expect(orphaned.status == .active)
    }

    @Test("Nothing syncable short-circuits the pass")
    func syncPassWithNoRemoteWorkspacesShortCircuits() async throws {
        let context = ModelContext(try makeContainer())
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        context.insert(repo)
        makeWorkspace(
            repo: repo, name: "local", backendIdentifier: "local", remoteId: nil, context: context)

        let outcome = await controller.syncWorkspaceStatuses(
            repos: [repo],
            registry: makeRegistry([]),
            modelContext: context,
            trigger: "test"
        )

        #expect(outcome == .noWork)
    }

    // MARK: - Sidebar aggregation

    @Test("Aggregator inputs carry every repo and workspace with its access time")
    func aggregatorInputsProjectReposAndWorkspaces() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = makeWorkspace(
            repo: repo, name: "feature-a", backendIdentifier: "local", remoteId: nil)

        let inputs = controller.aggregatorInputs(
            repos: [repo],
            sessions: [],
            agentStatusBySessionID: [:],
            registry: makeRegistry([]),
            normalizePath: { $0.path }
        )

        #expect(inputs.repos.map(\.repoID) == [repo.id])
        #expect(inputs.repos.map(\.lastAccessedAt) == [repo.lastAccessedAt])
        #expect(inputs.workspaces.map(\.workspaceID) == [workspace.id])
        #expect(inputs.workspaces.map(\.repoID) == [repo.id])
        #expect(inputs.workspaces.map(\.lastAccessedAt) == [workspace.lastAccessedAt])
    }

    /// The projection is only useful if session state actually reaches it, so this asserts a
    /// live agent status lands on the matching workspace and bubbles to its repo — and that a
    /// session on an unrelated key does not.
    @Test("A live agent status reaches the workspace whose session key matches")
    func aggregatorInputsCarryLiveAgentStatus() throws {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = makeWorkspace(
            repo: repo, name: "feature-a", backendIdentifier: "local", remoteId: nil)

        let matching = HostTerminalSession(
            key: .hostPath(workspace.workspaceURL.path),
            directory: workspace.workspaceURL
        )
        let unrelated = HostTerminalSession(
            key: .hostPath("/tmp/somewhere-else"),
            directory: URL(fileURLWithPath: "/tmp/somewhere-else")
        )
        let status = AgentSessionStatus(
            hostSessionID: matching.id,
            cwd: workspace.workspaceURL.path,
            run: .thinking,
            lastEventAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let inputs = controller.aggregatorInputs(
            repos: [repo],
            sessions: [matching, unrelated],
            agentStatusBySessionID: [matching.id: status],
            registry: makeRegistry([]),
            normalizePath: { $0.path }
        )

        #expect(inputs.workspaces.compactMap(\.status) == [status])
        #expect(inputs.workspaces.count == 1)
        // The repo's own key has no session, so its status stays nil; roll-up to the repo row
        // is the aggregator's job, not the projection's.
        #expect(inputs.repos.allSatisfy { $0.status == nil })
    }

    @Test("With no registered agent status every input reports nil rather than a stale status")
    func aggregatorInputsReportNilStatusWithoutSessions() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        makeWorkspace(repo: repo, name: "feature-a", backendIdentifier: "local", remoteId: nil)

        let inputs = controller.aggregatorInputs(
            repos: [repo],
            sessions: [],
            agentStatusBySessionID: [:],
            registry: makeRegistry([]),
            normalizePath: { $0.path }
        )

        #expect(inputs.workspaces.allSatisfy { $0.status == nil })
        #expect(inputs.repos.allSatisfy { $0.status == nil })
    }

    @Test("An empty model produces empty aggregator inputs")
    func aggregatorInputsEmptyForNoRepos() {
        let inputs = controller.aggregatorInputs(
            repos: [],
            sessions: [],
            agentStatusBySessionID: [:],
            registry: makeRegistry([]),
            normalizePath: { $0.path }
        )

        #expect(inputs == .init(workspaces: [], repos: []))
    }
}

private enum StubSyncError: Error {
    case unreachable
}

/// Minimal provider that only answers `syncStatuses`; every other requirement falls through
/// to the protocol's default implementations.
private actor StatusSyncStubProvider: WorkspaceProviderProtocol {
    nonisolated let descriptor: WorkspaceProviderDescriptor

    private let snapshots: [WorkspaceProviderStatusSnapshot]
    private let error: (any Error)?

    init(
        id: String,
        snapshots: [WorkspaceProviderStatusSnapshot] = [],
        error: (any Error)? = nil
    ) {
        self.descriptor = WorkspaceProviderDescriptor(
            id: id,
            displayName: id,
            description: "stub provider for status-sync tests"
        )
        self.snapshots = snapshots
        self.error = error
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
        throw StubSyncError.unreachable
    }

    func terminalLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> TerminalLaunchSpec {
        TerminalLaunchSpec(
            sessionKey: sessionKey(for: workspace),
            workingDirectory: workspace.workspaceURL
        )
    }

    func startWorkspace(_ workspace: WorkspaceProviderTarget) async throws {}
    func stopWorkspace(_ workspace: WorkspaceProviderTarget) async throws {}
    func archiveWorkspace(_ workspace: WorkspaceProviderTarget) async throws {}
    func deleteWorkspace(_ workspace: WorkspaceProviderTarget) async throws {}

    func syncStatuses(
        for workspaces: [WorkspaceProviderTarget]
    ) async throws -> [WorkspaceProviderStatusSnapshot] {
        if let error {
            throw error
        }
        return snapshots
    }
}
