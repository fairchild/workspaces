import Foundation

@MainActor
struct SplitRoutingController {
    func handle(
        notification: Notification,
        terminalMultiplexingMode: TerminalMultiplexingMode,
        hostTerminalState: HostTerminalStateStore,
        focusTerminal: @escaping (UUID) -> Void
    ) {
        guard terminalMultiplexingMode == .ghosttyManagedSplits else {
            NSLog(
                "[SplitRouting] Ignored split action while terminal mode=%@",
                terminalMultiplexingMode.rawValue
            )
            return
        }

        guard let request = GhosttyAppManager.splitActionRequest(from: notification) else {
            NSLog("[SplitRouting] Ignored split action notification with invalid payload")
            return
        }

        let sourceSessionID =
            (notification.object as? GhosttySurfaceView)
            .flatMap { hostTerminalState.surfaceStore.sessionID(for: $0) }

        switch request.kind {
        case .newSplit:
            handleNewSplit(
                sourceSessionID: sourceSessionID,
                direction: request.splitDirection,
                hostTerminalState: hostTerminalState,
                focusTerminal: focusTerminal
            )
        case .gotoSplit:
            handleGotoSplit(
                sourceSessionID: sourceSessionID,
                direction: request.focusDirection,
                hostTerminalState: hostTerminalState,
                focusTerminal: focusTerminal
            )
        case .resizeSplit:
            handleResizeSplit(
                sourceSessionID: sourceSessionID,
                direction: request.resizeDirection,
                amount: request.amount,
                hostTerminalState: hostTerminalState
            )
        case .equalizeSplits:
            handleEqualizeSplits(
                sourceSessionID: sourceSessionID,
                hostTerminalState: hostTerminalState
            )
        }
    }

    private func handleNewSplit(
        sourceSessionID: UUID?,
        direction: GhosttyAppManager.SplitDirection?,
        hostTerminalState: HostTerminalStateStore,
        focusTerminal: @escaping (UUID) -> Void
    ) {
        let primarySessionID =
            sourceSessionID.flatMap { hostTerminalState.activatePrimarySession(containing: $0) }
            ?? hostTerminalState.activeSessionID

        guard let primarySessionID else {
            NSLog("[SplitRouting] new_split ignored: no active/primary session")
            return
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
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            focusTerminal(splitSession.id)
        }
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
        hostTerminalState: HostTerminalStateStore,
        focusTerminal: @escaping (UUID) -> Void
    ) {
        guard let sourceSessionID,
            let direction
        else {
            NSLog("[SplitRouting] goto_split ignored: missing source or direction")
            return
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
            return
        }

        NSLog(
            "[SplitRouting] goto_split source=%@ target=%@ direction=%@",
            sourceSessionID.uuidString,
            targetSessionID.uuidString,
            String(describing: direction)
        )
        focusTerminal(targetSessionID)
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
}
