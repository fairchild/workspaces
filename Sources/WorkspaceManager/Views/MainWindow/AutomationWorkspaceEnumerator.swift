//
//  AutomationWorkspaceEnumerator.swift
//  WorkspaceManager
//
//  Projects the app's live SwiftData repos and workspaces into the read-only descriptors the
//  operator-scope `GET /v1/workspaces` route returns. Keyed by the stable SwiftData model ids so
//  mutation verbs can target the same repo/workspace an operator listed here.
//

import Foundation
import WorkspaceManagerCore

enum AutomationWorkspaceEnumerator {
    @MainActor
    static func inventory(
        repos: [Repo],
        selectedWorkspaceID: UUID?,
        selectedRepoID: UUID?
    ) -> AutomationWorkspaceInventory {
        let repoDescriptors = repos.map { repo in
            AutomationRepoDescriptor(
                repoID: repo.id,
                name: repo.name,
                path: repo.localPath,
                isSelected: repo.id == selectedRepoID
            )
        }

        let workspaceDescriptors = repos.flatMap(\.workspaces).map { workspace in
            AutomationWorkspaceDescriptor(
                workspaceID: workspace.id,
                repoID: workspace.sourceRepo?.id,
                name: workspace.name,
                path: workspace.path,
                branch: workspace.gitBranch,
                status: workspace.status.rawValue,
                isArchived: workspace.status == .archived,
                backend: workspace.backendIdentifier,
                isSelected: workspace.id == selectedWorkspaceID
            )
        }

        return AutomationWorkspaceInventory(repos: repoDescriptors, workspaces: workspaceDescriptors)
    }
}
