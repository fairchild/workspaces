import Foundation
import Testing

@testable import WorkspaceManager

@Suite("RestoreLaunchCommand")
struct RestoreLaunchCommandTests {
    @Test("Wraps claude --resume in a deterministic -L workspaces tmux session")
    func buildsResumeCommand() {
        let cwd = URL(fileURLWithPath: "/code/app")
        let name = GhosttyTerminalConfig.tmuxSessionName(for: cwd)
        let command = RestoreLaunchCommand.claudeResume(cwd: cwd, sessionID: "sess-123")

        #expect(command == "tmux -L 'workspaces' new-session -A -s '\(name)' -c '/code/app' 'claude --resume sess-123'")
    }

    @Test("Uses the same session name a normal launch would, so restore reattaches")
    func nameMatchesNormalLaunch() {
        let cwd = URL(fileURLWithPath: "/Users/me/proj")
        let command = RestoreLaunchCommand.claudeResume(cwd: cwd, sessionID: "s1")
        #expect(command.contains("-s '\(GhosttyTerminalConfig.tmuxSessionName(for: cwd))'"))
    }

    @Test("Single quotes in the session id are escaped safely")
    func escapesQuotes() {
        let command = RestoreLaunchCommand.claudeResume(cwd: URL(fileURLWithPath: "/x"), sessionID: "a'b")
        #expect(command.hasSuffix("'claude --resume a'\"'\"'b'"))
    }
}
