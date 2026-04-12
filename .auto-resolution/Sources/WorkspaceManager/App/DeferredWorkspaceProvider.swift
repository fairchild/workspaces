import Foundation
import WorkspaceManagerCore

actor DeferredWorkspaceProvider: WorkspaceProviderProtocol {
    private let makeProvider: @Sendable () -> any WorkspaceProviderProtocol
    private let sessionKeyProvider: @Sendable (WorkspaceProviderTarget) -> HostTerminalSessionKey
    private var cachedProvider: (any WorkspaceProviderProtocol)?

    nonisolated let descriptor: WorkspaceProviderDescriptor

    init(
        descriptor: WorkspaceProviderDescriptor,
        sessionKeyProvider: @escaping @Sendable (WorkspaceProviderTarget) -> HostTerminalSessionKey,
        makeProvider: @escaping @Sendable () -> any WorkspaceProviderProtocol
    ) {
        self.descriptor = descriptor
        self.sessionKeyProvider = sessionKeyProvider
        self.makeProvider = makeProvider
    }

    func availability() async -> WorkspaceProviderAvailability {
        await resolvedProvider().availability()
    }

    nonisolated func sessionKey(for workspace: WorkspaceProviderTarget) -> HostTerminalSessionKey {
        sessionKeyProvider(workspace)
    }

    func createWorkspace(
        request: WorkspaceProviderCreationRequest,
        workspaceService: any WorkspaceServiceProtocol,
        progress: WorkspaceProviderProgressHandler?,
        persist: WorkspaceProviderPersistenceHandler?
    ) async throws -> WorkspaceProviderCreationResult {
        try await resolvedProvider().createWorkspace(
            request: request,
            workspaceService: workspaceService,
            progress: progress,
            persist: persist
        )
    }

    func terminalLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> TerminalLaunchSpec {
        try await resolvedProvider().terminalLaunchSpec(for: workspace)
    }

    func desktopLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> DesktopLaunchSpec {
        try await resolvedProvider().desktopLaunchSpec(for: workspace)
    }

    func startWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        try await resolvedProvider().startWorkspace(workspace)
    }

    func stopWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        try await resolvedProvider().stopWorkspace(workspace)
    }

    func archiveWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        try await resolvedProvider().archiveWorkspace(workspace)
    }

    func deleteWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        try await resolvedProvider().deleteWorkspace(workspace)
    }

    func syncStatuses(for workspaces: [WorkspaceProviderTarget]) async throws -> [WorkspaceProviderStatusSnapshot] {
        try await resolvedProvider().syncStatuses(for: workspaces)
    }

    private func resolvedProvider() -> any WorkspaceProviderProtocol {
        if let cachedProvider {
            return cachedProvider
        }

        let provider = makeProvider()
        cachedProvider = provider
        return provider
    }
}
