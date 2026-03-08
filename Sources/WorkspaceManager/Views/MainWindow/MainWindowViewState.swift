import SwiftUI
import WorkspaceManagerCore

struct MainWindowViewState {
    var selectedWorkspace: Workspace?
    var selectedWebSource: WebSource?
    var selectedCodePreview: CodePreviewSelection?
    var isTerminalPanelVisible = true
    var isRightPaneVisible = false
    var columnVisibility: NavigationSplitViewVisibility = .all
    var didRunPerfAutoSelection = false
    var didApplyFixturePreviewBootstrap = false
    var didApplyFixtureWebBootstrap = false
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
