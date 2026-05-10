import Foundation
import WorkspaceManagerCore

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
        hostTerminalState: HostTerminalStateStore
    ) -> [GhosttyTerminalRoutingEffect] {
        switch intent {
        case .split(let splitIntent):
            guard terminalMultiplexingMode == .ghosttyManagedSplits else {
                NSLog(
                    "[SplitRouting] Ignored split action while terminal mode=%@",
                    terminalMultiplexingMode.rawValue
                )
                return []
            }
            return routeSplit(
                splitIntent,
                sourceSessionID: sourceSessionID,
                hostTerminalState: hostTerminalState
            )
        case .tab(let tabIntent):
            return routeTab(
                tabIntent,
                sourceSessionID: sourceSessionID,
                hostTerminalState: hostTerminalState
            )
        }
    }

    private func routeSplit(
        _ intent: GhosttySplitIntent,
        sourceSessionID: UUID?,
        hostTerminalState: HostTerminalStateStore
    ) -> [GhosttyTerminalRoutingEffect] {
        switch intent {
        case .newSplit(let direction):
            return handleNewSplit(
                sourceSessionID: sourceSessionID,
                direction: direction,
                hostTerminalState: hostTerminalState
            )
        case .gotoSplit(let direction):
            return handleGotoSplit(
                sourceSessionID: sourceSessionID,
                direction: direction,
                hostTerminalState: hostTerminalState
            )
        case .resizeSplit(let direction, let amount):
            handleResizeSplit(
                sourceSessionID: sourceSessionID,
                direction: direction,
                amount: amount,
                hostTerminalState: hostTerminalState
            )
            return []
        case .equalizeSplits:
            handleEqualizeSplits(
                sourceSessionID: sourceSessionID,
                hostTerminalState: hostTerminalState
            )
            return []
        }
    }

    private func routeTab(
        _ intent: GhosttyTabIntent,
        sourceSessionID: UUID?,
        hostTerminalState: HostTerminalStateStore
    ) -> [GhosttyTerminalRoutingEffect] {
        switch intent {
        case .newTab:
            guard let session = hostTerminalState.createTab(from: sourceSessionID) else {
                NSLog("[TabRouting] new_tab ignored: no source/active session")
                return []
            }
            return [.focus(session.id)]

        case .closeTab(let mode):
            let tabIDs = hostTerminalState.tabIDsForClose(
                mode: mode,
                sourceSessionID: sourceSessionID
            )
            guard !tabIDs.isEmpty else {
                NSLog("[TabRouting] close_tab no-op mode=%@", String(describing: mode))
                return []
            }
            return [.closeTabs(tabIDs)]

        case .gotoTab(let target):
            guard let target,
                let session = activateTab(
                    target,
                    hostTerminalState: hostTerminalState,
                    sourceSessionID: sourceSessionID
                )
            else {
                NSLog("[TabRouting] goto_tab no-op target=%@", String(describing: target))
                return []
            }
            return [.focus(session.id)]

        case .moveTab(let amount):
            let resolvedAmount = amount ?? 0
            guard hostTerminalState.moveTab(containing: sourceSessionID, offset: resolvedAmount),
                let activeSessionID = hostTerminalState.activeSessionID
            else {
                NSLog("[TabRouting] move_tab no-op amount=%d", resolvedAmount)
                return []
            }
            return [.focus(activeSessionID)]

        case .setTabTitle(let title):
            guard hostTerminalState.setTabTitle(title, for: sourceSessionID) else {
                NSLog("[TabRouting] set_tab_title no-op")
                return []
            }
            return []
        }
    }

    private func handleNewSplit(
        sourceSessionID: UUID?,
        direction: GhosttyAppManager.SplitDirection?,
        hostTerminalState: HostTerminalStateStore
    ) -> [GhosttyTerminalRoutingEffect] {
        let primarySessionID =
            sourceSessionID.flatMap { hostTerminalState.activatePrimarySession(containing: $0) }
            ?? hostTerminalState.activeSessionID

        guard let primarySessionID else {
            NSLog("[SplitRouting] new_split ignored: no active/primary session")
            return []
        }
        NSLog(
            "[SplitRouting] new_split source=%@ primary=%@",
            sourceSessionID?.uuidString ?? "nil",
            primarySessionID.uuidString
        )
        let preferredLayout = splitLayout(for: direction)
        NSLog(
            "[SplitRouting] new_split layout axis=%@ splitBeforePrimary=%@ direction=%@",
            preferredLayout.axis == .topBottom ? "topBottom" : "leadingTrailing",
            preferredLayout.splitBeforePrimary ? "true" : "false",
            String(describing: direction)
        )

        guard
            let splitSession = hostTerminalState.ensureSplit(
                forPrimarySessionID: primarySessionID,
                preferredLayout: preferredLayout
            )
        else {
            return []
        }

        return [.delayedFocus(splitSession.id, delay: Self.splitFocusDelay)]
    }

    private func splitLayout(
        for direction: GhosttyAppManager.SplitDirection?
    ) -> HostTerminalStateStore.SplitPaneLayout {
        switch direction {
        case .left:
            return HostTerminalStateStore.SplitPaneLayout(
                axis: .leadingTrailing,
                splitBeforePrimary: true
            )
        case .up:
            return HostTerminalStateStore.SplitPaneLayout(
                axis: .topBottom,
                splitBeforePrimary: true
            )
        case .down:
            return HostTerminalStateStore.SplitPaneLayout(
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
        hostTerminalState: HostTerminalStateStore
    ) -> [GhosttyTerminalRoutingEffect] {
        guard let sourceSessionID,
            let direction
        else {
            NSLog("[SplitRouting] goto_split ignored: missing source or direction")
            return []
        }

        guard
            let targetSessionID = hostTerminalState.splitFocusTarget(
                from: sourceSessionID,
                direction: direction
            )
        else {
            NSLog(
                "[SplitRouting] goto_split no-op source=%@ direction=%@",
                sourceSessionID.uuidString,
                String(describing: direction)
            )
            return []
        }

        NSLog(
            "[SplitRouting] goto_split source=%@ target=%@ direction=%@",
            sourceSessionID.uuidString,
            targetSessionID.uuidString,
            String(describing: direction)
        )
        return [.focus(targetSessionID)]
    }

    private func handleResizeSplit(
        sourceSessionID: UUID?,
        direction: GhosttyAppManager.SplitResizeDirection?,
        amount: Int?,
        hostTerminalState: HostTerminalStateStore
    ) {
        guard let sourceSessionID,
            let direction
        else {
            NSLog("[SplitRouting] resize_split ignored: missing source or direction")
            return
        }

        let resolvedAmount = max(amount ?? 100, 1)
        guard
            hostTerminalState.resizeSplit(
                containing: sourceSessionID,
                direction: direction,
                amount: resolvedAmount
            )
        else {
            NSLog(
                "[SplitRouting] resize_split no-op source=%@ direction=%@ amount=%d",
                sourceSessionID.uuidString,
                String(describing: direction),
                resolvedAmount
            )
            return
        }

        NSLog(
            "[SplitRouting] resize_split source=%@ direction=%@ amount=%d",
            sourceSessionID.uuidString,
            String(describing: direction),
            resolvedAmount
        )
    }

    private func handleEqualizeSplits(
        sourceSessionID: UUID?,
        hostTerminalState: HostTerminalStateStore
    ) {
        guard let sourceSessionID else {
            NSLog("[SplitRouting] equalize_splits ignored: missing source")
            return
        }

        guard hostTerminalState.equalizeSplit(containing: sourceSessionID) else {
            NSLog("[SplitRouting] equalize_splits no-op source=%@", sourceSessionID.uuidString)
            return
        }

        NSLog("[SplitRouting] equalize_splits source=%@", sourceSessionID.uuidString)
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
