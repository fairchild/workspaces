import Foundation

public enum AgentKind: String, Codable, Sendable {
    case claudeCode
    case opencode
    case aider
    case unknown
}

public enum AwaitingReason: String, Codable, Sendable {
    case permissionPrompt
    case idlePrompt
    case custom
}

public enum AgentErrorCategory: String, Codable, Sendable {
    case rateLimit
    case authentication
    case server
    case toolFailure
    case unknown
}

public enum AgentRunState: Sendable, Equatable {
    case idle
    case thinking
    case runningTool(name: String, detail: String?)
    case awaitingInput(reason: AwaitingReason)
    case complete
    case errored(category: AgentErrorCategory, message: String?)
}

public struct AgentSessionStatus: Sendable, Equatable {
    public let hostSessionID: UUID
    public var agentSessionID: String?
    public var kind: AgentKind
    public var cwd: String
    public var run: AgentRunState
    public var contextUsedPercent: Double?
    public var fiveHourLimitUsedPercent: Double?
    public var fiveHourLimitResetsAt: Date?
    public var costUSD: Double?
    public var modelDisplayName: String?
    public var lastEventAt: Date
    public var hookActive: Bool
    /// When the host session was first registered with the registry. Used by
    /// `resolveHostSession` to disambiguate multiple unbound entries with the same
    /// cwd (e.g. duplicate tabs or split panes on the same workspace) — newer
    /// entries win, matching the user's expectation that the most recently spawned
    /// terminal owns the next `SessionStart`.
    public var createdAt: Date

    public init(
        hostSessionID: UUID,
        agentSessionID: String? = nil,
        kind: AgentKind = .unknown,
        cwd: String,
        run: AgentRunState = .idle,
        contextUsedPercent: Double? = nil,
        fiveHourLimitUsedPercent: Double? = nil,
        fiveHourLimitResetsAt: Date? = nil,
        costUSD: Double? = nil,
        modelDisplayName: String? = nil,
        lastEventAt: Date = Date(),
        hookActive: Bool = false,
        createdAt: Date = Date()
    ) {
        self.hostSessionID = hostSessionID
        self.agentSessionID = agentSessionID
        self.kind = kind
        self.cwd = cwd
        self.run = run
        self.contextUsedPercent = contextUsedPercent
        self.fiveHourLimitUsedPercent = fiveHourLimitUsedPercent
        self.fiveHourLimitResetsAt = fiveHourLimitResetsAt
        self.costUSD = costUSD
        self.modelDisplayName = modelDisplayName
        self.lastEventAt = lastEventAt
        self.hookActive = hookActive
        self.createdAt = createdAt
    }
}
