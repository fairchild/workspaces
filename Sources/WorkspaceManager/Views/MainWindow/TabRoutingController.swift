import Foundation
import WorkspaceManagerCore

@MainActor
struct TabRoutingController {
    private let router = GhosttyTerminalIntentRouter()

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

        let effects = router.route(
            .tab(GhosttyTabIntent(request: request)),
            sourceSessionID: sourceSessionID,
            terminalMultiplexingMode: .ghosttyManagedSplits,
            hostTerminalState: hostTerminalState
        )
        apply(
            effects: effects,
            focusTerminal: focusTerminal,
            requestCloseTabs: requestCloseTabs
        )
    }

    private func apply(
        effects: [GhosttyTerminalRoutingEffect],
        focusTerminal: @escaping (UUID) -> Void,
        requestCloseTabs: @escaping ([UUID]) -> Void
    ) {
        for effect in effects {
            switch effect {
            case .focus(let sessionID):
                focusTerminal(sessionID)
            case .delayedFocus(let sessionID, let delay):
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    focusTerminal(sessionID)
                }
            case .closeTabs(let sessionIDs):
                requestCloseTabs(sessionIDs)
            }
        }
    }
}
