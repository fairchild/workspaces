import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("TerminalForegroundProcessResolver")
struct TerminalForegroundProcessResolverTests {
    private func session() -> HostTerminalSession {
        HostTerminalSession(
            key: .repoPath("/tmp/repo-\(UUID().uuidString)"),
            directory: URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)")
        )
    }

    // MARK: - Fallback ladder

    @Test("A resolved foreground name is preferred over the terminal title")
    func prefersForegroundName() {
        #expect(
            TerminalForegroundProcessResolver.preferredTabTitle(
                foregroundName: "vim", terminalTitle: "~/repo") == "vim")
    }

    @Test("Falls back to the terminal title when no name resolved")
    func fallsBackToTitle() {
        #expect(
            TerminalForegroundProcessResolver.preferredTabTitle(
                foregroundName: nil, terminalTitle: "~/repo") == "~/repo")
        #expect(
            TerminalForegroundProcessResolver.preferredTabTitle(
                foregroundName: "   ", terminalTitle: "~/repo") == "~/repo")
    }

    // MARK: - Mode gating

    @Test("tmux mode resolves the real foreground command")
    func tmuxModeResolves() async {
        let resolver = TerminalForegroundProcessResolver(
            probe: TmuxSessionProbe(runForOutput: { _, _, _ in "1 vim\n" }, environment: [:]),
            tmuxSessionName: { _ in "wm-repo-abcd1234" }
        )
        let name = await resolver.foregroundName(for: session(), mode: .tmuxPerSession)
        #expect(name == "vim")
    }

    @Test("ghostty-splits mode does not attempt detection and returns nil")
    func ghosttyModeReturnsNil() async {
        // The probe would return "vim", but the mode gate must short-circuit before calling it.
        let resolver = TerminalForegroundProcessResolver(
            probe: TmuxSessionProbe(runForOutput: { _, _, _ in "1 vim\n" }, environment: [:]),
            tmuxSessionName: { _ in "wm-repo-abcd1234" }
        )
        let name = await resolver.foregroundName(for: session(), mode: .ghosttyManagedSplits)
        #expect(name == nil)
    }

    @Test("An unavailable tmux session resolves to nil (title fallback upstream)")
    func unavailableSessionReturnsNil() async {
        let resolver = TerminalForegroundProcessResolver(
            probe: TmuxSessionProbe(runForOutput: { _, _, _ in nil }, environment: [:]),
            tmuxSessionName: { _ in "wm-repo-abcd1234" }
        )
        let name = await resolver.foregroundName(for: session(), mode: .tmuxPerSession)
        #expect(name == nil)
    }
}
