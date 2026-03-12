//
//  SidebarWorkspaceController.swift
//  WorkspaceManager
//

import Foundation
import SwiftData
import WorkspaceManagerCore

@MainActor
struct SidebarWorkspaceController {
    enum ControllerError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message):
                return message
            }
        }
    }

    let modelContext: ModelContext
    let workspaceService: any WorkspaceServiceProtocol
    let remoteBackendRegistry: any RemoteBackendRegistryProtocol

    nonisolated static func preferredRepoForNewWorkspace(
        selectedWorkspace: Workspace?,
        activeSessionKey: HostTerminalSessionKey?,
        repos: [Repo],
        normalizeRepoPath: (URL) -> String
    ) -> Repo? {
        if let selectedWorkspace {
            return selectedWorkspace.sourceRepo
        }

        if case .repoPath(let activeRepoPath) = activeSessionKey {
            let normalizedActiveRepoPath = normalizeRepoPath(URL(fileURLWithPath: activeRepoPath))
            if let matchedRepo = repos.first(where: {
                normalizeRepoPath($0.localURL) == normalizedActiveRepoPath
            }) {
                return matchedRepo
            }
        }

        return repos.first
    }

    nonisolated static func cleanupRemoteSandboxAfterFailedPersistence(
        sandboxId: String,
        deleteSandbox: @Sendable (String) async throws -> Void
    ) async -> Error? {
        do {
            try await deleteSandbox(sandboxId)
            return nil
        } catch {
            return error
        }
    }

    nonisolated static func remoteWorkspacePersistenceFailureMessage(
        existingMessage: String?,
        cleanupMessage: String
    ) -> String {
        if let existingMessage, !existingMessage.isEmpty {
            return "\(existingMessage)\n\n\(cleanupMessage)"
        }

        return cleanupMessage
    }

    nonisolated static func remoteWorkspacePersistenceFailureMessage(
        existingMessage: String?,
        sandboxId: String,
        cleanupError: Error
    ) -> String {
        remoteWorkspacePersistenceFailureMessage(
            existingMessage: existingMessage,
            cleanupMessage:
                "Cleanup also failed for remote workspace '\(sandboxId)': \(cleanupError.localizedDescription)"
        )
    }

    nonisolated static func localCreationMessage(for phase: WorkspaceCreationPhase) -> String {
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

    func createWorkspace(
        from repo: Repo,
        request: NewWorkspaceRequest,
        progress: WorkspaceCreationProgressHandler? = nil
    ) async throws -> Workspace {
        switch request.backend {
        case .local:
            return try await createLocalWorkspace(from: repo, name: request.name, progress: progress)
        case .daytona:
            return try await createDaytonaWorkspace(from: repo, name: request.name)
        case .sshHost(let sshRequest):
            return try createSSHWorkspace(from: repo, name: request.name, request: sshRequest)
        }
    }

    func deleteWorkspace(_ workspace: Workspace, deleteFiles: Bool) async throws {
        if workspace.isRemote {
            let backend = try remoteBackend(for: workspace)
            if backend.runtimeCapabilities.supportsDelete {
                let remoteId = try requiredRemoteIdentifier(for: workspace)
                let provisionableBackend = try provisioningBackend(
                    identifier: workspace.backendIdentifier,
                    requiresDelete: true,
                    operation: "deleting remote workspaces"
                )
                try await provisionableBackend.deleteSandbox(sandboxId: remoteId)
            }
        } else {
            try await workspaceService.deleteWorkspace(at: workspace.workspaceURL, deleteFiles: deleteFiles)
        }

        modelContext.delete(workspace)
        try saveModelContext(action: "update workspace list")
    }

    func stop(_ workspace: Workspace) async throws {
        let backend = try startStopBackend(for: workspace, operation: "stopping remote workspaces")
        let remoteId = try requiredRemoteIdentifier(for: workspace)
        try await backend.stopSandbox(sandboxId: remoteId)
        workspace.status = .stopped
        try saveModelContext(action: "stop remote workspace")
    }

    func start(_ workspace: Workspace) async throws {
        let backend = try startStopBackend(for: workspace, operation: "starting remote workspaces")
        let remoteId = try requiredRemoteIdentifier(for: workspace)
        _ = try await backend.startSandbox(sandboxId: remoteId)
        workspace.status = .active
        try saveModelContext(action: "start remote workspace")
    }

    func archive(_ workspace: Workspace) async throws {
        let backend = try archivableBackend(for: workspace, operation: "archiving remote workspaces")
        let remoteId = try requiredRemoteIdentifier(for: workspace)
        try await backend.archiveSandbox(sandboxId: remoteId)
        workspace.status = .archived
        try saveModelContext(action: "archive remote workspace")
    }

    private func createLocalWorkspace(
        from repo: Repo,
        name: String,
        progress: WorkspaceCreationProgressHandler? = nil
    ) async throws -> Workspace {
        let info = try await workspaceService.createWorkspace(
            repoName: repo.name,
            repoLocalURL: repo.localURL,
            name: name,
            progress: progress
        )

        let workspace = Workspace(
            name: info.name,
            path: info.path,
            sourceRepo: repo,
            gitBranch: info.gitBranch
        )
        modelContext.insert(workspace)

        do {
            try saveModelContext(action: "save workspace")
            return workspace
        } catch {
            Self.cleanupWorkspaceDirectoryAfterFailedPersistence(info.path)
            throw error
        }
    }

    private func createDaytonaWorkspace(
        from repo: Repo,
        name: String
    ) async throws -> Workspace {
        let backend = try provisioningBackend(
            identifier: DaytonaBackend.identifier,
            requiresCreate: true,
            operation: "creating Daytona workspaces"
        )

        guard await backend.healthCheck() else {
            throw BackendError.notAvailable("Daytona")
        }

        let info = try await backend.createSandbox(name: name, cloneURL: repo.remoteURL)
        let workspace = Workspace(
            name: name,
            path: FileManager.default.temporaryDirectory,
            sourceRepo: repo,
            backendIdentifier: DaytonaBackend.identifier,
            remoteId: info.sandboxId
        )
        modelContext.insert(workspace)

        do {
            try saveModelContext(action: "save remote workspace")
            return workspace
        } catch {
            if let cleanupError = await Self.cleanupRemoteSandboxAfterFailedPersistence(
                sandboxId: info.sandboxId,
                deleteSandbox: { sandboxId in
                    try await backend.deleteSandbox(sandboxId: sandboxId)
                }
            ) {
                NSLog(
                    "[RemoteBackend] Failed to clean up workspace %@ after persistence failure: %@",
                    info.sandboxId,
                    cleanupError.localizedDescription
                )
                throw ControllerError.message(
                    Self.remoteWorkspacePersistenceFailureMessage(
                        existingMessage: error.localizedDescription,
                        sandboxId: info.sandboxId,
                        cleanupError: cleanupError
                    )
                )
            }
            throw error
        }
    }

    private func createSSHWorkspace(
        from repo: Repo,
        name: String,
        request: SSHHostWorkspaceRequest
    ) throws -> Workspace {
        let sanitizedName = WorkspaceService.sanitizeWorkspaceNameComponent(name)
        guard WorkspaceService.isValidWorkspaceNameComponent(sanitizedName) else {
            throw WorkspaceError.invalidName(name: name)
        }
        guard (1...65535).contains(request.ssh.port) else {
            throw RemoteWorkspaceError.invalidSSHConfiguration(
                "port must be between 1 and 65535"
            )
        }

        guard remoteBackendRegistry.backend(for: SSHBackend.identifier) != nil else {
            throw ControllerError.message(
                RemoteWorkspaceError.backendNotRegistered(SSHBackend.identifier).localizedDescription
            )
        }

        let trimmedRemoteURL = repo.remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedRemoteURL?.isEmpty == false else {
            throw ControllerError.message(RemoteWorkspaceError.missingRemoteURL.localizedDescription)
        }

        let workspace = Workspace(
            name: name,
            path: FileManager.default.temporaryDirectory,
            sourceRepo: repo,
            backendIdentifier: SSHBackend.identifier,
            remoteId: UUID().uuidString
        )
        workspace.sshMetadata = request.ssh
        workspace.composeMetadata = request.compose

        modelContext.insert(workspace)
        try saveModelContext(action: "save SSH workspace")
        return workspace
    }

    private func remoteBackend(for identifier: String) throws -> any RemoteBackendProtocol {
        guard let backend = remoteBackendRegistry.backend(for: identifier) else {
            throw ControllerError.message(
                RemoteWorkspaceError.backendNotRegistered(identifier).localizedDescription
            )
        }
        return backend
    }

    private func remoteBackend(for workspace: Workspace) throws -> any RemoteBackendProtocol {
        try remoteBackend(for: workspace.backendIdentifier)
    }

    private func provisioningBackend(
        identifier: String,
        requiresCreate: Bool = false,
        requiresDelete: Bool = false,
        operation: String
    ) throws -> any ProvisionCapable {
        let backend = try remoteBackend(for: identifier)
        let capabilities = backend.runtimeCapabilities

        guard
            (!requiresCreate || capabilities.supportsCreate)
                && (!requiresDelete || capabilities.supportsDelete)
        else {
            throw ControllerError.message(
                RemoteBackendCapabilityError.unsupportedOperation(
                    backendIdentifier: identifier,
                    operation: operation
                ).localizedDescription
            )
        }

        guard let provisionableBackend = backend as? any ProvisionCapable else {
            throw ControllerError.message(
                RemoteBackendCapabilityError.unsupportedOperation(
                    backendIdentifier: identifier,
                    operation: operation
                ).localizedDescription
            )
        }

        return provisionableBackend
    }

    private func startStopBackend(
        for workspace: Workspace,
        operation: String
    ) throws -> any StartStopCapable {
        let backend = try remoteBackend(for: workspace)
        guard backend.runtimeCapabilities.supportsStartStop,
            let startStopBackend = backend as? any StartStopCapable
        else {
            throw ControllerError.message(
                RemoteBackendCapabilityError.unsupportedOperation(
                    backendIdentifier: workspace.backendIdentifier,
                    operation: operation
                ).localizedDescription
            )
        }

        return startStopBackend
    }

    private func archivableBackend(
        for workspace: Workspace,
        operation: String
    ) throws -> any Archivable {
        let backend = try remoteBackend(for: workspace)
        guard backend.runtimeCapabilities.supportsArchive,
            let archivableBackend = backend as? any Archivable
        else {
            throw ControllerError.message(
                RemoteBackendCapabilityError.unsupportedOperation(
                    backendIdentifier: workspace.backendIdentifier,
                    operation: operation
                ).localizedDescription
            )
        }

        return archivableBackend
    }

    private func requiredRemoteIdentifier(for workspace: Workspace) throws -> String {
        guard
            let remoteId = workspace.remoteId?.trimmingCharacters(in: .whitespacesAndNewlines),
            !remoteId.isEmpty
        else {
            throw RemoteWorkspaceError.missingRemoteIdentifier
        }

        return remoteId
    }

    private func saveModelContext(action: String) throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw ControllerError.message("Failed to \(action): \(error.localizedDescription)")
        }
    }

    private static func cleanupWorkspaceDirectoryAfterFailedPersistence(_ workspaceURL: URL) {
        try? FileManager.default.removeItem(at: workspaceURL)

        let parentDirectory = workspaceURL.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: parentDirectory.path),
            contents.isEmpty
        {
            try? FileManager.default.removeItem(at: parentDirectory)
        }
    }
}
