//
//  SplitRoutingControllerTests.swift
//  WorkspaceManagerAppTests
//
//  Verifies app-level routing for Ghostty split action notifications.
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("SplitRoutingController")
struct SplitRoutingControllerTests {
    @Test("new_split creates a split in Ghostty-managed mode")
    func newSplitCreatesSplitInGhosttyManagedMode() throws {
        let store = makeStoreWithActiveSession()
        let primaryID = try #require(store.activeSessionID)
        let notification = splitActionNotification(
            kind: .newSplit,
            directionRawValue: GhosttyAppManager.SplitDirection.right.rawValue
        )

        SplitRoutingController().handle(
            notification: notification,
            terminalMultiplexingMode: .ghosttyManagedSplits,
            hostTerminalState: store,
            focusTerminal: { _ in }
        )

        #expect(store.splitSession(for: primaryID) != nil)
        #expect(store.splitLayout(for: primaryID) == .defaultTrailing)
    }

    @Test("new_split is ignored in tmux mode")
    func newSplitIsIgnoredInTmuxMode() throws {
        let store = makeStoreWithActiveSession()
        let primaryID = try #require(store.activeSessionID)
        let notification = splitActionNotification(
            kind: .newSplit,
            directionRawValue: GhosttyAppManager.SplitDirection.right.rawValue
        )

        SplitRoutingController().handle(
            notification: notification,
            terminalMultiplexingMode: .tmuxPerSession,
            hostTerminalState: store,
            focusTerminal: { _ in }
        )

        #expect(store.sessions.count == 1)
        #expect(store.activeSessionID == primaryID)
        #expect(store.splitSession(for: primaryID) == nil)
    }

    @Test("Invalid split action payload leaves terminal state unchanged")
    func invalidSplitActionPayloadLeavesTerminalStateUnchanged() throws {
        let store = makeStoreWithActiveSession()
        let primaryID = try #require(store.activeSessionID)
        let notification = Notification(
            name: GhosttyAppManager.splitActionNotification,
            userInfo: [
                GhosttyAppManager.splitActionDirectionUserInfoKey: GhosttyAppManager.SplitDirection.right.rawValue
            ]
        )

        SplitRoutingController().handle(
            notification: notification,
            terminalMultiplexingMode: .ghosttyManagedSplits,
            hostTerminalState: store,
            focusTerminal: { _ in }
        )

        #expect(store.sessions.count == 1)
        #expect(store.activeSessionID == primaryID)
        #expect(store.splitSession(for: primaryID) == nil)
    }

    @Test("goto_split focuses paired pane")
    func gotoSplitFocusesPairedPane() throws {
        let store = makeStoreWithActiveSession()
        let primarySession = try #require(store.sessions.first)
        let splitSession = try #require(
            store.ensureSplit(
                forPrimarySessionID: primarySession.id,
                preferredLayout: .defaultTrailing
            )
        )
        let primarySurface = store.surfaceStore.view(for: primarySession)
        let notification = splitActionNotification(
            kind: .gotoSplit,
            directionRawValue: GhosttyAppManager.SplitFocusDirection.right.rawValue,
            source: primarySurface
        )
        var focusedSessionIDs: [UUID] = []

        SplitRoutingController().handle(
            notification: notification,
            terminalMultiplexingMode: .ghosttyManagedSplits,
            hostTerminalState: store,
            focusTerminal: { focusedSessionIDs.append($0) }
        )

        #expect(focusedSessionIDs == [splitSession.id])
        #expect(store.activeSessionID == primarySession.id)
    }

    @Test("resize_split updates split fraction")
    func resizeSplitUpdatesSplitFraction() throws {
        let store = makeStoreWithActiveSession()
        let primarySession = try #require(store.sessions.first)
        let splitSession = try #require(
            store.ensureSplit(
                forPrimarySessionID: primarySession.id,
                preferredLayout: .defaultTrailing
            )
        )
        let splitSurface = store.surfaceStore.view(for: splitSession)
        let notification = splitActionNotification(
            kind: .resizeSplit,
            directionRawValue: GhosttyAppManager.SplitResizeDirection.left.rawValue,
            amount: 100,
            source: splitSurface
        )

        SplitRoutingController().handle(
            notification: notification,
            terminalMultiplexingMode: .ghosttyManagedSplits,
            hostTerminalState: store,
            focusTerminal: { _ in }
        )

        #expect(store.splitFraction(for: primarySession.id) == 0.45)
    }

    @Test("equalize_splits resets split fraction")
    func equalizeSplitsResetsSplitFraction() throws {
        let store = makeStoreWithActiveSession()
        let primarySession = try #require(store.sessions.first)
        let splitSession = try #require(
            store.ensureSplit(
                forPrimarySessionID: primarySession.id,
                preferredLayout: .defaultTrailing
            )
        )
        #expect(store.updateSplitFraction(0.7, forPrimarySessionID: primarySession.id))
        let splitSurface = store.surfaceStore.view(for: splitSession)
        let notification = splitActionNotification(
            kind: .equalizeSplits,
            directionRawValue: nil,
            source: splitSurface
        )

        SplitRoutingController().handle(
            notification: notification,
            terminalMultiplexingMode: .ghosttyManagedSplits,
            hostTerminalState: store,
            focusTerminal: { _ in }
        )

        #expect(store.splitFraction(for: primarySession.id) == HostTerminalStateStore.defaultSplitFraction)
    }

    private func makeStoreWithActiveSession() -> HostTerminalStateStore {
        let store = HostTerminalStateStore()
        _ = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        return store
    }

    private func splitActionNotification(
        kind: GhosttyAppManager.SplitActionKind,
        directionRawValue: Int?,
        amount: Int? = nil,
        source: GhosttySurfaceView? = nil
    ) -> Notification {
        var userInfo: [String: Any] = [
            GhosttyAppManager.splitActionKindUserInfoKey: kind.rawValue
        ]
        if let directionRawValue {
            userInfo[GhosttyAppManager.splitActionDirectionUserInfoKey] = directionRawValue
        }
        if let amount {
            userInfo[GhosttyAppManager.splitActionAmountUserInfoKey] = amount
        }

        return Notification(
            name: GhosttyAppManager.splitActionNotification,
            object: source,
            userInfo: userInfo
        )
    }
}
