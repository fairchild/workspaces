//
//  SidebarWorkspaceController.swift
//  WorkspaceManager
//

import Foundation
import SwiftData
@preconcurrency import WorkspaceManagerCore

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
    let workspaceProviderRegistry: WorkspaceProviderRegistry

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
        name: String,
        providerID: String,
        guestOS: WorkspaceGuestOS? = nil,
        progress: WorkspaceProviderProgressHandler? = nil,
        onPersisted: (@MainActor @Sendable (HostLumeSmokeWorkspaceRecord) async -> Void)? = nil
    ) async throws -> Workspace {
        guard let provider = workspaceProviderRegistry.provider(for: providerID) else {
            throw ControllerError.message("Workspace provider '\(providerID)' is not registered.")
        }

        var persistedWorkspace: Workspace?
        let request = WorkspaceProviderCreationRequest(
            repoName: repo.name,
            repoLocalURL: repo.localURL,
            repoRemoteURL: repo.remoteURL,
            workspaceName: name,
            guestOS: guestOS
        )

        do {
            let finalResult = try await provider.createWorkspace(
                request: request,
                workspaceService: workspaceService,
                progress: progress,
                persist: { partialResult in
                    try await MainActor.run {
                        try upsertWorkspace(
                            from: partialResult,
                            repo: repo,
                            existingWorkspace: &persistedWorkspace
                        )
                    }
                    await onPersisted?(HostLumeSmokeWorkspaceRecord(result: partialResult))
                }
            )

            try upsertWorkspace(
                from: finalResult,
                repo: repo,
                existingWorkspace: &persistedWorkspace
            )
            await onPersisted?(HostLumeSmokeWorkspaceRecord(result: finalResult))

            guard let persistedWorkspace else {
                throw ControllerError.message("Failed to create workspace record.")
            }

            return persistedWorkspace
        } catch {
            if let persistedWorkspace {
                modelContext.delete(persistedWorkspace)
                do {
                    try saveModelContext(action: "revert failed workspace creation")
                } catch {
                    modelContext.rollback()
                }
            }
            throw error
        }
    }

    func deleteWorkspace(_ workspace: Workspace, deleteFiles: Bool) async throws {
        let workspaceURL = workspace.workspaceURL

        if workspace.backendIdentifier == LocalWorkspaceProvider.identifier {
            try await workspaceService.deleteWorkspace(at: workspaceURL, deleteFiles: deleteFiles)
        } else {
            let provider = try provider(for: workspace)
            try await provider.deleteWorkspace(WorkspaceProviderTarget(workspace))
            if provider.descriptor.usesHostWorkspaceFiles {
                try await workspaceService.deleteWorkspace(at: workspaceURL, deleteFiles: deleteFiles)
            }
        }

        modelContext.delete(workspace)
        try saveModelContext(action: "update workspace list")
    }

    func stop(_ workspace: Workspace) async throws {
        let provider = try provider(for: workspace)
        try await provider.stopWorkspace(WorkspaceProviderTarget(workspace))
        workspace.status = .stopped
        try saveModelContext(action: "stop workspace")
    }

    func start(_ workspace: Workspace) async throws {
        let provider = try provider(for: workspace)
        try await provider.startWorkspace(WorkspaceProviderTarget(workspace))
        workspace.status = .active
        try saveModelContext(action: "start workspace")
    }

    func archive(_ workspace: Workspace) async throws {
        let provider = try provider(for: workspace)
        try await provider.archiveWorkspace(WorkspaceProviderTarget(workspace))
        workspace.status = .archived
        try saveModelContext(action: "archive workspace")
    }

    private func upsertWorkspace(
        from result: WorkspaceProviderCreationResult,
        repo: Repo,
        existingWorkspace: inout Workspace?
    ) throws {
        if let existingWorkspace {
            existingWorkspace.name = result.name
            existingWorkspace.path = result.path.path
            existingWorkspace.gitBranch = result.gitBranch
            existingWorkspace.status = result.status
            existingWorkspace.backendIdentifier = result.backendIdentifier
            existingWorkspace.remoteId = result.remoteId
            existingWorkspace.backendMetadataRaw = result.backendMetadataRaw
        } else {
            let workspace = Workspace(
                name: result.name,
                path: result.path,
                sourceRepo: repo,
                status: result.status,
                gitBranch: result.gitBranch,
                backendIdentifier: result.backendIdentifier,
                remoteId: result.remoteId,
                backendMetadataRaw: result.backendMetadataRaw
            )
            modelContext.insert(workspace)
            existingWorkspace = workspace
        }

        try saveModelContext(action: "save workspace")
    }

    private func provider(for workspace: Workspace) throws -> any WorkspaceProviderProtocol {
        guard let provider = workspaceProviderRegistry.provider(for: workspace) else {
            throw ControllerError.message(
                "No workspace provider is registered for '\(workspace.backendIdentifier)'."
            )
        }

        return provider
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
