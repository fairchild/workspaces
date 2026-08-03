import Foundation
import WorkspaceManagerCore
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "GhosttyTerminalIntentRouter")

enum GhosttyTerminalIntent: Equatable {
    case split(GhosttySplitIntent)
    case tab(GhosttyTabIntent)
}

enum GhosttySplitIntent: Equatable {
    case newSplit(direction: GhosttyAppManager.SplitDirection?)
    case gotoSplit(direction: GhosttyAppManager.SplitFocusDirection?)
    case resizeSplit(direction: GhosttyAppManager.SplitResizeDirection?, amount: Int?)
    case equalizeSplits
}

enum GhosttyTabIntent: Equatable {
    case newTab
    case closeTab(mode: GhosttyAppManager.TabCloseMode)
    case gotoTab(target: GhosttyAppManager.TabGotoTarget?)
    case moveTab(amount: Int?)
    case setTabTitle(String?)
}

enum GhosttyTerminalRoutingEffect: Equatable {
    case focus(UUID)
    case delayedFocus(UUID, delay: TimeInterval)
    case closeTabs([UUID])
}

@MainActor
struct GhosttyTerminalIntentRouter {
    static let splitFocusDelay: TimeInterval = 0.12

    func route(
        _ intent: GhosttyTerminalIntent,
        sourceSessionID: UUID?,
        terminalMultiplexingMode: TerminalMultiplexingMode,
        tileTreeStore: TileTreeStore
    ) -> [GhosttyTerminalRoutingEffect] {
        switch intent {
        case .split(let splitIntent):
            guard terminalMultiplexingMode == .ghosttyManagedSplits else {
                log.error(
                    "[SplitRouting] Ignored split action while terminal mode=\(terminalMultiplexingMode.rawValue, privacy: .public)"
                )
                return []
            }
            return routeSplit(
                splitIntent,
                sourceSessionID: sourceSessionID,
                tileTreeStore: tileTreeStore
            )
        case .tab(let tabIntent):
            return routeTab(
                tabIntent,
                sourceSessionID: sourceSessionID,
                tileTreeStore: tileTreeStore
            )
        }
    }

    private func routeSplit(
        _ intent: GhosttySplitIntent,
        sourceSessionID: UUID?,
        tileTreeStore: TileTreeStore
    ) -> [GhosttyTerminalRoutingEffect] {
        switch intent {
        case .newSplit(let direction):
            return handleNewSplit(
                sourceSessionID: sourceSessionID,
                direction: direction,
                tileTreeStore: tileTreeStore
            )
        case .gotoSplit(let direction):
            return handleGotoSplit(
                sourceSessionID: sourceSessionID,
                direction: direction,
                tileTreeStore: tileTreeStore
            )
        case .resizeSplit(let direction, let amount):
            handleResizeSplit(
                sourceSessionID: sourceSessionID,
                direction: direction,
                amount: amount,
                tileTreeStore: tileTreeStore
            )
            return []
        case .equalizeSplits:
            handleEqualizeSplits(
                sourceSessionID: sourceSessionID,
                tileTreeStore: tileTreeStore
            )
            return []
        }
    }

    private func routeTab(
        _ intent: GhosttyTabIntent,
        sourceSessionID: UUID?,
        tileTreeStore: TileTreeStore
    ) -> [GhosttyTerminalRoutingEffect] {
        switch intent {
        case .newTab:
            guard let session = tileTreeStore.createTab(from: sourceSessionID) else {
                log.error("[TabRouting] new_tab ignored: no source/active session")
                return []
            }
            return [.focus(session.id)]

        case .closeTab(let mode):
            let tabIDs = tileTreeStore.tabIDsForClose(
                mode: mode,
                sourceSessionID: sourceSessionID
            )
            guard !tabIDs.isEmpty else {
                log.error("[TabRouting] close_tab no-op mode=\(String(describing: mode), privacy: .public)")
                return []
            }
            return [.closeTabs(tabIDs)]

        case .gotoTab(let target):
            guard let target,
                let session = activateTab(
                    target,
                    tileTreeStore: tileTreeStore,
                    sourceSessionID: sourceSessionID
                )
            else {
                log.error("[TabRouting] goto_tab no-op target=\(String(describing: target), privacy: .public)")
                return []
            }
            return [.focus(session.id)]

        case .moveTab(let amount):
            let resolvedAmount = amount ?? 0
            guard tileTreeStore.moveTab(containing: sourceSessionID, offset: resolvedAmount),
                let activeSessionID = tileTreeStore.activeSessionID
            else {
                log.error("[TabRouting] move_tab no-op amount=\(resolvedAmount, privacy: .public)")
                return []
            }
            return [.focus(activeSessionID)]

        case .setTabTitle(let title):
            guard tileTreeStore.setTabTitle(title, for: sourceSessionID) else {
                log.error("[TabRouting] set_tab_title no-op")
                return []
            }
            return []
        }
    }

