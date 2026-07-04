//
//  GhosttyTerminalConfigTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

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

    @Test("tmux mode runs an initial command as the session's process under the login shell")
    func tmuxModeRunsInitialCommand() throws {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true,
            initialCommand: "claude --resume sess-123"
        )

        let command = try #require(config.command)
        // Login shell wraps the tmux invocation → the tmux session inherits the login PATH,
        // so `claude` resolves (the whole point of the #783 fix vs the fixed-PATH path).
        #expect(command.contains("/bin/zsh --login -c "))
        #expect(command.contains("tmux -L workspaces new-session -A -s"))
        #expect(command.contains("claude --resume sess-123"))
    }

    @Test("ghostty-splits mode runs an initial command via cd + exec in the login shell")
    func ghosttyModeRunsInitialCommand() throws {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true,
            initialCommand: "claude --resume sess-123"
        )

        let command = try #require(config.command)
        #expect(command.contains("/bin/zsh --login -c "))
        #expect(command.contains("exec claude --resume sess-123"))
        #expect(command.contains("/tmp/repo-a"))
        #expect(!command.contains("tmux"))
    }

    @Test("A nil initial command leaves each mode's command unchanged")
    func nilInitialCommandIsNoOp() throws {
        let splits = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true,
            initialCommand: nil
        )
        #expect(splits.command == "/bin/zsh --login")  // identical to the reattach/fresh path

        let tmux = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true,
            initialCommand: nil
        )
        let tmuxCommand = try #require(tmux.command)
        #expect(!tmuxCommand.contains(" exec claude"))  // no trailing initial command
    }

    @Test("Single quotes in an initial command are escaped")
    func initialCommandQuotesEscaped() throws {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true,
            initialCommand: "echo x'y"
        )
        // The whole cd+exec is single-quoted, so an inner ' becomes '"'"'.
        let command = try #require(config.command)
        #expect(command.contains("x'\"'\"'y"))
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

    @Test("clean shell mode uses zsh without profile loading")
    func cleanShellModeUsesBareZsh() {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
                "WORKSPACES_SHELL_PROFILE_MODE": "clean",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true
        )

        #expect(config.command == "/bin/zsh -f")
        #expect(config.shellProfileModeLabel == "clean")
    }

    @Test("clean zsh diagnostics install prompt readiness marker")
    func cleanZshDiagnosticsInstallPromptReadinessMarker() throws {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
                "WORKSPACES_SHELL_PROFILE_MODE": "clean",
                "WORKSPACES_TERMINAL_DIAGNOSTICS": "1",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true
        )

        let prompt = try #require(config.environmentVariables["PROMPT"])
        #expect(config.command == "/bin/zsh -f")
        #expect(prompt.contains("\u{1B}]0;WorkSpaces Ready\u{7}"))
        #expect(prompt.hasPrefix("%{"))
    }

    @Test("clean shell mode uses bash without profile loading")
    func cleanShellModeUsesBareBash() {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/bash",
                "PATH": "/usr/bin:/bin",
                "WORKSPACES_SHELL_PROFILE_MODE": "clean",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true
        )

        #expect(config.command == "/bin/bash --noprofile --norc")
        #expect(config.shellProfileModeLabel == "clean")
    }

    @Test("clean bash diagnostics install prompt readiness marker")
    func cleanBashDiagnosticsInstallPromptReadinessMarker() throws {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/bash",
                "PATH": "/usr/bin:/bin",
                "WORKSPACES_SHELL_PROFILE_MODE": "clean",
                "WORKSPACES_TERMINAL_DIAGNOSTICS": "1",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true
        )

        let prompt = try #require(config.environmentVariables["PS1"])
        #expect(config.command == "/bin/bash --noprofile --norc")
        #expect(prompt.contains("\u{1B}]0;WorkSpaces Ready\u{7}"))
        #expect(prompt.hasPrefix("\\["))
    }

    @Test("host session hook context is exported when both values are available")
    func exportsHostSessionHookContext() {
        let hostSessionID = UUID(uuidString: "2D4D6044-1E11-49C9-9CB0-A1D7B9F44E31")!
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true,
            hostSessionID: hostSessionID,
            hooksSocketPath: "/tmp/workspaces-hooks.sock"
        )

        #expect(config.environmentVariables["WORKSPACES_HOST_SESSION_ID"] == hostSessionID.uuidString)
        #expect(config.environmentVariables["WORKSPACES_HOOKS_SOCKET"] == "/tmp/workspaces-hooks.sock")
        let commandStatusHook = config.environmentVariables["WORKSPACES_COMMAND_STATUS_ZSH"]
        #expect(commandStatusHook?.hasSuffix("command-status.zsh") == true)
        if let commandStatusHook {
            #expect(FileManager.default.fileExists(atPath: commandStatusHook))
        }
    }

    @Test("host session hook context is omitted unless complete")
    func omitsIncompleteHostSessionHookContext() {
        let hostSessionID = UUID(uuidString: "2D4D6044-1E11-49C9-9CB0-A1D7B9F44E31")!
        let missingSocket = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true,
            hostSessionID: hostSessionID
        )
        let missingHostID = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true,
            hooksSocketPath: "/tmp/workspaces-hooks.sock"
        )

        #expect(missingSocket.environmentVariables["WORKSPACES_HOST_SESSION_ID"] == nil)
        #expect(missingSocket.environmentVariables["WORKSPACES_HOOKS_SOCKET"] == nil)
        #expect(missingSocket.environmentVariables["WORKSPACES_COMMAND_STATUS_ZSH"] == nil)
        #expect(missingHostID.environmentVariables["WORKSPACES_HOST_SESSION_ID"] == nil)
        #expect(missingHostID.environmentVariables["WORKSPACES_HOOKS_SOCKET"] == nil)
        #expect(missingHostID.environmentVariables["WORKSPACES_COMMAND_STATUS_ZSH"] == nil)
    }

    @Test("Automation context exports only socket and opaque handle")
    func exportsAutomationContextOnly() {
        let hostSessionID = UUID(uuidString: "2D4D6044-1E11-49C9-9CB0-A1D7B9F44E31")!
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true,
            hostSessionID: hostSessionID,
            hooksSocketPath: "/tmp/workspaces-hooks.sock",
            automationEnvironment: AutomationTerminalEnvironment(
                socketPath: "/tmp/workspaces-automation.sock",
                handle: "opaque-handle"
            )
        )

        #expect(config.environmentVariables["WORKSPACES_AUTOMATION_SOCKET"] == "/tmp/workspaces-automation.sock")
        #expect(config.environmentVariables["WORKSPACES_AUTOMATION_HANDLE"] == "opaque-handle")
        #expect(config.environmentVariables["WORKSPACES_TILE_ID"] == nil)
        #expect(config.environmentVariables["WORKSPACES_SURFACE_ID"] == nil)
        #expect(config.environmentVariables["WORKSPACES_HOST_SESSION_ID"] == hostSessionID.uuidString)
    }

    @Test("custom command config preserves explicit command without hook environment")
    func customCommandConfigPreservesExplicitCommandWithoutHookEnvironment() {
        let config = GhosttyTerminalConfig(customCommand: "/usr/local/bin/lume ssh vm-123")

        #expect(config.command == "/usr/local/bin/lume ssh vm-123")
        #expect(config.shellProfileModeLabel == "custom")
        #expect(config.environmentVariables["WORKSPACES_HOST_SESSION_ID"] == nil)
        #expect(config.environmentVariables["WORKSPACES_HOOKS_SOCKET"] == nil)
        #expect(config.environmentVariables["WORKSPACES_COMMAND_STATUS_ZSH"] == nil)
    }

    @Test("tmux mode respects clean shell override")
    func tmuxModeRespectsCleanShellOverride() throws {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
                "WORKSPACES_SHELL_PROFILE_MODE": "clean",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true
        )

        let command = try #require(config.command)
        #expect(command.contains("/bin/zsh -f -c "))
        #expect(command.contains("tmux -L workspaces new-session -A -s"))
        #expect(config.shellProfileModeLabel == "clean")
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
