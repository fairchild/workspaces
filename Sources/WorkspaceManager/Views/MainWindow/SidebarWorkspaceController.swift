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
    let remoteBackend: any RemoteBackendProtocol

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
                "Cleanup also failed for remote sandbox '\(sandboxId)': \(cleanupError.localizedDescription)"
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

    private func unsupportedOperationMessage(_ operation: String) -> String {
        RemoteBackendCapabilityError.unsupportedOperation(
            backendIdentifier: remoteBackend.identifier,
            operation: operation
        ).localizedDescription
    }

    private func provisioningBackend(
        requiresCreate: Bool = false,
        requiresDelete: Bool = false,
        operation: String
    ) throws -> any ProvisionCapable {
        let capabilities = remoteBackend.runtimeCapabilities

        guard
            (!requiresCreate || capabilities.supportsCreate)
                && (!requiresDelete || capabilities.supportsDelete)
        else {
            throw ControllerError.message(unsupportedOperationMessage(operation))
        }

        guard let backend = remoteBackend as? any ProvisionCapable else {
            throw ControllerError.message(unsupportedOperationMessage(operation))
        }

        return backend
    }

    private func startStopBackend(operation: String) throws -> any StartStopCapable {
        guard remoteBackend.runtimeCapabilities.supportsStartStop,
            let backend = remoteBackend as? any StartStopCapable
        else {
            throw ControllerError.message(unsupportedOperationMessage(operation))
        }

        return backend
    }

    private func archivableBackend(operation: String) throws -> any Archivable {
        guard remoteBackend.runtimeCapabilities.supportsArchive,
            let backend = remoteBackend as? any Archivable
        else {
            throw ControllerError.message(unsupportedOperationMessage(operation))
        }

        return backend
    }

    func createWorkspace(
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

    func createRemoteWorkspace(from repo: Repo, name: String) async throws -> Workspace {
        let backend = try provisioningBackend(
            requiresCreate: true,
            operation: "creating remote workspaces"
        )
        let info = try await backend.createSandbox(name: name, cloneURL: repo.remoteURL)
        let workspace = Workspace(
            name: name,
            path: FileManager.default.temporaryDirectory,
            sourceRepo: repo,
            backendIdentifier: remoteBackend.identifier,
            remoteId: info.sandboxId
        )
        modelContext.insert(workspace)

        do {
            try saveModelContext(action: "save remote workspace")
            return workspace
        } catch {
            if remoteBackend.runtimeCapabilities.supportsDelete {
                if let cleanupError = await Self.cleanupRemoteSandboxAfterFailedPersistence(
                    sandboxId: info.sandboxId,
                    deleteSandbox: { sandboxId in
                        try await backend.deleteSandbox(sandboxId: sandboxId)
                    }
                ) {
                    NSLog(
                        "[RemoteBackend] Failed to clean up sandbox %@ after persistence failure: %@",
                        info.sandboxId,
                        cleanupError.localizedDescription
                    )
                    throw ControllerError.message(
                        Self.remoteWorkspacePersistenceFailureMessage(
                            existingMessage: error.localizedDescription,
                            cleanupMessage:
                                "Cleanup also failed for remote sandbox '\(info.sandboxId)': \(cleanupError.localizedDescription)"
                        )
                    )
                }
            } else {
                NSLog(
                    "[RemoteBackend] Skipping sandbox cleanup after persistence failure because %@ does not support delete",
                    remoteBackend.identifier
                )
                throw ControllerError.message(
                    Self.remoteWorkspacePersistenceFailureMessage(
                        existingMessage: error.localizedDescription,
                        cleanupMessage:
                            "Cleanup was skipped for remote sandbox '\(info.sandboxId)' because backend '\(remoteBackend.identifier)' does not support deletion."
                    )
                )
            }
            throw error
        }
    }

    func deleteWorkspace(_ workspace: Workspace, deleteFiles: Bool) async throws {
        let workspaceURL = workspace.workspaceURL

        if workspace.isRemote, let sandboxId = workspace.remoteId {
            if remoteBackend.runtimeCapabilities.supportsDelete,
                let backend = remoteBackend as? any ProvisionCapable
            {
                do {
                    try await backend.deleteSandbox(sandboxId: sandboxId)
                } catch {
                    NSLog("[RemoteBackend] Failed to delete sandbox %@: %@", sandboxId, error.localizedDescription)
                }
            } else {
                NSLog(
                    "[RemoteBackend] Backend %@ does not support deleting sandbox %@; removing local record only",
                    remoteBackend.identifier,
                    sandboxId
                )
            }
        } else {
            try await workspaceService.deleteWorkspace(at: workspaceURL, deleteFiles: deleteFiles)
        }

        modelContext.delete(workspace)
        try saveModelContext(action: "update workspace list")
    }

    func stop(_ workspace: Workspace) async throws {
        guard let sandboxId = workspace.remoteId else { return }
        let backend = try startStopBackend(operation: "stopping remote workspaces")
        try await backend.stopSandbox(sandboxId: sandboxId)
        workspace.status = .stopped
        try saveModelContext(action: "stop sandbox")
    }

    func start(_ workspace: Workspace) async throws {
        guard let sandboxId = workspace.remoteId else { return }
        let backend = try startStopBackend(operation: "starting remote workspaces")
        _ = try await backend.startSandbox(sandboxId: sandboxId)
        workspace.status = .active
        try saveModelContext(action: "start sandbox")
    }

    func archive(_ workspace: Workspace) async throws {
        guard let sandboxId = workspace.remoteId else { return }
        let backend = try archivableBackend(operation: "archiving remote workspaces")
        try await backend.archiveSandbox(sandboxId: sandboxId)
        workspace.status = .archived
        try saveModelContext(action: "archive sandbox")
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
