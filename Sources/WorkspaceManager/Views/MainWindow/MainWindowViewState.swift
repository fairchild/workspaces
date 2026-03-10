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

struct MainWindowViewState {
    var selectedWorkspace: MainWindowWorkspaceSelection?
    var selectedWebSource: MainWindowWebSourceSelection?
    var selectedRepoForLandingID: UUID?
    var selectedCodePreview: CodePreviewSelection?
    var isTerminalPanelVisible = true
    var isRightPaneVisible = false
    var columnVisibility: NavigationSplitViewVisibility = .all
    var didRunPerfAutoSelection = false
    var didApplyFixturePreviewBootstrap = false
    var didApplyFixtureWebBootstrap = false
    var didResolveInitialSurface = false
    var openInEditorErrorMessage: String?
    var remoteErrorMessage: String?
    var connectingSandboxId: String?
}

enum MainWindowOpenInEditorContextKey: Equatable {
    case none
    case file(String)
    case workspace(UUID)
    case repo(UUID)
}
