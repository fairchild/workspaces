import Foundation
import Testing

@testable import WorkspaceManager

@Suite("TerminalChromePolicy")
struct TerminalChromePolicyTests {
    @Test("Current terminal pane chrome policy is minimal and restart-free")
    func currentPolicyIsMinimalAndRestartFree() {
        let policy = TerminalPaneChromePolicy.current

        #expect(policy == .minimal)
        #expect(!policy.showsPaneHeader)
        #expect(!policy.showsManualRestartControl)
    }

    @Test("Terminal container identity token is path-scoped")
    func terminalContainerIdentityTokenIsPathScoped() {
        let first = URL(fileURLWithPath: "/Users/test/code/repo-a")
        let second = URL(fileURLWithPath: "/Users/test/code/repo-b")

        #expect(TerminalContainerView.identityToken(for: first) == first.path)
        #expect(TerminalContainerView.identityToken(for: second) == second.path)
        #expect(
            TerminalContainerView.identityToken(for: first)
                != TerminalContainerView.identityToken(for: second)
        )
    }

    @Test("Persistent host container identity token is session-scoped")
    func persistentHostIdentityTokenIsSessionScoped() {
        let first = UUID()
        let second = UUID()

        #expect(PersistentHostTerminalContainerView.identityToken(for: first) == first)
        #expect(PersistentHostTerminalContainerView.identityToken(for: second) == second)
        #expect(
            PersistentHostTerminalContainerView.identityToken(for: first)
                != PersistentHostTerminalContainerView.identityToken(for: second)
        )
    }
}
