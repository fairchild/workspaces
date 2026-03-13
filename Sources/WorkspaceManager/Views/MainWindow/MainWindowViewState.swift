import SwiftUI
import WorkspaceManagerCore

struct MainWindowWorkspaceSelection: Equatable {
    let workspaceID: UUID
    let repoID: UUID?

    init(workspace: Workspace) {
        workspaceID = workspace.id
        repoID = workspace.sourceRepo?.id
    }
}

struct MainWindowWebSourceSelection: Equatable {
    let webSourceID: UUID
    let ownerRepoID: UUID?
    let ownerWorkspaceID: UUID?

    init(source: WebSource) {
        webSourceID = source.id
        ownerRepoID = source.ownerRepo?.id
        ownerWorkspaceID = source.sourceWorkspace?.id
    }
}

struct MainWindowPendingRemoteWorkspaceSelection: Equatable {
    let workspaceID: UUID
    let workspaceName: String
    let routingID: String

    init(workspace: Workspace, routingID: String) {
        workspaceID = workspace.id
        workspaceName = workspace.name
        self.routingID = routingID
    }
}

struct MainWindowViewState {
    var selectedWorkspace: MainWindowWorkspaceSelection?
    var selectedWebSource: MainWindowWebSourceSelection?
    var selectedRepoForLandingID: UUID?
    var pendingRemoteWorkspace: MainWindowPendingRemoteWorkspaceSelection?
    var selectedCodePreview: CodePreviewSelection?
    var isTerminalPanelVisible = true
    var isRightPaneVisible = false
    var columnVisibility: NavigationSplitViewVisibility = .all
    var didRunPerfAutoSelection = false
    var didRunPerfAutoOpenNewWorkspace = false
    var didApplyFixturePreviewBootstrap = false
    var didApplyFixtureWebBootstrap = false
    var didResolveInitialSurface = false
    var openInEditorErrorMessage: String?
    var workspaceOperationErrorMessage: String?
    var connectingWorkspaceID: UUID?
}

enum MainWindowOpenInEditorContextKey: Equatable {
    case none
    case file(String)
    case workspace(UUID)
    case repo(UUID)
}
