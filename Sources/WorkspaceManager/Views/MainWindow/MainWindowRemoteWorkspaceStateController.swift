import WorkspaceManagerCore

enum MainWindowRemoteWorkspaceSelectionDecision: Equatable {
    case beginConnection(MainWindowPendingRemoteWorkspaceSelection)
    case ignoreInFlightConnection(sandboxID: String)
}

struct MainWindowRemoteWorkspaceStateController {
    func selectionDecision(
        for workspace: Workspace,
        connectingSandboxID: String?
    ) -> MainWindowRemoteWorkspaceSelectionDecision {
        guard let sandboxID = workspace.remoteId else {
            preconditionFailure("Remote workspace selection requires a sandbox identifier")
        }

        if let connectingSandboxID {
            return .ignoreInFlightConnection(sandboxID: connectingSandboxID)
        }

        return .beginConnection(
            MainWindowPendingRemoteWorkspaceSelection(workspace: workspace, sandboxID: sandboxID)
        )
    }

    func shouldAcceptCompletion(
        sandboxID: String,
        pendingSelection: MainWindowPendingRemoteWorkspaceSelection?
    ) -> Bool {
        pendingSelection?.sandboxID == sandboxID
    }
}
