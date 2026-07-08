//
//  SidebarWorkspaceController.swift
//  WorkspaceManager
//

import Foundation
import SwiftData
@preconcurrency import WorkspaceManagerCore
import os.log

private let log = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "WorkspaceCreation"
)

@MainActor
struct SidebarWorkspaceController {
    private static let nameReservationStore = WorkspaceNameReservationStore.shared

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
    let retireTerminalSessions: @MainActor (HostTerminalSessionKey) async throws -> Void

    init(
        modelContext: ModelContext,
        workspaceService: any WorkspaceServiceProtocol,
        workspaceProviderRegistry: WorkspaceProviderRegistry,
        retireTerminalSessions: @escaping @MainActor (HostTerminalSessionKey) async throws -> Void = { _ in }
    ) {
        self.modelContext = modelContext
        self.workspaceService = workspaceService
        self.workspaceProviderRegistry = workspaceProviderRegistry
        self.retireTerminalSessions = retireTerminalSessions
    }

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

    /// Count of workspaces shown in a repo's active section — archived workspaces live in
    /// their own collapsed section, so the collapsed-repo badge must exclude them to match
    /// the rows listed when the repo is expanded.
    nonisolated static func activeWorkspaceCount(in workspaces: [Workspace]) -> Int {
        workspaces.filter { $0.status != .archived }.count
    }

    nonisolated static func localCreationMessage(for phase: WorkspaceCreationPhase) -> String {
        switch phase {
        case .preparing:
            return "Preparing workspace..."
        case .creatingWorktree:
            return "Creating git worktree..."
        case .runningSetupScript:
            return "Running setup..."
        case .finished:
            return "Finishing workspace..."
        }
    }

    func createWorkspace(
        from repo: Repo,
        name: String,
        nameSource: WorkspaceNameSource = .manual,
        providerID: String,
        guestOS: WorkspaceGuestOS? = nil,
        fromRef: String? = nil,
        progress: WorkspaceProviderProgressHandler? = nil,
        onPersisted: (@MainActor @Sendable (HostLumeSmokeWorkspaceRecord) async -> Void)? = nil
    ) async throws -> Workspace {
        guard let provider = workspaceProviderRegistry.provider(for: providerID) else {
            throw ControllerError.message("Workspace provider '\(providerID)' is not registered.")
        }

        let reservation = try await reserveWorkspaceName(
            for: repo,
            requestedName: name,
            source: nameSource,
            includeOnDiskDirectories: provider.descriptor.usesHostWorkspaceFiles
        )

        log.info(
            "createWorkspace: starting provider=\(providerID) repo=\(repo.name) name=\(reservation.resolvedName)"
        )

        var persistedWorkspace: Workspace?
        let request = WorkspaceProviderCreationRequest(
            repoName: repo.name,
            repoLocalURL: repo.localURL,
            repoRemoteURL: repo.remoteURL,
            workspaceName: reservation.resolvedName,
            guestOS: guestOS,
            fromRef: fromRef
        )

        do {
            log.info("createWorkspace: calling provider.createWorkspace")
            let finalResult = try await provider.createWorkspace(
                request: request,
                workspaceService: workspaceService,
                progress: progress,
                persist: { partialResult in
                    log.info("createWorkspace: persist handler called, hopping to MainActor")
                    try await MainActor.run {
                        try upsertWorkspace(
                            from: partialResult,
                            repo: repo,
                            existingWorkspace: &persistedWorkspace
                        )
                    }
                    log.info("createWorkspace: persist handler upsert complete")
                    await onPersisted?(HostLumeSmokeWorkspaceRecord(result: partialResult))
                }
            )

            log.info("createWorkspace: provider returned, calling final upsertWorkspace")
            try upsertWorkspace(
                from: finalResult,
                repo: repo,
                existingWorkspace: &persistedWorkspace
            )
            log.info("createWorkspace: final upsert complete")
            await onPersisted?(HostLumeSmokeWorkspaceRecord(result: finalResult))

            guard let persistedWorkspace else {
                throw ControllerError.message("Failed to create workspace record.")
            }

            await Self.nameReservationStore.release(reservation)
            log.info("createWorkspace: success, returning workspace")
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
            await Self.nameReservationStore.release(reservation)
            throw error
        }
    }

