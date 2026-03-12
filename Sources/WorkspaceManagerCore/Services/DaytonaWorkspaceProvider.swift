//
//  DaytonaWorkspaceProvider.swift
//  WorkspaceManagerCore
//
//  Provider wrapper for Daytona-backed cloud workspaces.
//

import Foundation

public actor DaytonaWorkspaceProvider: WorkspaceProviderProtocol {
    public static let identifier = "daytona"

    public nonisolated let descriptor = WorkspaceProviderDescriptor(
        id: DaytonaWorkspaceProvider.identifier,
        displayName: "Daytona",
        description: "Create a cloud Linux workspace and connect over SSH.",
        supportedGuestOS: [.linux],
        supportsArchive: true,
        requiresRemoteRepository: true
    )

    private let backend: any ProvisionCapable & StartStopCapable & Archivable & Listable

    public init(backend: any ProvisionCapable & StartStopCapable & Archivable & Listable = DaytonaBackend.shared) {
        self.backend = backend
    }

    public func availability() async -> WorkspaceProviderAvailability {
        if await backend.healthCheck() {
            return .available
        }

        return .unavailable("Add a Daytona API key and install uv to enable Daytona workspaces.")
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
        guard let cloneURL = request.repoRemoteURL, !cloneURL.isEmpty else {
            throw WorkspaceProviderError.unavailable(
                "Daytona workspaces require the repository to have a remote origin URL."
            )
        }

        await progress?("Creating cloud workspace...")
        let info = try await backend.createSandbox(name: request.workspaceName, cloneURL: cloneURL)

        return WorkspaceProviderCreationResult(
            name: request.workspaceName,
            path: FileManager.default.temporaryDirectory,
            persistedPath: Workspace.remotePathSentinel,
            status: .active,
            backendIdentifier: descriptor.id,
            remoteId: info.sandboxId
        )
    }

    public func terminalLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> TerminalLaunchSpec {
        guard let sandboxId = workspace.remoteId else {
            throw WorkspaceProviderError.invalidWorkspace("Daytona workspace is missing a sandbox ID.")
        }

        let info = try await backend.openSession(
            for: RemoteWorkspaceSessionRequest(
                workspaceID: workspace.id,
                name: workspace.name,
                backendIdentifier: descriptor.id,
                remoteId: sandboxId,
                sessionRoutingID: workspace.terminalSessionIdentifier,
                status: workspace.status,
                repoName: nil,
                repoRemoteURL: nil,
                sshMetadata: nil,
                composeMetadata: nil
            )
        )

        return TerminalLaunchSpec(
            sessionKey: sessionKey(for: workspace),
            workingDirectory: FileManager.default.temporaryDirectory,
            customCommand: info.sshCommand,
            statusAfterLaunch: .active
        )
    }

    public func startWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        guard let sandboxId = workspace.remoteId else {
            throw WorkspaceProviderError.invalidWorkspace("Daytona workspace is missing a sandbox ID.")
        }
        _ = try await backend.startSandbox(sandboxId: sandboxId)
    }

    public func stopWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        guard let sandboxId = workspace.remoteId else {
            throw WorkspaceProviderError.invalidWorkspace("Daytona workspace is missing a sandbox ID.")
        }
        try await backend.stopSandbox(sandboxId: sandboxId)
    }

    public func archiveWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        guard let sandboxId = workspace.remoteId else {
            throw WorkspaceProviderError.invalidWorkspace("Daytona workspace is missing a sandbox ID.")
        }
        try await backend.archiveSandbox(sandboxId: sandboxId)
    }

    public func deleteWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        guard let sandboxId = workspace.remoteId else { return }
        try await backend.deleteSandbox(sandboxId: sandboxId)
    }

    public func syncStatuses(
        for workspaces: [WorkspaceProviderTarget]
    ) async throws -> [WorkspaceProviderStatusSnapshot] {
        let statuses = try await backend.listSandboxes()

        return statuses.map { status in
            WorkspaceProviderStatusSnapshot(
                remoteId: status.sandboxId,
                status: Self.mapStatus(status.state)
            )
        }
    }

    static func mapStatus(_ rawValue: String) -> WorkspaceStatus {
        switch rawValue {
        case "started", "starting":
            return .active
        case "stopped", "stopping":
            return .stopped
        case "archived", "archiving":
            return .archived
        default:
            return .archived
        }
    }
}
