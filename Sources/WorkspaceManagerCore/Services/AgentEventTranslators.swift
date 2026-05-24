import Foundation

/// Concrete translator for Claude Code's hook JSON. This is intentionally not a
/// protocol seam: there is one rich hook speaker today, so a protocol only pushes
/// knowledge about absent adapters into callers.
public enum ClaudeHookTranslator {
    public static func decodeAgentEvent(from raw: Data) throws -> AgentEvent? {
        let event = try ClaudeHookDecoder.decode(raw)
        return translate(event)
    }

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

/// Concrete mapper for OSC 9 / OSC 777 notifications and terminal bells. Claude
/// gets a small amount of body interpretation; other agents produce a generic
/// awaiting-input signal until they have a richer contract.
public enum AgentOSCEventMapper {
    public static func mapNotification(
        kind: AgentKind,
        title: String?,
        body: String
    ) -> AgentEvent {
        guard kind == .claudeCode else {
            return .awaitingInput(reason: .custom, title: title, message: body)
        }

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

    public static func mapBell(kind: AgentKind) -> AgentEvent {
        _ = kind
        return .bell
    }
}
