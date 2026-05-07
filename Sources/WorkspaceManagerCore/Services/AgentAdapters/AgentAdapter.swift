import Foundation

/// Per-agent adapter that maps raw input-channel data into the registry's `AgentEvent` shape.
/// Claude Code uses HTTP hooks for rich semantics; opencode/aider fall back to OSC + bell.
/// The UI never branches on `AgentKind` — it observes `AgentRunState` from the registry.
public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }

    /// Decode a hook payload received over the Unix socket. Adapters that don't speak the
    /// Claude Code hook schema return `nil`; the listener will then fall through to other
    /// channels for that session. Throwing means the payload was malformed and should be
    /// surfaced as a decoder error in logs.
    func decodeHookEvent(_ raw: Data) throws -> AgentEvent?

    /// Map an OSC 9 / OSC 777 notification surfaced by libghostty. All adapters must implement
    /// this — it is the universal fallback channel.
    func mapOSCNotification(title: String?, body: String) -> AgentEvent

    /// Map a BEL (`\a`) terminal bell. Adapters with no opinion can return `.bell`.
    func mapBell() -> AgentEvent
}

/// Default Claude Code adapter: rich hook semantics + OSC fallback + bell.
public struct ClaudeCodeAdapter: AgentAdapter {
    public let kind: AgentKind = .claudeCode

    public init() {}

    public func decodeHookEvent(_ raw: Data) throws -> AgentEvent? {
        let event = try ClaudeHookDecoder.decode(raw)
        return Self.translate(event)
    }

    public func mapOSCNotification(title: String?, body: String) -> AgentEvent {
        let lowered = body.lowercased()
        let titleLowered = title?.lowercased() ?? ""

        if lowered.contains("permission") || titleLowered.contains("permission") {
            return .awaitingInput(reason: .permissionPrompt, title: title, message: body)
        }
        if lowered.contains("waiting for your input") || lowered.contains("idle") {
            return .awaitingInput(reason: .idlePrompt, title: title, message: body)
        }
        return .awaitingInput(reason: .custom, title: title, message: body)
    }

    public func mapBell() -> AgentEvent { .bell }

    static func translate(_ event: ClaudeHookEvent) -> AgentEvent? {
        switch event {
        case .sessionStart(let e):
            return .sessionStart(
                agentSessionID: e.common.sessionID, cwd: e.common.cwd, kind: .claudeCode)

        case .userPromptSubmit(let e):
            return .userPrompt(prompt: e.prompt)

        case .preToolUse(let e):
            let detail = Self.extractDetail(toolName: e.toolName, toolInput: e.toolInput)
            return .toolStart(name: e.toolName, detail: detail)

        case .postToolUse(let e):
            return .toolEnd(name: e.toolName, durationMS: e.durationMS)

        case .postToolBatch(let e):
            return .toolBatchEnd(toolCount: e.toolCount)

        case .postToolUseFailure(let e):
            return .toolFailed(name: e.toolName, error: e.error)

        case .permissionRequest(let e):
            return .awaitingInput(
                reason: .permissionPrompt,
                title: "Permission requested",
                message: e.toolName.map { "Tool: \($0)" })

        case .notification(let e):
            switch e.notificationType {
            case "permission_prompt":
                return .awaitingInput(reason: .permissionPrompt, title: e.title, message: e.message)
            case "idle_prompt":
                return .awaitingInput(reason: .idlePrompt, title: e.title, message: e.message)
            case "auth_success":
                return nil  // informational
            default:
                return .awaitingInput(reason: .custom, title: e.title, message: e.message)
            }

        case .stop:
            return .stopped(error: nil)

        case .stopFailure(let e):
            return .errored(category: Self.categorize(e.error), message: e.error)

        case .worktreeCreate, .worktreeRemove, .taskCreated, .taskCompleted:
            // Channel #4 / sidebar surfaces handle these; PR #1 ignores.
            return nil

        case .unknown:
            return nil
        }
    }

    private static func extractDetail(
        toolName: String, toolInput: [String: AnyCodable]?
    ) -> String? {
        guard let toolInput else { return nil }
        // Common detail fields for the most-shown tools, no rich logic in PR #1.
        for key in ["file_path", "filePath", "path", "command", "url"] {
            if let any = toolInput[key], let s = any.value as? String, !s.isEmpty {
                return s
            }
        }
        return nil
    }

    private static func categorize(_ error: String?) -> AgentErrorCategory {
        guard let error = error?.lowercased() else { return .unknown }
        if error.contains("rate") && error.contains("limit") { return .rateLimit }
        if error.contains("auth") { return .authentication }
        if error.contains("server") || error.contains("5xx") { return .server }
        return .unknown
    }
}

/// Generic OSC-only adapter for agents (opencode, aider, etc.) that don't speak Claude Code's
/// hook schema. They get an `.awaitingInput` from any OSC notification — the UI shows the dot
/// in the awaiting-input state but no rich tool-name detail.
public struct GenericOSCAdapter: AgentAdapter {
    public let kind: AgentKind

    public init(kind: AgentKind = .unknown) {
        self.kind = kind
    }

    public func decodeHookEvent(_ raw: Data) throws -> AgentEvent? {
        nil  // not a Claude Code hook speaker
    }

    public func mapOSCNotification(title: String?, body: String) -> AgentEvent {
        .awaitingInput(reason: .custom, title: title, message: body)
    }

    public func mapBell() -> AgentEvent { .bell }
}

/// Looks up an adapter by detected kind. Adapters are stateless, so a single instance per kind
/// is fine.
public struct AgentAdapterRegistry: Sendable {
    private let adapters: [AgentKind: any AgentAdapter]

    public init(adapters: [any AgentAdapter] = AgentAdapterRegistry.defaults) {
        var byKind: [AgentKind: any AgentAdapter] = [:]
        for adapter in adapters {
            byKind[adapter.kind] = adapter
        }
        self.adapters = byKind
    }

    public func adapter(for kind: AgentKind) -> any AgentAdapter {
        adapters[kind] ?? GenericOSCAdapter(kind: kind)
    }

    public static var defaults: [any AgentAdapter] {
        [
            ClaudeCodeAdapter(),
            GenericOSCAdapter(kind: .opencode),
            GenericOSCAdapter(kind: .aider),
            GenericOSCAdapter(kind: .unknown),
        ]
    }
}
