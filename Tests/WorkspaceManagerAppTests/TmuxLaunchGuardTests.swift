import Testing

@testable import WorkspaceManager

@Suite("TmuxLaunchGuard")
struct TmuxLaunchGuardTests {
    @Test("This test process knows it is one, so a surface it realizes is checked")
    func recognizesTheTestProcess() {
        #expect(TmuxLaunchGuard.isTestProcess)
    }

    @Test("A test may not launch tmux on a live socket; the app and isolated labels may")
    func refusesOnlyLiveLabelsInTests() {
        #expect(TmuxLaunchGuard.refusal(socketLabel: "workspaces", inTestProcess: true) != nil)
        #expect(TmuxLaunchGuard.refusal(socketLabel: "workspaces-rejected-label", inTestProcess: true) != nil)
        #expect(TmuxLaunchGuard.refusal(socketLabel: "wstest-1a2b3c4d", inTestProcess: true) == nil)
        #expect(TmuxLaunchGuard.refusal(socketLabel: "workspaces", inTestProcess: false) == nil)
    }
}
