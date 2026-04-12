import Foundation
import Testing

@testable import WorkspaceManager

@Suite("GhosttySplitActionRequest")
struct GhosttySplitActionRequestTests {
    @Test("Parses resize split action payload")
    func parsesResizeSplitActionPayload() throws {
        let notification = Notification(
            name: GhosttyAppManager.splitActionNotification,
            userInfo: [
                GhosttyAppManager.splitActionKindUserInfoKey: GhosttyAppManager.SplitActionKind.resizeSplit.rawValue,
                GhosttyAppManager.splitActionDirectionUserInfoKey: GhosttyAppManager.SplitResizeDirection.left.rawValue,
                GhosttyAppManager.splitActionAmountUserInfoKey: 200,
            ]
        )

        let request = try #require(GhosttyAppManager.splitActionRequest(from: notification))
        #expect(request.kind == .resizeSplit)
        #expect(request.resizeDirection == .left)
        #expect(request.amount == 200)
    }

    @Test("Parses equalize split action payload without direction")
    func parsesEqualizeSplitActionPayloadWithoutDirection() throws {
        let notification = Notification(
            name: GhosttyAppManager.splitActionNotification,
            userInfo: [
                GhosttyAppManager.splitActionKindUserInfoKey: GhosttyAppManager.SplitActionKind.equalizeSplits.rawValue
            ]
        )

        let request = try #require(GhosttyAppManager.splitActionRequest(from: notification))
        #expect(request.kind == .equalizeSplits)
        #expect(request.directionRawValue == nil)
        #expect(request.amount == nil)
    }
}
