//
//  AgentKindPresentation.swift
//  WorkspaceManager
//
//  UI presentation for agent identity and run state: maps each AgentKind to an
//  SF Symbol + tint (the "favicon" shown in the workspace hover card) and turns a
//  run state into a short human summary line.
//

import SwiftUI
import WorkspaceManagerCore

extension AgentKind {
    /// Human-facing name, matching the agent notification copy.
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .opencode: return "OpenCode"
        case .aider: return "Aider"
        case .unknown: return "Agent"
        }
    }

    /// SF Symbol standing in for the agent's icon.
    var symbolName: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .aider: return "wand.and.rays"
        case .unknown: return "cpu"
        }
    }

    /// Tint applied to the agent symbol so kinds read apart at a glance.
    var tintColor: Color {
        switch self {
        case .claudeCode: return .orange
        case .opencode: return .blue
        case .aider: return .purple
        case .unknown: return .secondary
        }
    }
}

extension AgentRunState {
    /// One-line summary of what the agent is doing right now.
    var summaryText: String {
        switch self {
        case .idle:
            return "Idle"
        case .thinking:
            return "Thinking…"
        case .runningTool(let name, _):
            return "Running: \(name)"
        case .awaitingInput:
            return "Awaiting input"
        case .complete:
            return "Done"
        case .errored(let category, _):
            switch category {
            case .rateLimit: return "Rate limited"
            case .authentication: return "Auth error"
            case .server: return "Server error"
            case .toolFailure: return "Tool failed"
            case .unknown: return "Error"
            }
        }
    }
}
