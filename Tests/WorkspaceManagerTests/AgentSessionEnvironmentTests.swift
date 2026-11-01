//
//  AgentSessionEnvironmentTests.swift
//  WorkspaceManagerTests
//
//  Pins which variables count as the caller's identity. A key dropped from this set
//  would be inherited by every session on the shared tmux socket, and a key added to it
//  by mistake would be missing from every launched session, so both directions matter.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Agent session environment")
struct AgentSessionEnvironmentTests {
    @Test(
        "An agent's own variables belong to the caller",
        arguments: [
            "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_MESSAGING_SOCKET",
            "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ID", "CLAUDE_EFFORT", "CLAUDE_PID",
            "CLAUDE_CONFIG_DIR", "CLAUDE_SOMETHING_ADDED_NEXT_MONTH", "AI_AGENT",
            "CODEX_THREAD_ID", "CODEX_SANDBOX", "CODEX_SESSION_ID", "CODEX_SOMETHING_ADDED_NEXT_MONTH",
            "WORKSPACES_HOST_SESSION_ID", "WORKSPACES_HOOKS_SOCKET", "WORKSPACES_COMMAND_STATUS_ZSH",
            AutomationAPI.socketEnvironmentKey, AutomationAPI.handleEnvironmentKey,
        ]
    )
    func callerKeys(key: String) {
        #expect(AgentSessionEnvironment.belongsToCaller(key))
    }

    @Test(
        "What a session needs from its environment stays",
        arguments: [
            "PATH", "HOME", "SHELL", "LANG", "TERM", "SSH_AUTH_SOCK", "ANTHROPIC_API_KEY", "OPENAI_API_KEY",
            "TMUX_TMPDIR", "XDG_CONFIG_HOME", "WORKSPACES_TMUX_SOCKET_LABEL", "WORKSPACES_DATA_DIR",
            "NOT_CLAUDE_EFFORT", "MYCODEX_THREAD_ID", "CODEX",
        ]
    )
    func ordinaryKeys(key: String) {
        #expect(!AgentSessionEnvironment.belongsToCaller(key))
    }

    @Test("Filtering an environment keeps everything that is not the caller's")
    func filtering() {
        let filtered = AgentSessionEnvironment.removingCallerIdentity(
            from: ["PATH": "/bin", "CLAUDE_PID": "1", "AI_AGENT": "x", "HOME": "/h"]
        )
        #expect(filtered == ["PATH": "/bin", "HOME": "/h"])
    }

    @Test("A process outliving its caller also drops the caller's pane; a filtered child keeps it")
    func callerPane() {
        #expect(!AgentSessionEnvironment.belongsToCaller("TMUX"))
        let removed = AgentSessionEnvironment.removeCallerIdentityFromProcess(
            environment: ["TMUX_AGENT_SESSION_ENV_TEST": "1", "TMUX_PANE": "%3"]
        )
        #expect(removed == ["TMUX_PANE"])
    }

    @Test("Clearing the process removes the caller's variables and leaves the rest")
    func clearingTheProcess() {
        setenv("CLAUDE_AGENT_SESSION_ENV_TEST", "1", 1)
        setenv("AGENT_SESSION_ENV_TEST_CONTROL", "1", 1)
        defer { unsetenv("AGENT_SESSION_ENV_TEST_CONTROL") }

        let removed = AgentSessionEnvironment.removeCallerIdentityFromProcess(
            environment: ["CLAUDE_AGENT_SESSION_ENV_TEST": "1", "AGENT_SESSION_ENV_TEST_CONTROL": "1"]
        )

        #expect(removed == ["CLAUDE_AGENT_SESSION_ENV_TEST"])
        #expect(getenv("CLAUDE_AGENT_SESSION_ENV_TEST") == nil)
        #expect(getenv("AGENT_SESSION_ENV_TEST_CONTROL") != nil)
    }
}