    func deleteWorkspace(_ workspace: Workspace, deleteFiles: Bool) async throws {
        let workspaceURL = workspace.workspaceURL
        let sessionKey = try terminalSessionKey(for: workspace)
        try await retireTerminalSessions(sessionKey)

        if workspace.backend == .local {
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
        let sessionKey = try terminalSessionKey(for: workspace)
        try await retireTerminalSessions(sessionKey)

        if workspace.backend == .local {
            let archivedURL = try await workspaceService.archiveWorkspace(at: workspace.workspaceURL)
            workspace.path = archivedURL.path
        } else {
            let provider = try provider(for: workspace)
            try await provider.archiveWorkspace(WorkspaceProviderTarget(workspace))
        }
        workspace.archivedAt = Date()
        workspace.status = .archived
        try saveModelContext(action: "archive workspace")
    }

    /// Restores a local workspace: moves its directory back out of `.archived/` and
    /// clears the archived state. Non-local workspaces just flip status back.
    ///
    /// Workspaces archived before directory moves existed were never relocated — their
    /// files still sit at the live path with no `.archived/` component. Moving one back
    /// out of `.archived/` would walk a level too far and land outside the workspaces
    /// root, so legacy records restore in place with a status flip only. The guard checks
    /// the exact shape `restoredDestination` assumes — `…/.archived/<repo>/<name>` — not
    /// mere component containment, so a repo or workspace literally named `.archived`
    /// at its live path also restores in place rather than taking a bogus move.
    func unarchive(_ workspace: Workspace) async throws {
        let components = workspace.workspaceURL.pathComponents
        let isUnderArchived =
            components.dropLast(2).last == WorkspaceDirectoryArchiver.archivedDirectoryComponent
        if workspace.backend == .local && isUnderArchived {
            let restoredURL = try await workspaceService.unarchiveWorkspace(at: workspace.workspaceURL)
            workspace.path = restoredURL.path
        }
        workspace.archivedAt = nil
        workspace.status = .active
        try saveModelContext(action: "unarchive workspace")
    }

    private func upsertWorkspace(
        from result: WorkspaceProviderCreationResult,
        repo: Repo,
        existingWorkspace: inout Workspace?
    ) throws {
        if let existingWorkspace {
            existingWorkspace.name = result.name
            existingWorkspace.path = result.persistedPath ?? result.path.path
            existingWorkspace.gitBranch = result.gitBranch
            existingWorkspace.status = result.status
            existingWorkspace.backendIdentifier = result.backendIdentifier
            existingWorkspace.remoteId = result.remoteId
            existingWorkspace.sessionRoutingID = result.sessionRoutingID
            existingWorkspace.backendMetadataRaw = result.backendMetadataRaw
        } else {
            let workspace = Workspace(
                name: result.name,
                path: URL(fileURLWithPath: result.persistedPath ?? result.path.path),
                sourceRepo: repo,
                status: result.status,
                gitBranch: result.gitBranch,
                backendIdentifier: result.backendIdentifier,
                remoteId: result.remoteId,
                sessionRoutingID: result.sessionRoutingID,
                backendMetadataRaw: result.backendMetadataRaw
            )
            modelContext.insert(workspace)
            existingWorkspace = workspace
        }

        try saveModelContext(action: "save workspace")
    }

    private func terminalSessionKey(for workspace: Workspace) throws -> HostTerminalSessionKey {
        let target = WorkspaceProviderTarget(workspace)
        if workspace.backend == .local {
            return LocalWorkspaceProvider().sessionKey(for: target)
        }

        return try provider(for: workspace).sessionKey(for: target)
    }

    private func reserveWorkspaceName(
        for repo: Repo,
        requestedName: String,
        source: WorkspaceNameSource,
        includeOnDiskDirectories: Bool
    ) async throws -> WorkspaceNameReservation {
        let occupiedNames = await occupiedSanitizedWorkspaceNames(
            for: repo,
            includeOnDiskDirectories: includeOnDiskDirectories
        )

        return try await Self.nameReservationStore.reserveName(
            repoID: repo.id,
            requestedName: requestedName,
            source: source,
            occupiedSanitizedNames: occupiedNames
        )
    }

    private func occupiedSanitizedWorkspaceNames(
        for repo: Repo,
        includeOnDiskDirectories: Bool
    ) async -> Set<String> {
        var occupiedNames = WorkspaceNameGenerator.sanitizedNameSet(
            from: repo.workspaces.map(\.name)
        )

        guard includeOnDiskDirectories else {
            return occupiedNames
        }

        let root = await workspaceService.workspacesRoot
        let repoDirectory = root.appendingPathComponent(repo.name, isDirectory: true)

        guard FileManager.default.fileExists(atPath: repoDirectory.path) else {
            return occupiedNames
        }

        let directoryNames =
            (try? FileManager.default.contentsOfDirectory(
                at: repoDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ))?
            .compactMap { url -> String? in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { return nil }
                return url.lastPathComponent
            } ?? []

        occupiedNames.formUnion(WorkspaceNameGenerator.sanitizedNameSet(from: directoryNames))
        return occupiedNames
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
            log.debug("saveModelContext: \(action)")
            try modelContext.save()
            log.debug("saveModelContext: \(action) succeeded")
        } catch {
            log.error("saveModelContext: \(action) failed: \(error.localizedDescription)")
            modelContext.rollback()
            throw ControllerError.message("Failed to \(action): \(error.localizedDescription)")
        }
    }

}
