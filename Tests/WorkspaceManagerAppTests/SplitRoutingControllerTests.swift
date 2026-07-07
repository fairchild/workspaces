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
            tileTreeStore: store,
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
            tileTreeStore: store,
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
            tileTreeStore: store,
            focusTerminal: { _ in }
        )

        #expect(store.sessions.count == 1)
        #expect(store.activeSessionID == primaryID)
        #expect(store.splitSession(for: primaryID) == nil)
    }

    private func makeStoreWithActiveSession() -> TileTreeStore {
        let store = TileTreeStore()
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
