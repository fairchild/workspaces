//
//  TerminalSessionLaunchContextTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@Suite("TerminalSessionLaunchContext")
struct TerminalSessionLaunchContextTests {
    @Test("Directory-backed host sessions expose hook environment")
    func directoryBackedHostSessionsExposeHookEnvironment() {
        let hostSessionID = UUID(uuidString: "7BD8C9BD-7F3B-456D-A9EC-16CDB2221339")!
        let session = HostTerminalSession(
            id: hostSessionID,
            key: .repoPath("/Users/test/repo"),
            directory: URL(fileURLWithPath: "/Users/test/repo")
        )

        let context = TerminalSessionLaunchContext.hostSession(
            session,
            hooksSocketPath: "/tmp/workspaces-hooks.sock"
        )
        let hookEnvironment = context.hookEnvironment(commandStatusHookPath: "/tmp/command-status.zsh")

        #expect(context.commandModeLabel == "directory")
        #expect(context.promptReadinessHostSessionID == hostSessionID)
        #expect(context.agentCommunication == .hookEnvironment)
        #expect(hookEnvironment["WORKSPACES_HOST_SESSION_ID"] == hostSessionID.uuidString)
        #expect(hookEnvironment["WORKSPACES_HOOKS_SOCKET"] == "/tmp/workspaces-hooks.sock")
        #expect(hookEnvironment["WORKSPACES_COMMAND_STATUS_ZSH"] == "/tmp/command-status.zsh")
    }

    @Test("Incomplete directory hook context falls back to terminal signals")
    func incompleteDirectoryHookContextFallsBackToTerminalSignals() {
        let hostSessionID = UUID(uuidString: "7BD8C9BD-7F3B-456D-A9EC-16CDB2221339")!
        let context = TerminalSessionLaunchContext.directoryBacked(
            workingDirectory: URL(fileURLWithPath: "/Users/test/repo"),
            hostSessionID: hostSessionID
        )

        #expect(context.agentCommunication == .terminalSignalsOnly(.incompleteHookContext))
        #expect(context.hookEnvironment(commandStatusHookPath: "/tmp/command-status.zsh").isEmpty)
    }

    @Test("Custom-command host sessions are terminal-signal only")
    func customCommandHostSessionsAreTerminalSignalOnly() {
        let hostSessionID = UUID(uuidString: "7BD8C9BD-7F3B-456D-A9EC-16CDB2221339")!
        let session = HostTerminalSession(
            id: hostSessionID,
            key: .backendSession(providerID: "lume", instanceID: "vm-123"),
            directory: URL(fileURLWithPath: "/tmp/workspaces/vm-123"),
            customCommand: "/usr/local/bin/lume ssh vm-123"
        )

        let context = TerminalSessionLaunchContext.hostSession(
            session,
            hooksSocketPath: "/tmp/workspaces-hooks.sock"
        )
        let config = GhosttyTerminalConfig(launchContext: context)

        #expect(context.commandModeLabel == "custom")
        #expect(context.promptReadinessHostSessionID == nil)
        #expect(context.agentCommunication == .terminalSignalsOnly(.customCommand))
        #expect(context.hookEnvironment(commandStatusHookPath: "/tmp/command-status.zsh").isEmpty)
        #expect(context.workingDirectory.path == "/tmp/workspaces/vm-123")
        #expect(config.command == "/usr/local/bin/lume ssh vm-123")
        #expect(config.shellProfileModeLabel == "custom")
        #expect(config.workingDirectory == FileManager.default.temporaryDirectory.path)
        #expect(config.environmentVariables["WORKSPACES_HOST_SESSION_ID"] == nil)
        #expect(config.environmentVariables["WORKSPACES_HOOKS_SOCKET"] == nil)
        #expect(config.environmentVariables["WORKSPACES_COMMAND_STATUS_ZSH"] == nil)
    }
}
