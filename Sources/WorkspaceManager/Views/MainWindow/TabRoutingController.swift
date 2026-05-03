import Foundation
import WorkspaceManagerCore

@MainActor
struct TabRoutingController {
    func handle(
        notification: Notification,
        hostTerminalState: HostTerminalStateStore,
        focusTerminal: @escaping (UUID) -> Void,
        requestCloseTabs: @escaping ([UUID]) -> Void
    ) {
        guard let request = GhosttyAppManager.tabActionRequest(from: notification) else {
            NSLog("[TabRouting] Ignored tab action notification with invalid payload")
            return
        }

        let sourceSessionID =
            (notification.object as? GhosttySurfaceView)
            .flatMap { hostTerminalState.surfaceStore.sessionID(for: $0) }

        switch request.kind {
        case .newTab:
            guard let session = hostTerminalState.createTab(from: sourceSessionID) else {
                NSLog("[TabRouting] new_tab ignored: no source/active session")
                return
            }
            focusTerminal(session.id)

        case .closeTab:
            let tabIDs = hostTerminalState.tabIDsForClose(
                mode: request.closeMode,
                sourceSessionID: sourceSessionID
            )
            guard !tabIDs.isEmpty else {
                NSLog("[TabRouting] close_tab no-op mode=%@", String(describing: request.closeMode))
                return
            }
            requestCloseTabs(tabIDs)

        case .gotoTab:
            guard let target = request.gotoTarget,
                let session = activateTab(
                    target,
                    hostTerminalState: hostTerminalState,
                    sourceSessionID: sourceSessionID
                )
            else {
                NSLog("[TabRouting] goto_tab no-op target=%@", String(describing: request.gotoTarget))
                return
            }
            focusTerminal(session.id)

        case .moveTab:
            let amount = request.moveAmount ?? 0
            guard hostTerminalState.moveTab(containing: sourceSessionID, offset: amount),
                let activeSessionID = hostTerminalState.activeSessionID
            else {
                NSLog("[TabRouting] move_tab no-op amount=%d", amount)
                return
            }
            focusTerminal(activeSessionID)

        case .setTabTitle:
            guard hostTerminalState.setTabTitle(request.title, for: sourceSessionID) else {
                NSLog("[TabRouting] set_tab_title no-op")
                return
            }
        }
    }

    private func activateTab(
        _ target: GhosttyAppManager.TabGotoTarget,
        hostTerminalState: HostTerminalStateStore,
        sourceSessionID: UUID?
    ) -> HostTerminalSession? {
        switch target {
        case .previous:
            return hostTerminalState.activateAdjacentTab(offset: -1, from: sourceSessionID)
        case .next:
            return hostTerminalState.activateAdjacentTab(offset: 1, from: sourceSessionID)
        case .last:
            return hostTerminalState.activateLastTab()
        case .index(let index):
            return hostTerminalState.activateTab(atOneBasedIndex: index)
        }
    }
}
