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
        source: GhosttySurfaceView? = nil
    ) -> Notification {
        var userInfo: [String: Any] = [
            GhosttyAppManager.splitActionKindUserInfoKey: kind.rawValue
        ]
        if let directionRawValue {
            userInfo[GhosttyAppManager.splitActionDirectionUserInfoKey] = directionRawValue
        }

        return Notification(
            name: GhosttyAppManager.splitActionNotification,
            object: source,
            userInfo: userInfo
        )
    }
}
