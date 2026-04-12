import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("SidebarSessionPresentation")
struct SidebarSessionPresentationTests {
    @Test("Session activity derives inactive/live/active state from session flags")
    func activityDerivationFromFlags() {
        #expect(
            SidebarSessionActivity(hasLiveSession: false, isActiveSession: false)
                == .inactive
        )
        #expect(
            SidebarSessionActivity(hasLiveSession: true, isActiveSession: false)
                == .live
        )
        #expect(
            SidebarSessionActivity(hasLiveSession: true, isActiveSession: true)
                == .active
        )
        #expect(
            SidebarSessionActivity(hasLiveSession: false, isActiveSession: true)
                == .active
        )
    }

    @Test("Activity reports whether any live session exists")
    func activityLiveSessionFlag() {
        #expect(!SidebarSessionActivity.inactive.hasLiveSession)
        #expect(SidebarSessionActivity.live.hasLiveSession)
        #expect(SidebarSessionActivity.active.hasLiveSession)
    }

    @Test("Pane count badge appears only when more than one pane exists")
    func paneCountBadgeThreshold() {
        #expect(!SidebarSessionActivity.showsPaneCountBadge(for: 0))
        #expect(!SidebarSessionActivity.showsPaneCountBadge(for: 1))
        #expect(SidebarSessionActivity.showsPaneCountBadge(for: 2))
        #expect(SidebarSessionActivity.showsPaneCountBadge(for: 3))
    }

    @Test("Sidebar active key is suppressed while web source is selected")
    func activeSessionKeySuppressedForWebSelection() {
        let sessionID = UUID()
        let session = HostTerminalSession(
            id: sessionID,
            key: .repoPath("/Users/test/code/repo"),
            directory: URL(fileURLWithPath: "/Users/test/code/repo")
        )

        let resolved = ContentView.sidebarActiveSessionKey(
            selectedWebSourceID: UUID(),
            activeSessionID: sessionID,
            sessions: [session]
        )

        #expect(resolved == nil)
    }

    @Test("Sidebar active key resolves from terminal state when web is not selected")
    func activeSessionKeyResolvesFromTerminalState() {
        let sessionID = UUID()
        let session = HostTerminalSession(
            id: sessionID,
            key: .repoPath("/Users/test/code/repo"),
            directory: URL(fileURLWithPath: "/Users/test/code/repo")
        )

        let resolved = ContentView.sidebarActiveSessionKey(
            selectedWebSourceID: nil,
            activeSessionID: sessionID,
            sessions: [session]
        )

        #expect(resolved == .repoPath("/Users/test/code/repo"))
    }
}
