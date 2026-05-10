import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("TabRoutingController")
struct TabRoutingControllerTests {
    @Test("new_tab notification forwards through adapter")
    func newTabNotificationForwardsThroughAdapter() throws {
        let store = makeStore()
        let first = try #require(store.sessions.first)
        let source = store.surfaceStore.view(for: first)
        var focusedSessionIDs: [UUID] = []

        TabRoutingController().handle(
            notification: tabActionNotification(kind: .newTab, source: source),
            hostTerminalState: store,
            focusTerminal: { focusedSessionIDs.append($0) },
            requestCloseTabs: { _ in }
        )

        #expect(store.sessions.count == 2)
        #expect(store.sessions[1].key == first.key)
        #expect(focusedSessionIDs == [store.sessions[1].id])
    }

    @Test("close_tab notification forwards close request effect")
    func closeTabNotificationForwardsCloseRequestEffect() throws {
        let store = makeStore()
        let first = try #require(store.sessions.first)
        let second = try #require(store.createTab())
        let third = try #require(store.createTab())
        let source = store.surfaceStore.view(for: second)
        var closeRequests: [[UUID]] = []

        TabRoutingController().handle(
            notification: tabActionNotification(kind: .closeTab, closeModeRawValue: 2, source: source),
            hostTerminalState: store,
            focusTerminal: { _ in },
            requestCloseTabs: { closeRequests.append($0) }
        )

        #expect(first.id != second.id)
        #expect(closeRequests == [[third.id]])
    }

    @Test("Invalid tab action payload leaves terminal state unchanged")
    func invalidTabActionPayloadLeavesTerminalStateUnchanged() throws {
        let store = makeStore()
        let initialSessionIDs = store.sessions.map(\.id)
        var focusedSessionIDs: [UUID] = []
        var closeRequests: [[UUID]] = []

        TabRoutingController().handle(
            notification: Notification(
                name: GhosttyAppManager.tabActionNotification,
                userInfo: [
                    GhosttyAppManager.tabActionGotoUserInfoKey: -2
                ]
            ),
            hostTerminalState: store,
            focusTerminal: { focusedSessionIDs.append($0) },
            requestCloseTabs: { closeRequests.append($0) }
        )

        #expect(store.sessions.map(\.id) == initialSessionIDs)
        #expect(focusedSessionIDs.isEmpty)
        #expect(closeRequests.isEmpty)
    }

    private func makeStore() -> HostTerminalStateStore {
        let store = HostTerminalStateStore()
        _ = store.activateSession(
            key: .repoPath("/Users/test/repo"),
            directory: URL(fileURLWithPath: "/Users/test/repo")
        )
        return store
    }

    private func tabActionNotification(
        kind: GhosttyAppManager.TabActionKind,
        closeModeRawValue: Int? = nil,
        gotoRawValue: Int? = nil,
        moveAmount: Int? = nil,
        title: String? = nil,
        source: GhosttySurfaceView? = nil
    ) -> Notification {
        var userInfo: [String: Any] = [
            GhosttyAppManager.tabActionKindUserInfoKey: kind.rawValue
        ]
        if let closeModeRawValue {
            userInfo[GhosttyAppManager.tabActionCloseModeUserInfoKey] = closeModeRawValue
        }
        if let gotoRawValue {
            userInfo[GhosttyAppManager.tabActionGotoUserInfoKey] = gotoRawValue
        }
        if let moveAmount {
            userInfo[GhosttyAppManager.tabActionMoveAmountUserInfoKey] = moveAmount
        }
        if let title {
            userInfo[GhosttyAppManager.tabActionTitleUserInfoKey] = title
        }

        return Notification(
            name: GhosttyAppManager.tabActionNotification,
            object: source,
            userInfo: userInfo
        )
    }
}
