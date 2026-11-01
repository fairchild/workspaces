import Foundation
import Testing

@testable import WorkspaceManager

@Suite("RestoreLaunchCommand")
struct RestoreLaunchCommandTests {
    // The command is intentionally bare — the login-shell/tmux wrapping (and its
    // quoting) now lives in GhosttyTerminalConfig, verified in its own tests.
    @Test("Produces a bare claude --resume command for the restored surface")
    func buildsBareResumeCommand() {
        #expect(RestoreLaunchCommand.claudeResume(sessionID: "sess-123") == "claude --resume sess-123")
    }

    @Test("Carries the conversation's effort, which claude does not restore by itself")
    func carriesEffort() {
        #expect(
            RestoreLaunchCommand.claudeResume(sessionID: "sess-123", effort: "xhigh")
                == "claude --resume sess-123 --effort xhigh"
        )
    }

    @Test("A stored effort that is not a known level never reaches the shell")
    func rejectsUnknownEffort() {
        #expect(
            RestoreLaunchCommand.claudeResume(sessionID: "sess-123", effort: "low; rm -rf ~")
                == "claude --resume sess-123"
        )
    }
}
