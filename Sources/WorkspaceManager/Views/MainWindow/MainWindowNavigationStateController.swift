import SwiftUI
import WorkspaceManagerCore

enum MainWindowNavigationDestination {
    case repoOverview(Repo)
    case repoTerminal(Repo)
    case workspaceTerminal(Workspace)
    case webView(WebSource)
}

struct MainWindowNavigationTransition {
    let selectedWorkspace: MainWindowWorkspaceSelection?
    let selectedWebSource: MainWindowWebSourceSelection?
    let selectedRepoForLandingID: UUID?
    let clearsCodePreview: Bool
    let rightPaneVisibility: Bool?
    let columnVisibility: NavigationSplitViewVisibility
    let persistedSurface: MainWindowLastSurface
}

struct MainWindowNavigationStateController {
    func transition(to destination: MainWindowNavigationDestination) -> MainWindowNavigationTransition {
        switch destination {
        case .repoOverview(let repo):
            return MainWindowNavigationTransition(
                selectedWorkspace: nil,
                selectedWebSource: nil,
                selectedRepoForLandingID: repo.id,
                clearsCodePreview: true,
                rightPaneVisibility: false,
                columnVisibility: .all,
                persistedSurface: .init(kind: .repoOverview, id: repo.id)
            )

        case .repoTerminal(let repo):
            return MainWindowNavigationTransition(
                selectedWorkspace: nil,
                selectedWebSource: nil,
                selectedRepoForLandingID: nil,
                clearsCodePreview: true,
                rightPaneVisibility: nil,
                columnVisibility: .all,
                persistedSurface: .init(kind: .repoTerminal, id: repo.id)
            )

        case .workspaceTerminal(let workspace):
            return MainWindowNavigationTransition(
                selectedWorkspace: .init(workspace: workspace),
                selectedWebSource: nil,
                selectedRepoForLandingID: nil,
                clearsCodePreview: true,
                rightPaneVisibility: nil,
                columnVisibility: .all,
                persistedSurface: .init(kind: .workspaceTerminal, id: workspace.id)
            )

        case .webView(let source):
            return MainWindowNavigationTransition(
                selectedWorkspace: nil,
                selectedWebSource: .init(source: source),
                selectedRepoForLandingID: nil,
                clearsCodePreview: true,
                rightPaneVisibility: false,
                columnVisibility: .all,
                persistedSurface: .init(kind: .webView, id: source.id)
            )
        }
    }

    func apply(_ transition: MainWindowNavigationTransition, to state: inout MainWindowViewState) {
        state.selectedWorkspace = transition.selectedWorkspace
        state.selectedWebSource = transition.selectedWebSource
        state.selectedRepoForLandingID = transition.selectedRepoForLandingID

        if transition.clearsCodePreview {
            state.selectedCodePreview = nil
            state.isTerminalPanelVisible = true
        }

        if let rightPaneVisibility = transition.rightPaneVisibility {
            state.isRightPaneVisible = rightPaneVisibility
        }

        state.columnVisibility = transition.columnVisibility
    }
}
