//
//  AgentDisplayText.swift
//  WorkspaceManagerCore
//
//  Pure, UI-free display strings for agent enums, needed by the Core session-card read model
//  (#680). SwiftUI presentation (symbol/tint) stays in the app layer.
//

import Foundation

extension AgentKind {
    /// Human-facing name, matching the agent notification copy.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .opencode: return "OpenCode"
        case .aider: return "Aider"
        case .unknown: return "Agent"
        }
    }
}

extension AwaitingReason {
    /// Short reason label shown when an agent is awaiting input.
    public var displayName: String {
        switch self {
        case .permissionPrompt: return "permission"
        case .idlePrompt: return "idle"
        case .custom: return "custom"
        }
    }
}
