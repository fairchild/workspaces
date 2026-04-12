import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("InspectorStateController")
struct InspectorStateControllerTests {
    @Test("Toggle inspector ignores missing target")
    func toggleInspectorIgnoresMissingTarget() {
        let controller = InspectorStateController()
        var isVisible = false

        controller.toggleInspectorVisibility(hasTarget: false, isVisible: &isVisible)

        #expect(!isVisible)
    }

    @Test("Toggle inspector flips visibility when target exists")
    func toggleInspectorFlipsVisibilityWhenTargetExists() {
        let controller = InspectorStateController()
        var isVisible = false

        controller.toggleInspectorVisibility(hasTarget: true, isVisible: &isVisible)
        #expect(isVisible)

        controller.toggleInspectorVisibility(hasTarget: true, isVisible: &isVisible)
        #expect(!isVisible)
    }

    @Test("Inspector target set includes repo and nested workspace IDs")
    func inspectorTargetSetIncludesRepoAndNestedWorkspaceIDs() {
        let repo = Repo(name: "demo", localPath: URL(fileURLWithPath: "/tmp/demo"))
        let workspace = Workspace(
            name: "feature",
            path: URL(fileURLWithPath: "/tmp/workspaces/demo/feature"),
            sourceRepo: repo
        )
        repo.workspaces = [workspace]

        let controller = InspectorStateController()
        let ids = controller.inspectorTargetIDSet(repos: [repo])

        #expect(ids.contains("repo-\(repo.id.uuidString)"))
        #expect(ids.contains("workspace-\(workspace.id.uuidString)"))
    }
}
