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
        AgentChromeProjection.runState(self).summaryText
    }
}
