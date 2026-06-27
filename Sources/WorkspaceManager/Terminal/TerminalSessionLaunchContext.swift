//
//  TerminalSessionLaunchContext.swift
//  WorkspaceManager
//
//  Launch policy for one Terminal Session. It keeps command mode, working
//  directory, host-session identity, and Agent hook reachability together so
//  Ghostty surface creation has one place to ask what environment is safe.
//

import Foundation
import WorkspaceManagerCore

struct TerminalSessionLaunchContext: Equatable, Sendable {
    enum CommandMode: Equatable, Sendable {
        case directoryShell
        case customCommand(String)

        var label: String {
            switch self {
            case .directoryShell:
                return "directory"
            case .customCommand:
                return "custom"
            }
        }
    }

    enum AgentCommunication: Equatable, Sendable {
        case hookEnvironment
        case terminalSignalsOnly(TerminalSignalOnlyReason)
    }

    enum TerminalSignalOnlyReason: String, Equatable, Sendable {
        case customCommand
        case incompleteHookContext
    }

    let workingDirectory: URL
    let commandMode: CommandMode
    let hostSessionID: UUID?
    let hooksSocketPath: String?
    let automationEnvironment: AutomationTerminalEnvironment?

    static func hostSession(
        _ session: HostTerminalSession,
        hooksSocketPath: String?,
        automationEnvironment: AutomationTerminalEnvironment? = nil
    ) -> TerminalSessionLaunchContext {
        if let customCommand = session.customCommand {
            return TerminalSessionLaunchContext(
                workingDirectory: session.directoryURL,
                commandMode: .customCommand(customCommand),
                hostSessionID: session.id,
                hooksSocketPath: hooksSocketPath,
                automationEnvironment: nil
            )
        }

        return directoryBacked(
            workingDirectory: session.directoryURL,
            hostSessionID: session.id,
            hooksSocketPath: hooksSocketPath,
            automationEnvironment: automationEnvironment
        )
    }

    static func directoryBacked(
        workingDirectory: URL,
        hostSessionID: UUID? = nil,
        hooksSocketPath: String? = nil,
        automationEnvironment: AutomationTerminalEnvironment? = nil
    ) -> TerminalSessionLaunchContext {
        TerminalSessionLaunchContext(
            workingDirectory: workingDirectory,
            commandMode: .directoryShell,
            hostSessionID: hostSessionID,
            hooksSocketPath: hooksSocketPath,
            automationEnvironment: automationEnvironment
        )
    }

    static func customCommand(
        _ command: String,
        workingDirectory: URL = FileManager.default.temporaryDirectory,
        hostSessionID: UUID? = nil,
        hooksSocketPath: String? = nil,
        automationEnvironment: AutomationTerminalEnvironment? = nil
    ) -> TerminalSessionLaunchContext {
        _ = automationEnvironment
        return TerminalSessionLaunchContext(
            workingDirectory: workingDirectory,
            commandMode: .customCommand(command),
            hostSessionID: hostSessionID,
            hooksSocketPath: hooksSocketPath,
            automationEnvironment: nil
        )
    }

    var commandModeLabel: String {
        commandMode.label
    }

    var promptReadinessHostSessionID: UUID? {
        switch commandMode {
        case .directoryShell:
            return hostSessionID
        case .customCommand:
            return nil
        }
    }

    var agentCommunication: AgentCommunication {
        switch commandMode {
        case .customCommand:
            return .terminalSignalsOnly(.customCommand)
        case .directoryShell:
            guard hostSessionID != nil, hooksSocketPath != nil else {
                return .terminalSignalsOnly(.incompleteHookContext)
            }
            return .hookEnvironment
        }
    }

    func hookEnvironment(
        commandStatusHookPath: String? = ClaudeIntegrationLifecycle.bundledCommandStatusHookPath()
    ) -> [String: String] {
        guard case .hookEnvironment = agentCommunication,
            let hostSessionID,
            let hooksSocketPath
        else {
            return [:]
        }

        var environment = [
            "WORKSPACES_HOOKS_SOCKET": hooksSocketPath,
            "WORKSPACES_HOST_SESSION_ID": hostSessionID.uuidString,
        ]
        if let commandStatusHookPath {
            environment["WORKSPACES_COMMAND_STATUS_ZSH"] = commandStatusHookPath
        }
        return environment
    }
}
