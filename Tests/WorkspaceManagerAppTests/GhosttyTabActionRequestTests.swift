import Foundation
import Testing

@testable import WorkspaceManager

@Suite("GhosttyTabActionRequest")
struct GhosttyTabActionRequestTests {
    @Test("Parses close tab action payload")
    func parsesCloseTabActionPayload() throws {
        let notification = Notification(
            name: GhosttyAppManager.tabActionNotification,
            userInfo: [
                GhosttyAppManager.tabActionKindUserInfoKey: GhosttyAppManager.TabActionKind.closeTab.rawValue,
                GhosttyAppManager.tabActionCloseModeUserInfoKey: GhosttyAppManager.TabCloseMode.right.rawValue,
            ]
        )

        let request = try #require(GhosttyAppManager.tabActionRequest(from: notification))
        #expect(request.kind == .closeTab)
        #expect(request.closeMode == .right)
    }

    @Test("Parses goto tab action payloads")
    func parsesGotoTabActionPayloads() throws {
        let next = try #require(
            GhosttyAppManager.tabActionRequest(
                from: Notification(
                    name: GhosttyAppManager.tabActionNotification,
                    userInfo: [
                        GhosttyAppManager.tabActionKindUserInfoKey: GhosttyAppManager.TabActionKind.gotoTab.rawValue,
                        GhosttyAppManager.tabActionGotoUserInfoKey: -2,
                    ]
                )
            )
        )
        let indexed = try #require(
            GhosttyAppManager.tabActionRequest(
                from: Notification(
                    name: GhosttyAppManager.tabActionNotification,
                    userInfo: [
                        GhosttyAppManager.tabActionKindUserInfoKey: GhosttyAppManager.TabActionKind.gotoTab.rawValue,
                        GhosttyAppManager.tabActionGotoUserInfoKey: 3,
                    ]
                )
            )
        )

        #expect(next.gotoTarget == .next)
        #expect(indexed.gotoTarget == .index(3))
    }

    @Test("Parses set tab title action payload")
    func parsesSetTabTitleActionPayload() throws {
        let notification = Notification(
            name: GhosttyAppManager.tabActionNotification,
            userInfo: [
                GhosttyAppManager.tabActionKindUserInfoKey: GhosttyAppManager.TabActionKind.setTabTitle.rawValue,
                GhosttyAppManager.tabActionTitleUserInfoKey: "Build",
            ]
        )

        let request = try #require(GhosttyAppManager.tabActionRequest(from: notification))
        #expect(request.kind == .setTabTitle)
        #expect(request.title == "Build")
    }
}
