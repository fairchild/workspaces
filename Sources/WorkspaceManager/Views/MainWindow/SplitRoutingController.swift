import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "SplitRoutingController")

@MainActor
struct SplitRoutingController {
    private let router = GhosttyTerminalIntentRouter()

    func handle(
        notification: Notification,
        terminalMultiplexingMode: TerminalMultiplexingMode,
        tileTreeStore: TileTreeStore,
        focusTerminal: @escaping (UUID) -> Void
    ) {
        guard let request = GhosttyAppManager.splitActionRequest(from: notification) else {
            log.error("[SplitRouting] Ignored split action notification with invalid payload")
            return
        }

        let sourceSessionID =
            (notification.object as? GhosttySurfaceView)
            .flatMap { tileTreeStore.surfaceStore.sessionID(for: $0) }

        let effects = router.route(
            .split(GhosttySplitIntent(request: request)),
            sourceSessionID: sourceSessionID,
            terminalMultiplexingMode: terminalMultiplexingMode,
            tileTreeStore: tileTreeStore
        )
        apply(effects: effects, focusTerminal: focusTerminal)
    }

    private func apply(
        effects: [GhosttyTerminalRoutingEffect],
        focusTerminal: @escaping (UUID) -> Void
    ) {
        for effect in effects {
            switch effect {
            case .focus(let sessionID):
                focusTerminal(sessionID)
            case .delayedFocus(let sessionID, let delay):
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    focusTerminal(sessionID)
                }
            case .closeTabs:
                break
            }
        }
    }
}
