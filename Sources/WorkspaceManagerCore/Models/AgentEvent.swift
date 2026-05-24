import Foundation

/// Agent event normalized from an input channel (HTTP hook, status line, OSC notification,
/// or transcript reader). The registry consumes only this type.
///
/// New cases must be additive — never rename or repurpose without a migration.
public enum AgentEvent: Sendable {
    case sessionStart(agentSessionID: String, cwd: String, kind: AgentKind)
    case userPrompt(prompt: String?)
    case toolStart(name: String, detail: String?)
    case toolEnd(name: String, durationMS: Int?)
    case toolBatchEnd(toolCount: Int)
    case toolFailed(name: String, error: String?)
    case awaitingInput(reason: AwaitingReason, title: String?, message: String?)
    case stopped(error: String?)
    case errored(category: AgentErrorCategory, message: String?)
    case statusFields(StatusFields)
    case workingDirectory(String)
    case bell

    public struct StatusFields: Sendable, Equatable {
        public var modelDisplayName: String?
        public var contextUsedPercent: Double?
        public var fiveHourLimitUsedPercent: Double?
        public var fiveHourLimitResetsAt: Date?
        public var costUSD: Double?

        public init(
            modelDisplayName: String? = nil,
            contextUsedPercent: Double? = nil,
            fiveHourLimitUsedPercent: Double? = nil,
            fiveHourLimitResetsAt: Date? = nil,
            costUSD: Double? = nil
        ) {
            self.modelDisplayName = modelDisplayName
            self.contextUsedPercent = contextUsedPercent
            self.fiveHourLimitUsedPercent = fiveHourLimitUsedPercent
            self.fiveHourLimitResetsAt = fiveHourLimitResetsAt
            self.costUSD = costUSD
        }
    }
}

/// Where an event came from. Used for dedup and provenance display.
public enum AgentEventOrigin: Sendable, Equatable {
    case hook
    case osc(surfaceID: UInt64?)
    case statusLine
    case transcript
    case bell
}
