//
//  SessionActivity.swift
//  WorkspaceManagerCore
//
//  The attention ladder a session/row sits on, derived from agent status. This is the
//  single Core encoding of that ladder — the sidebar's `SidebarSessionActivity` is a thin
//  SwiftUI styling wrapper (Color/icon) over this type, and the session-switcher read model
//  ranks by its `severity`. Pure and UI-free so both surfaces share one ordering (#680).
//

import Foundation

public enum SessionActivity: Equatable, Sendable {
    case inactive
    case live
    case active
    case thinking
    case runningTool
    case awaitingInput
    case errored(category: AgentErrorCategory)

    public init(hasLiveSession: Bool, isActiveSession: Bool) {
        if isActiveSession {
            self = .active
        } else if hasLiveSession {
            self = .live
        } else {
            self = .inactive
        }
    }

    /// Map an agent registry status to an activity. Returns `.inactive` when the host has no
    /// registered agent status.
    public static func from(_ status: AgentSessionStatus?) -> SessionActivity {
        guard let status else { return .inactive }
        switch status.run {
        case .idle:
            return .live
        case .thinking:
            return .thinking
        case .runningTool:
            return .runningTool
        case .awaitingInput:
            return .awaitingInput
        case .complete:
            return .live
        case .errored(let category, _):
            return .errored(category: category)
        }
    }

    public var isActive: Bool {
        self == .active
    }

    public var hasLiveSession: Bool {
        switch self {
        case .inactive: return false
        case .live, .active, .thinking, .runningTool, .awaitingInput, .errored:
            return true
        }
    }

    public var indicatorTone: AgentChromeProjection.Tone {
        switch self {
        case .inactive:
            return .hidden
        case .live:
            return .live
        case .active:
            return .active
        case .thinking, .runningTool:
            return .running
        case .awaitingInput:
            return .attention
        case .errored:
            return .critical
        }
    }

    public var accessibilityDescription: String {
        switch self {
        case .inactive:
            return "no live session"
        case .live:
            return "live session"
        case .active:
            return "active session"
        case .thinking:
            return AgentChromeProjection.runState(.thinking).accessibilityDescription
        case .runningTool:
            return AgentChromeProjection.runState(.runningTool(name: "", detail: nil)).accessibilityDescription
        case .awaitingInput:
            return AgentChromeProjection.runState(.awaitingInput(reason: .custom)).accessibilityDescription
        case .errored(let category):
            return AgentChromeProjection.runState(.errored(category: category, message: nil)).accessibilityDescription
        }
    }

    public static func showsPaneCountBadge(for paneCount: Int) -> Bool {
        paneCount > 1
    }

    /// Severity ranking used to merge a baseline (own-session) activity with a bubbled
    /// activity derived from child workspaces, and to order the session switcher. Higher wins.
    public var severity: Int {
        switch self {
        case .errored(let category):
            return AgentChromeProjection.runState(.errored(category: category, message: nil)).sidebarPriority
        case .awaitingInput:
            return AgentChromeProjection.runState(.awaitingInput(reason: .custom)).sidebarPriority
        case .runningTool:
            return AgentChromeProjection.runState(.runningTool(name: "", detail: nil)).sidebarPriority
        case .thinking:
            return AgentChromeProjection.runState(.thinking).sidebarPriority
        case .active: return 2
        case .live: return 1
        case .inactive: return 0
        }
    }

    /// Combine this activity with another, returning the more severe one. Ties prefer `self`
    /// so callers can pass the baseline first.
    public func mergedWithBubbled(_ other: SessionActivity) -> SessionActivity {
        other.severity > self.severity ? other : self
    }
}
