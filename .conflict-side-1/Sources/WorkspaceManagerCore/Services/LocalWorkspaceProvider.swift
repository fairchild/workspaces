//
//  LocalWorkspaceProvider.swift
//  WorkspaceManagerCore
//
//  Provider for standard host-backed workspaces.
//

import Foundation

public struct LocalWorkspaceProvider: WorkspaceProviderProtocol {
    public static let identifier = "local"
    public static let providerDescriptor = WorkspaceProviderDescriptor(
        id: LocalWorkspaceProvider.identifier,
        displayName: "Local",
        description: "Create a normal workspace on the host filesystem.",
        sheetStatusPolicy: .immediate,
        usesHostWorkspaceFiles: true
    )

    public let descriptor = LocalWorkspaceProvider.providerDescriptor

    public init() {}

    public func availability() async -> WorkspaceProviderAvailability {
        .available
    }

    public func sessionKey(for workspace: WorkspaceProviderTarget) -> HostTerminalSessionKey {
        .hostPath((workspace.localDirectoryURL ?? workspace.workspaceURL).path)
    }

    public func createWorkspace(
        request: WorkspaceProviderCreationRequest,
        workspaceService: any WorkspaceServiceProtocol,
        progress: WorkspaceProviderProgressHandler?,
        persist: WorkspaceProviderPersistenceHandler?
    ) async throws -> WorkspaceProviderCreationResult {
        let info = try await workspaceService.createWorkspace(
            repoName: request.repoName,
            repoLocalURL: request.repoLocalURL,
            name: request.workspaceName,
            progress: { phase in
                await progress?(Self.progressMessage(for: phase))
            }
        )

        return WorkspaceProviderCreationResult(
            name: info.name,
            path: info.path,
            gitBranch: info.gitBranch,
            status: .active,
            backendIdentifier: descriptor.id
        )
    }

    public func terminalLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> TerminalLaunchSpec {
        guard let localDirectoryURL = workspace.localDirectoryURL else {
            throw WorkspaceProviderError.invalidWorkspace("Local workspace is missing a host directory.")
        }

        return TerminalLaunchSpec(
            sessionKey: sessionKey(for: workspace),
            workingDirectory: localDirectoryURL
        )
    }

    static func progressMessage(for phase: WorkspaceCreationPhase) -> String {
        switch phase {
        case .preparing:
            return "Preparing workspace..."
        case .copyingRepository:
            return "Copying repository..."
        case .creatingBranch:
            return "Creating branch..."
        case .runningSetupScript:
            return "Running setup script..."
        case .finished:
            return "Finishing workspace..."
        }
    }
}
