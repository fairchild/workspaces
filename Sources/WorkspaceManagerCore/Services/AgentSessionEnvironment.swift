//
//  AgentSessionEnvironment.swift
//  WorkspaceManagerCore
//
//  Names the environment variables that say which agent session a process is running
//  inside, so a session started from there begins as itself. Agents export these for
//  their own children, and one of them, `CLAUDE_CODE_CHILD_SESSION`, turns off
//  transcript saving. On the shared tmux socket they do worse: the first client's
//  environment becomes the server's, and every later pane inherits it.
//

import Foundation

public enum AgentSessionEnvironment {
    /// Matched as families rather than listed by name: a variable an agent adds next
    /// month carries the same prefix, and an enumeration would miss it silently.
    /// Includes account selection such as `CLAUDE_CONFIG_DIR`, because on the shared
    /// server that value would move every later session onto the caller's account.
    /// A login shell that exports one of these itself still does so inside the pane.
    static let callerPrefixes = ["CLAUDE", "CODEX_"]
    static let callerKeys: Set<String> = ["AI_AGENT"]

    /// Keys whose values belong to one tile and one launch: the automation handle a CLI
    /// verb resolves its caller from, its socket, and the hook context that attributes
    /// status to a host session. A session launched from a tile that kept these would
    /// report its work as the tile's.
    public static let tileScopedKeys: [String] = [
        AutomationAPI.socketEnvironmentKey,
        AutomationAPI.handleEnvironmentKey,
        "WORKSPACES_HOOKS_SOCKET",
        "WORKSPACES_HOST_SESSION_ID",
        "WORKSPACES_COMMAND_STATUS_ZSH",
    ]

    public static func isAgentIdentity(_ key: String) -> Bool {
        callerKeys.contains(key) || callerPrefixes.contains { key.hasPrefix($0) }
    }

    public static func belongsToCaller(_ key: String) -> Bool {
        isAgentIdentity(key) || tileScopedKeys.contains(key)
    }

    public static func removingCallerIdentity(from environment: [String: String]) -> [String: String] {
        environment.filter { !belongsToCaller($0.key) }
    }

    /// For composing a tile's own environment, which is where tile-scoped keys get their
    /// values and so the one place they stay.
    public static func removingAgentIdentity(from environment: [String: String]) -> [String: String] {
        environment.filter { !isAgentIdentity($0.key) }
    }

    /// The pane a process was started from. Only a process that outlives that pane has any
    /// reason to drop these: a child of `ws open` really is in the caller's pane. The app's
    /// shells would inherit a claim to be inside tmux while sitting in a bare terminal, and
    /// the guard that keeps a launch repair from nesting tmux reads exactly that claim.
    static let callerPaneKeys: Set<String> = ["TMUX", "TMUX_PANE"]

    /// Clears the caller's identity from this process, for a process that carries it for
    /// its whole run. The app needs this rather than a filtered dictionary because the
    /// terminal library's children inherit the app's environment directly, beneath the
    /// per-surface variables it is handed. Run it during startup, before work fans out
    /// to other threads: `unsetenv` is not safe against a concurrent `getenv`.
    ///
    /// Returns the names removed, so the caller can log what it found: an app launched
    /// from inside an agent session is otherwise invisible.
    @discardableResult
    public static func removeCallerIdentityFromProcess(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let removed = environment.keys.filter { belongsToCaller($0) || callerPaneKeys.contains($0) }.sorted()
        for key in removed {
            unsetenv(key)
        }
        return removed
    }
}
