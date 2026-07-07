import Foundation

/// Presentation policy for projecting Agent Run State into WorkSpaces chrome.
/// Callers get labels, semantic tone, sidebar priority, attention, and notification
/// policy from one Module instead of re-encoding Run State in each surface.
public struct AgentChromeProjection: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        case hidden
        case live
        case active
        case neutral
        case running
        case attention
        case critical
    }

    public let diagnosticsLabel: String
    public let summaryText: String
    public let accessibilityDescription: String
    public let commandPaletteDescriptor: String?
    public let tone: Tone
    public let sidebarPriority: Int
    public let demandsAttention: Bool

    public static let attentionTone: Tone = .attention

    public static func runState(_ state: AgentRunState) -> AgentChromeProjection {
        switch state {
        case .idle:
            return AgentChromeProjection(
                diagnosticsLabel: "Idle",
                summaryText: "Idle",
                accessibilityDescription: "agent idle",
                commandPaletteDescriptor: nil,
                tone: .neutral,
                sidebarPriority: 1,
                demandsAttention: false
            )
        case .thinking:
            return AgentChromeProjection(
                diagnosticsLabel: "Thinking",
                summaryText: "Thinking…",
                accessibilityDescription: "agent thinking",
                commandPaletteDescriptor: "thinking",
                tone: .running,
                sidebarPriority: 3,
                demandsAttention: false
            )
        case .runningTool(let name, _):
            return AgentChromeProjection(
                diagnosticsLabel: "Running \(name)",
                summaryText: "Running: \(name)",
                accessibilityDescription: "agent running tool",
                commandPaletteDescriptor: "running tool",
                tone: .running,
                sidebarPriority: 3,
                demandsAttention: false
            )
        case .awaitingInput(let reason):
            return AgentChromeProjection(
                diagnosticsLabel: "Awaiting \(reason.rawValue)",
                summaryText: "Awaiting input",
                accessibilityDescription: "agent awaiting input",
                commandPaletteDescriptor: "awaiting input",
                tone: .attention,
                sidebarPriority: 4,
                demandsAttention: true
            )
        case .complete:
            return AgentChromeProjection(
                diagnosticsLabel: "Complete",
                summaryText: "Done",
                accessibilityDescription: "agent complete",
                commandPaletteDescriptor: nil,
                tone: .neutral,
                sidebarPriority: 1,
                demandsAttention: false
            )
        case .errored(let category, _):
            return AgentChromeProjection(
                diagnosticsLabel: "Errored: \(category.rawValue)",
                summaryText: errorSummary(for: category),
                accessibilityDescription: "agent errored (\(category.rawValue))",
                commandPaletteDescriptor: "errored",
                tone: .critical,
                sidebarPriority: 5,
                demandsAttention: true
            )
        }
    }

    public static func demandsAttention(_ state: AgentRunState) -> Bool {
        runState(state).demandsAttention
    }

    public static func shouldPostPermissionPromptNotification(
        previous: AgentRunState?,
        current: AgentRunState
    ) -> Bool {
        guard case .awaitingInput(.permissionPrompt) = current else { return false }
        return previous != current
    }

    public static func attentionTooltipFallback(count: Int) -> String {
        "\(count) sessions awaiting input or errored"
    }

    private static func errorSummary(for category: AgentErrorCategory) -> String {
        switch category {
        case .rateLimit: return "Rate limited"
        case .authentication: return "Auth error"
        case .server: return "Server error"
        case .toolFailure: return "Tool failed"
        case .unknown: return "Error"
        }
    }
}
