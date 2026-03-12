import WorkspaceManagerCore

enum MainWindowRemoteWorkspaceSelectionDecision: Equatable {
    case beginConnection(MainWindowPendingRemoteWorkspaceSelection)
    case ignoreInFlightConnection(routingID: String)
}

struct MainWindowRemoteWorkspaceStateController {
    func selectionDecision(
        for workspace: Workspace,
        connectingRoutingID: String?
    ) -> MainWindowRemoteWorkspaceSelectionDecision {
        let routingID = workspace.terminalSessionIdentifier

        if let connectingRoutingID {
            return .ignoreInFlightConnection(routingID: connectingRoutingID)
        }

        return .beginConnection(
            MainWindowPendingRemoteWorkspaceSelection(workspace: workspace, routingID: routingID)
        )
    }

    func shouldAcceptCompletion(
        routingID: String,
        pendingSelection: MainWindowPendingRemoteWorkspaceSelection?
    ) -> Bool {
        pendingSelection?.routingID == routingID
    }
}
