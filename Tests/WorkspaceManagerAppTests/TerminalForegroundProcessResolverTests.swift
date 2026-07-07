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

    private func resolver(
        tmuxOutput: String?,
        cwdProgram: String?
    ) -> TerminalForegroundProcessResolver {
        TerminalForegroundProcessResolver(
            probe: TmuxSessionProbe(runForOutput: { _, _, _ in tmuxOutput }, environment: [:]),
            tmuxSessionName: { _ in "wm-repo-abcd1234" },
            cwdProgramName: { _ in cwdProgram }
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

    // MARK: - Resolution ladder

    @Test("tmux mode prefers the exact per-pane command over the cwd program")
    func tmuxModePrefersPaneCommand() async {
        let resolver = resolver(tmuxOutput: "1 vim\n", cwdProgram: "python")
        #expect(await resolver.foregroundName(for: session(), mode: .tmuxPerSession) == "vim")
    }

    @Test("tmux mode falls back to the cwd program when the pane query is unavailable")
    func tmuxModeFallsBackToCwd() async {
        let resolver = resolver(tmuxOutput: nil, cwdProgram: "python")
        #expect(await resolver.foregroundName(for: session(), mode: .tmuxPerSession) == "python")
    }

    @Test("ghostty-splits mode (default) resolves via the cwd program")
    func ghosttyModeResolvesViaCwd() async {
        // No tmux query in this mode; the directory's running program still resolves.
        let resolver = resolver(tmuxOutput: "1 vim\n", cwdProgram: "python")
        #expect(await resolver.foregroundName(for: session(), mode: .ghosttyManagedSplits) == "python")
    }

    @Test("A bare shell (no non-shell program, no tmux) resolves to nil for title fallback")
    func bareShellResolvesNil() async {
        let resolver = resolver(tmuxOutput: nil, cwdProgram: nil)
        #expect(await resolver.foregroundName(for: session(), mode: .ghosttyManagedSplits) == nil)
    }

    // MARK: - cwd program selection (shell/agent filtering)

    @Test("cwd selection skips known agents and picks the plain program")
    func cwdSelectionSkipsKnownAgents() {
        let status = WorkspaceProcessMonitor.AgentStatus(processes: [
            WorkspaceProcessMonitor.DetectedProcess(displayName: "Claude", isKnownAgent: true),
            WorkspaceProcessMonitor.DetectedProcess(displayName: "vim", isKnownAgent: false),
        ])
        #expect(TerminalForegroundProcessResolver.programName(from: status) == "vim")
    }

    @Test("cwd selection yields nil when only agents run and for a bare shell")
    func cwdSelectionNilForAgentOnlyOrBareShell() {
        let agentOnly = WorkspaceProcessMonitor.AgentStatus(processes: [
            WorkspaceProcessMonitor.DetectedProcess(displayName: "Claude", isKnownAgent: true)
        ])
        #expect(TerminalForegroundProcessResolver.programName(from: agentOnly) == nil)
        // WorkspaceProcessMonitor already drops shells, so a bare shell yields no processes.
        #expect(TerminalForegroundProcessResolver.programName(from: .inactive) == nil)
    }
}
