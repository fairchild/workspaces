import Foundation
import WorkspaceManagerCore

@MainActor
struct InspectorStateController {
    func hasInspectorTarget(selectedWorkspace: Workspace?, selectedRepo: Repo?) -> Bool {
        selectedWorkspace != nil || selectedRepo != nil
    }

    func inspectorTargetIDSet(repos: [Repo]) -> Set<String> {
        var ids = Set<String>()
        ids.reserveCapacity(repos.count * 2)

        for repo in repos {
            ids.insert("repo-\(repo.id.uuidString)")
            for workspace in repo.workspaces {
                ids.insert("workspace-\(workspace.id.uuidString)")
            }
        }

        return ids
    }

    func pruneRightPaneState(store: RightPaneStateStore, repos: [Repo]) {
        store.prune(keeping: inspectorTargetIDSet(repos: repos))
    }

    func toggleInspectorVisibility(hasTarget: Bool, isVisible: inout Bool) {
        guard hasTarget else { return }
        isVisible.toggle()
    }
}