    private func handleNewSplit(
        sourceSessionID: UUID?,
        direction: GhosttyAppManager.SplitDirection?,
        tileTreeStore: TileTreeStore
    ) -> [GhosttyTerminalRoutingEffect] {
        // Resolve which pane to split: the live source, or the active session when fired without one.
        guard let sourcePaneID = sourceSessionID ?? tileTreeStore.activeSessionID else {
            log.error("[SplitRouting] new_split ignored: no active/primary session")
            return []
        }
        // Called for its tab-activation side effect only; the returned primary id is used for the log
        // line below, not threaded into the split — `splitFocusedTile` resolves its own primary.
        let primarySessionID = tileTreeStore.activatePrimarySession(containing: sourcePaneID)
        log.info(
            "[SplitRouting] new_split source=\(sourcePaneID.uuidString, privacy: .public) primary=\(primarySessionID?.uuidString ?? "nil", privacy: .public)"
        )
        let preferredLayout = splitLayout(for: direction)
        log.info(
            "[SplitRouting] new_split layout axis=\(preferredLayout.axis == .topBottom ? "topBottom" : "leadingTrailing", privacy: .public) splitBeforePrimary=\(preferredLayout.splitBeforePrimary ? "true" : "false", privacy: .public) direction=\(String(describing: direction), privacy: .public)"
        )

        guard
            let splitSession = tileTreeStore.splitFocusedTile(
                inTabContaining: sourcePaneID,
                preferredLayout: preferredLayout
            )
        else {
            return []
        }

        return [.delayedFocus(splitSession.id, delay: Self.splitFocusDelay)]
    }

    private func splitLayout(
        for direction: GhosttyAppManager.SplitDirection?
    ) -> TileTreeStore.SplitPaneLayout {
        switch direction {
        case .left:
            return TileTreeStore.SplitPaneLayout(
                axis: .leadingTrailing,
                splitBeforePrimary: true
            )
        case .up:
            return TileTreeStore.SplitPaneLayout(
                axis: .topBottom,
                splitBeforePrimary: true
            )
        case .down:
            return TileTreeStore.SplitPaneLayout(
                axis: .topBottom,
                splitBeforePrimary: false
            )
        case .right, .none:
            return .defaultTrailing
        }
    }

    private func handleGotoSplit(
        sourceSessionID: UUID?,
        direction: GhosttyAppManager.SplitFocusDirection?,
        tileTreeStore: TileTreeStore
    ) -> [GhosttyTerminalRoutingEffect] {
        guard let sourceSessionID,
            let direction
        else {
            log.error("[SplitRouting] goto_split ignored: missing source or direction")
            return []
        }

        guard
            let targetSessionID = tileTreeStore.splitFocusTarget(
                from: sourceSessionID,
                direction: direction
            )
        else {
            log.error(
                "[SplitRouting] goto_split no-op source=\(sourceSessionID.uuidString, privacy: .public) direction=\(String(describing: direction), privacy: .public)"
            )
            return []
        }

        log.info(
            "[SplitRouting] goto_split source=\(sourceSessionID.uuidString, privacy: .public) target=\(targetSessionID.uuidString, privacy: .public) direction=\(String(describing: direction), privacy: .public)"
        )
        return [.focus(targetSessionID)]
    }

    private func handleResizeSplit(
        sourceSessionID: UUID?,
        direction: GhosttyAppManager.SplitResizeDirection?,
        amount: Int?,
        tileTreeStore: TileTreeStore
    ) {
        guard let sourceSessionID,
            let direction
        else {
            log.error("[SplitRouting] resize_split ignored: missing source or direction")
            return
        }

        let resolvedAmount = max(amount ?? 100, 1)
        guard
            tileTreeStore.resizeSplit(
                containing: sourceSessionID,
                direction: direction,
                amount: resolvedAmount
            )
        else {
            log.error(
                "[SplitRouting] resize_split no-op source=\(sourceSessionID.uuidString, privacy: .public) direction=\(String(describing: direction), privacy: .public) amount=\(resolvedAmount, privacy: .public)"
            )
            return
        }

        log.info(
            "[SplitRouting] resize_split source=\(sourceSessionID.uuidString, privacy: .public) direction=\(String(describing: direction), privacy: .public) amount=\(resolvedAmount, privacy: .public)"
        )
    }

    private func handleEqualizeSplits(
        sourceSessionID: UUID?,
        tileTreeStore: TileTreeStore
    ) {
        guard let sourceSessionID else {
            log.error("[SplitRouting] equalize_splits ignored: missing source")
            return
        }

        guard tileTreeStore.equalizeSplit(containing: sourceSessionID) else {
            log.error("[SplitRouting] equalize_splits no-op source=\(sourceSessionID.uuidString, privacy: .public)")
            return
        }

        log.info("[SplitRouting] equalize_splits source=\(sourceSessionID.uuidString, privacy: .public)")
    }

    private func activateTab(
        _ target: GhosttyAppManager.TabGotoTarget,
        tileTreeStore: TileTreeStore,
        sourceSessionID: UUID?
    ) -> HostTerminalSession? {
        switch target {
        case .previous:
            return tileTreeStore.activateAdjacentTab(offset: -1, from: sourceSessionID)
        case .next:
            return tileTreeStore.activateAdjacentTab(offset: 1, from: sourceSessionID)
        case .last:
            return tileTreeStore.activateLastTab()
        case .index(let index):
            return tileTreeStore.activateTab(atOneBasedIndex: index)
        }
    }
}

extension GhosttySplitIntent {
    init(request: GhosttyAppManager.SplitActionRequest) {
        switch request.kind {
        case .newSplit:
            self = .newSplit(direction: request.splitDirection)
        case .gotoSplit:
            self = .gotoSplit(direction: request.focusDirection)
        case .resizeSplit:
            self = .resizeSplit(direction: request.resizeDirection, amount: request.amount)
        case .equalizeSplits:
            self = .equalizeSplits
        }
    }
}

extension GhosttyTabIntent {
    init(request: GhosttyAppManager.TabActionRequest) {
        switch request.kind {
        case .newTab:
            self = .newTab
        case .closeTab:
            self = .closeTab(mode: request.closeMode)
        case .gotoTab:
            self = .gotoTab(target: request.gotoTarget)
        case .moveTab:
            self = .moveTab(amount: request.moveAmount)
        case .setTabTitle:
            self = .setTabTitle(request.title)
        }
    }
}
