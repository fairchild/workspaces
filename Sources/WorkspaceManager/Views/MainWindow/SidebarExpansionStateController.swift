//
//  SidebarExpansionStateController.swift
//  WorkspaceManager
//

import Foundation

struct SidebarExpansionStateController {
    private(set) var expandedRepoIDs: Set<UUID> = []
    private(set) var expandedWorkspaceIDs: Set<UUID> = []
    private(set) var didInitializeRepoExpansion = false

    func isRepoExpanded(_ repoID: UUID) -> Bool {
        expandedRepoIDs.contains(repoID)
    }

    mutating func toggleRepoExpansion(_ repoID: UUID) {
        if expandedRepoIDs.contains(repoID) {
            expandedRepoIDs.remove(repoID)
        } else {
            expandedRepoIDs.insert(repoID)
        }
    }

    mutating func expandRepo(_ repoID: UUID) {
        expandedRepoIDs.insert(repoID)
    }

    func isWorkspaceExpanded(_ workspaceID: UUID) -> Bool {
        expandedWorkspaceIDs.contains(workspaceID)
    }

    mutating func toggleWorkspaceExpansion(_ workspaceID: UUID, hasWebSources: Bool) {
        guard hasWebSources else { return }

        if expandedWorkspaceIDs.contains(workspaceID) {
            expandedWorkspaceIDs.remove(workspaceID)
        } else {
            expandedWorkspaceIDs.insert(workspaceID)
        }
    }

    mutating func initializeRepoExpansionIfNeeded(
        repoIDs: [UUID],
        selectedWorkspaceRepoID: UUID?,
        isUIFixtureMode: Bool
    ) {
        guard !didInitializeRepoExpansion else { return }
        didInitializeRepoExpansion = true

        if isUIFixtureMode {
            expandedRepoIDs = Set(repoIDs)
            return
        }

        if let selectedWorkspaceRepoID {
            expandedRepoIDs.insert(selectedWorkspaceRepoID)
        }
    }

    mutating func expandSelectedWorkspace(
        workspaceID: UUID?,
        repoID: UUID?,
        hasWebSources: Bool
    ) {
        guard let workspaceID, let repoID else { return }
        expandedRepoIDs.insert(repoID)

        if hasWebSources {
            expandedWorkspaceIDs.insert(workspaceID)
        }
    }

    mutating func expandSelectedWebSource(repoID: UUID?, workspaceID: UUID?) {
        if let repoID {
            expandedRepoIDs.insert(repoID)
        }

        if let workspaceID {
            expandedWorkspaceIDs.insert(workspaceID)
        }
    }

    mutating func prune(validRepoIDs: Set<UUID>, validWorkspaceIDs: Set<UUID>) {
        expandedRepoIDs.formIntersection(validRepoIDs)
        expandedWorkspaceIDs.formIntersection(validWorkspaceIDs)
    }
}
