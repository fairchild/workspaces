import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("MainWindowRemoteWorkspaceStateController")
struct MainWindowRemoteWorkspaceStateControllerTests {
    private let controller = MainWindowRemoteWorkspaceStateController()

    @Test("Idle remote selection begins a pending connection")
    func idleRemoteSelectionBeginsConnection() {
        let workspace = makeRemoteWorkspace()

        let decision = controller.selectionDecision(
            for: workspace,
            connectingSandboxID: nil
        )

        switch decision {
        case .beginConnection(let pendingSelection):
            #expect(pendingSelection.workspaceID == workspace.id)
            #expect(pendingSelection.workspaceName == workspace.name)
            #expect(pendingSelection.sandboxID == workspace.remoteId)
        case .ignoreInFlightConnection:
            Issue.record("Expected remote selection to begin a connection when idle")
        }
    }

    @Test("In-flight remote selection ignores additional clicks")
    func inFlightSelectionIsIgnored() {
        let workspace = makeRemoteWorkspace()

        let decision = controller.selectionDecision(
            for: workspace,
            connectingSandboxID: "sandbox-in-flight"
        )

        switch decision {
        case .ignoreInFlightConnection(let sandboxID):
            #expect(sandboxID == "sandbox-in-flight")
        case .beginConnection:
            Issue.record("Expected selection to ignore clicks while another connection is in flight")
        }
    }

    @Test("Completion only applies to the matching pending sandbox")
    func completionRequiresMatchingPendingSandbox() {
        let workspace = makeRemoteWorkspace()
        let pendingSelection = MainWindowPendingRemoteWorkspaceSelection(
            workspace: workspace,
            sandboxID: workspace.remoteId ?? ""
        )

        #expect(
            controller.shouldAcceptCompletion(
                sandboxID: workspace.remoteId ?? "",
                pendingSelection: pendingSelection
            )
        )
        #expect(
            !controller.shouldAcceptCompletion(
                sandboxID: "different-sandbox",
                pendingSelection: pendingSelection
            )
        )
    }

    private func makeRemoteWorkspace() -> Workspace {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        return Workspace(
            name: "cloud-feature",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/cloud-feature"),
            sourceRepo: repo,
            backendIdentifier: "daytona",
            remoteId: "sandbox-123"
        )
    }
}
