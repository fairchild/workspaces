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
        sandboxId: String,
        cleanupError: Error
    ) -> String {
        let cleanupMessage =
            "Cleanup also failed for remote sandbox '\(sandboxId)': \(cleanupError.localizedDescription)"

        if let existingMessage, !existingMessage.isEmpty {
            return "\(existingMessage)\n\n\(cleanupMessage)"
        }

        return cleanupMessage
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
        case .sshHost:
            throw ControllerError.message("SSH host workspaces are not supported yet.")
        case .kubernetesPod:
            throw ControllerError.message("Kubernetes pod workspaces are not supported yet.")
        case .sshCompose:
            throw ControllerError.message("SSH Compose workspaces are not supported yet.")
        }
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

    private func createDaytonaWorkspace(from repo: Repo, name: String) async throws -> Workspace {
        guard await remoteBackend.isAvailable() else {
            throw BackendError.notAvailable("Daytona")
        }

        let info = try await remoteBackend.createSandbox(name: name, cloneURL: repo.remoteURL)
        let workspace = Workspace(
            name: name,
            path: FileManager.default.temporaryDirectory,
            sourceRepo: repo,
            backendIdentifier: WorkspaceBackendChoice.daytona.rawValue,
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
                    try await remoteBackend.deleteSandbox(sandboxId: sandboxId)
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
                        sandboxId: info.sandboxId,
                        cleanupError: cleanupError
                    )
                )
            }
            throw error
        }
    }

    func deleteWorkspace(_ workspace: Workspace, deleteFiles: Bool) async throws {
        let workspaceURL = workspace.workspaceURL

        if workspace.isRemote, let sandboxId = workspace.remoteId {
            do {
                try await remoteBackend.deleteSandbox(sandboxId: sandboxId)
            } catch {
                NSLog("[RemoteBackend] Failed to delete sandbox %@: %@", sandboxId, error.localizedDescription)
            }
        } else {
            try await workspaceService.deleteWorkspace(at: workspaceURL, deleteFiles: deleteFiles)
        }

        modelContext.delete(workspace)
        try saveModelContext(action: "update workspace list")
    }

    func stop(_ workspace: Workspace) async throws {
        guard let sandboxId = workspace.remoteId else { return }
        try await remoteBackend.stopSandbox(sandboxId: sandboxId)
        workspace.status = .stopped
        try saveModelContext(action: "stop sandbox")
    }

    func start(_ workspace: Workspace) async throws {
        guard let sandboxId = workspace.remoteId else { return }
        _ = try await remoteBackend.startSandbox(sandboxId: sandboxId)
        workspace.status = .active
        try saveModelContext(action: "start sandbox")
    }

    func archive(_ workspace: Workspace) async throws {
        guard let sandboxId = workspace.remoteId else { return }
        try await remoteBackend.archiveSandbox(sandboxId: sandboxId)
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
