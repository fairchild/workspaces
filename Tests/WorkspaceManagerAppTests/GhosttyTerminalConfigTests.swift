//
//  GhosttyTerminalConfigTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("GhosttyTerminalConfig")
struct GhosttyTerminalConfigTests {
    @Test("Ghostty mode uses plain login shell command")
    func ghosttyModeUsesLoginShell() {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true
        )

        #expect(config.command == "/bin/zsh --login")
    }

    @Test("tmux mode launches deterministic session attach-or-create command")
    func tmuxModeLaunchesAttachOrCreateCommand() throws {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true
        )

        let command = try #require(config.command)
        #expect(command.contains("/bin/zsh --login -c "))
        #expect(command.contains("tmux -L workspaces new-session -A -s"))
        #expect(command.contains("/tmp/repo-a"))
        #expect(command.contains("'wm-repo-a-"))
    }

    @Test("tmux mode falls back to login shell when tmux unavailable")
    func tmuxModeFallsBackWhenTmuxMissing() {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: false
        )

        #expect(config.command == "/bin/zsh --login")
    }

    @Test("tmux session identity is stable for a given path")
    func tmuxSessionIdentityIsStable() {
        let first = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true
        )

        let second = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true
        )

        let different = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-b"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true
        )

        #expect(first.command == second.command)
        #expect(first.command != different.command)
    }
}
