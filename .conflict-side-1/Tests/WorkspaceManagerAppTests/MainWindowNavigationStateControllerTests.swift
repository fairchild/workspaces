import Foundation
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("MainWindowNavigationStateController")
struct MainWindowNavigationStateControllerTests {
    private let controller = MainWindowNavigationStateController()

    @Test("Repo overview transition clears terminal selection and hides inspector")
    func repoOverviewTransitionClearsTerminalSelection() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        var state = makeState()

        let transition = controller.transition(to: .repoOverview(repo))
        controller.apply(transition, to: &state)

        #expect(state.selectedWorkspace == nil)
        #expect(state.selectedWebSource == nil)
        #expect(state.selectedRepoForLandingID == repo.id)
        #expect(state.selectedCodePreview == nil)
        #expect(state.isTerminalPanelVisible)
        #expect(state.isRightPaneVisible == false)
        #expect(state.columnVisibility == .all)
        #expect(transition.persistedSurface.kind == .repoOverview)
        #expect(transition.persistedSurface.id == repo.id)
    }

    @Test("Repo terminal transition preserves inspector visibility")
    func repoTerminalTransitionPreservesInspectorVisibility() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        var state = makeState()

        let transition = controller.transition(to: .repoTerminal(repo))
        controller.apply(transition, to: &state)

        #expect(state.selectedWorkspace == nil)
        #expect(state.selectedWebSource == nil)
        #expect(state.selectedRepoForLandingID == nil)
        #expect(state.selectedCodePreview == nil)
        #expect(state.isTerminalPanelVisible)
        #expect(state.isRightPaneVisible)
        #expect(state.columnVisibility == .all)
        #expect(transition.persistedSurface.kind == .repoTerminal)
        #expect(transition.persistedSurface.id == repo.id)
    }

    @Test("Workspace transition targets workspace and preserves inspector visibility")
    func workspaceTransitionTargetsWorkspace() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        var state = makeState()

        let transition = controller.transition(to: .workspaceTerminal(workspace))
        controller.apply(transition, to: &state)

        #expect(state.selectedWorkspace?.workspaceID == workspace.id)
        #expect(state.selectedWorkspace?.repoID == repo.id)
        #expect(state.selectedWebSource == nil)
        #expect(state.selectedRepoForLandingID == nil)
        #expect(state.selectedCodePreview == nil)
        #expect(state.isTerminalPanelVisible)
        #expect(state.isRightPaneVisible)
        #expect(state.columnVisibility == .all)
        #expect(transition.persistedSurface.kind == .workspaceTerminal)
        #expect(transition.persistedSurface.id == workspace.id)
    }

    @Test("Web transition hides inspector and clears workspace selection")
    func webTransitionHidesInspector() {
        let source = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com"
        )
        var state = makeState()

        let transition = controller.transition(to: .webView(source))
        controller.apply(transition, to: &state)

        #expect(state.selectedWorkspace == nil)
        #expect(state.selectedWebSource?.webSourceID == source.id)
        #expect(state.selectedRepoForLandingID == nil)
        #expect(state.selectedCodePreview == nil)
        #expect(state.isTerminalPanelVisible)
        #expect(state.isRightPaneVisible == false)
        #expect(state.columnVisibility == .all)
        #expect(transition.persistedSurface.kind == .webView)
        #expect(transition.persistedSurface.id == source.id)
    }

    private func makeState() -> MainWindowViewState {
        var state = MainWindowViewState()
        state.selectedWorkspace = MainWindowWorkspaceSelection(
            workspace: Workspace(
                name: "current",
                path: URL(fileURLWithPath: "/tmp/current"),
                sourceRepo: Repo(name: "current", localPath: URL(fileURLWithPath: "/tmp/current-repo"))
            )
        )
        state.selectedWebSource = MainWindowWebSourceSelection(
            source: WebSource(
                name: "Current Docs",
                baseURLString: "https://current.example.com/",
                allowedHost: "current.example.com"
            )
        )
        state.selectedRepoForLandingID = UUID()
        state.selectedCodePreview = CodePreviewSelection(
            rootURL: URL(fileURLWithPath: "/tmp/current"),
            relativePath: "README.md"
        )
        state.isTerminalPanelVisible = false
        state.isRightPaneVisible = true
        state.columnVisibility = .detailOnly
        return state
    }
}
