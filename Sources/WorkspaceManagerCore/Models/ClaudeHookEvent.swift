import Foundation

/// Hook event payloads emitted by Claude Code over the HTTP hook channel.
/// Schema reference: https://code.claude.com/docs/en/hooks
///
/// Forward-compatibility contract:
/// - Unknown event types decode to `.unknown(name:rawJSON:)`.
/// - Unknown fields on known events are ignored, never errored.
/// - Cases here are additive — never rename or repurpose an existing case.
public enum ClaudeHookEvent: Sendable {
    case sessionStart(SessionStart)
    case userPromptSubmit(UserPromptSubmit)
    case preToolUse(PreToolUse)
    case postToolUse(PostToolUse)
    case postToolBatch(PostToolBatch)
    case postToolUseFailure(PostToolUseFailure)
    case permissionRequest(PermissionRequest)
    case notification(Notification)
    case stop(Stop)
    case stopFailure(StopFailure)
    case worktreeCreate(WorktreeCreate)
    case worktreeRemove(WorktreeRemove)
    case taskCreated(TaskCreated)
    case taskCompleted(TaskCompleted)
    case unknown(name: String, rawJSON: Data)

    public struct Common: Sendable {
        public let sessionID: String
        public let cwd: String
        public let transcriptPath: String?
        public init(sessionID: String, cwd: String, transcriptPath: String? = nil) {
            self.sessionID = sessionID
            self.cwd = cwd
            self.transcriptPath = transcriptPath
        }
    }

    public struct SessionStart: Sendable {
        public let common: Common
        public init(common: Common) { self.common = common }
    }

    public struct UserPromptSubmit: Sendable {
        public let common: Common
        public let prompt: String?
        public init(common: Common, prompt: String?) {
            self.common = common
            self.prompt = prompt
        }
    }

    public struct PreToolUse: Sendable {
        public let common: Common
        public let toolName: String
        public let toolInput: [String: AnyCodable]?
        public init(common: Common, toolName: String, toolInput: [String: AnyCodable]?) {
            self.common = common
            self.toolName = toolName
            self.toolInput = toolInput
        }
    }

    public struct PostToolUse: Sendable {
        public let common: Common
        public let toolName: String
        public let durationMS: Int?
        public init(common: Common, toolName: String, durationMS: Int?) {
            self.common = common
            self.toolName = toolName
            self.durationMS = durationMS
        }
    }

    public struct PostToolBatch: Sendable {
        public let common: Common
        public let toolCount: Int
        public init(common: Common, toolCount: Int) {
            self.common = common
            self.toolCount = toolCount
        }
    }

    public struct PostToolUseFailure: Sendable {
        public let common: Common
        public let toolName: String
        public let error: String?
        public init(common: Common, toolName: String, error: String?) {
            self.common = common
            self.toolName = toolName
            self.error = error
        }
    }

    public struct PermissionRequest: Sendable {
        public let common: Common
        public let toolName: String?
        public init(common: Common, toolName: String?) {
            self.common = common
            self.toolName = toolName
        }
    }

    public struct Notification: Sendable {
        public let common: Common
        public let notificationType: String
        public let title: String?
        public let message: String?
        public init(common: Common, notificationType: String, title: String?, message: String?) {
            self.common = common
            self.notificationType = notificationType
            self.title = title
            self.message = message
        }
    }

    public struct Stop: Sendable {
        public let common: Common
        public init(common: Common) { self.common = common }
    }

    public struct StopFailure: Sendable {
        public let common: Common
        public let error: String?
        public init(common: Common, error: String?) {
            self.common = common
            self.error = error
        }
    }

    public struct WorktreeCreate: Sendable {
        public let common: Common
        public let worktreePath: String
        public init(common: Common, worktreePath: String) {
            self.common = common
            self.worktreePath = worktreePath
        }
    }

    public struct WorktreeRemove: Sendable {
        public let common: Common
        public let worktreePath: String
        public init(common: Common, worktreePath: String) {
            self.common = common
            self.worktreePath = worktreePath
        }
    }

    public struct TaskCreated: Sendable {
        public let common: Common
        public let taskID: String
        public let title: String?
        public init(common: Common, taskID: String, title: String?) {
            self.common = common
            self.taskID = taskID
            self.title = title
        }
    }

    public struct TaskCompleted: Sendable {
        public let common: Common
        public let taskID: String
        public init(common: Common, taskID: String) {
            self.common = common
            self.taskID = taskID
        }
    }

    public var common: Common? {
        switch self {
        case .sessionStart(let e): return e.common
        case .userPromptSubmit(let e): return e.common
        case .preToolUse(let e): return e.common
        case .postToolUse(let e): return e.common
        case .postToolBatch(let e): return e.common
        case .postToolUseFailure(let e): return e.common
        case .permissionRequest(let e): return e.common
        case .notification(let e): return e.common
        case .stop(let e): return e.common
        case .stopFailure(let e): return e.common
        case .worktreeCreate(let e): return e.common
        case .worktreeRemove(let e): return e.common
        case .taskCreated(let e): return e.common
        case .taskCompleted(let e): return e.common
        case .unknown: return nil
        }
    }

    public var name: String {
        switch self {
        case .sessionStart: return "SessionStart"
        case .userPromptSubmit: return "UserPromptSubmit"
        case .preToolUse: return "PreToolUse"
        case .postToolUse: return "PostToolUse"
        case .postToolBatch: return "PostToolBatch"
        case .postToolUseFailure: return "PostToolUseFailure"
        case .permissionRequest: return "PermissionRequest"
        case .notification: return "Notification"
        case .stop: return "Stop"
        case .stopFailure: return "StopFailure"
        case .worktreeCreate: return "WorktreeCreate"
        case .worktreeRemove: return "WorktreeRemove"
        case .taskCreated: return "TaskCreated"
        case .taskCompleted: return "TaskCompleted"
        case .unknown(let name, _): return name
        }
    }
}

public enum ClaudeHookDecoder {
    public enum DecodeError: Error, Sendable {
        case missingHookEventName
        case missingCommonField(String)
        case invalidJSON
    }

    public static func decode(_ data: Data) throws -> ClaudeHookEvent {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.invalidJSON
        }

        let name =
            (raw["hook_event_name"] as? String)
            ?? (raw["hookEventName"] as? String)
            ?? (raw["event"] as? String)

        guard let name else { throw DecodeError.missingHookEventName }

        let common = try decodeCommon(raw: raw)

        switch name {
        case "SessionStart":
            return .sessionStart(.init(common: common))

        case "UserPromptSubmit":
            return .userPromptSubmit(.init(common: common, prompt: raw["prompt"] as? String))

        case "PreToolUse":
            let toolName = (raw["tool_name"] as? String) ?? (raw["toolName"] as? String) ?? ""
            let toolInput = (raw["tool_input"] as? [String: Any]) ?? (raw["toolInput"] as? [String: Any])
            return .preToolUse(
                .init(
                    common: common,
                    toolName: toolName,
                    toolInput: toolInput.map { Self.codableMap($0) }
                ))

        case "PostToolUse":
            let toolName = (raw["tool_name"] as? String) ?? (raw["toolName"] as? String) ?? ""
            let durationMS = (raw["duration_ms"] as? Int) ?? (raw["durationMS"] as? Int)
            return .postToolUse(.init(common: common, toolName: toolName, durationMS: durationMS))

        case "PostToolBatch":
            let toolCount = (raw["tool_count"] as? Int) ?? (raw["toolCount"] as? Int) ?? 0
            return .postToolBatch(.init(common: common, toolCount: toolCount))

        case "PostToolUseFailure":
            let toolName = (raw["tool_name"] as? String) ?? (raw["toolName"] as? String) ?? ""
            let error = raw["error"] as? String
            return .postToolUseFailure(.init(common: common, toolName: toolName, error: error))

        case "PermissionRequest":
            let toolName = (raw["tool_name"] as? String) ?? (raw["toolName"] as? String)
            return .permissionRequest(.init(common: common, toolName: toolName))

        case "Notification":
            let notificationType =
                (raw["notification_type"] as? String) ?? (raw["notificationType"] as? String) ?? ""
            return .notification(
                .init(
                    common: common,
                    notificationType: notificationType,
                    title: raw["title"] as? String,
                    message: raw["message"] as? String
                ))

        case "Stop":
            return .stop(.init(common: common))

        case "StopFailure":
            return .stopFailure(.init(common: common, error: raw["error"] as? String))

        case "WorktreeCreate":
            let path = Self.worktreePath(in: raw)
            return .worktreeCreate(.init(common: common, worktreePath: path))

        case "WorktreeRemove":
            let path = Self.worktreePath(in: raw)
            return .worktreeRemove(.init(common: common, worktreePath: path))

        case "TaskCreated":
            let taskID = (raw["task_id"] as? String) ?? (raw["taskID"] as? String) ?? ""
            return .taskCreated(.init(common: common, taskID: taskID, title: raw["title"] as? String))

        case "TaskCompleted":
            let taskID = (raw["task_id"] as? String) ?? (raw["taskID"] as? String) ?? ""
            return .taskCompleted(.init(common: common, taskID: taskID))

        default:
            return .unknown(name: name, rawJSON: data)
        }
    }

    private static func decodeCommon(raw: [String: Any]) throws -> ClaudeHookEvent.Common {
        let sessionID =
            (raw["session_id"] as? String)
            ?? (raw["sessionId"] as? String)
            ?? (raw["sessionID"] as? String)

        let cwd =
            (raw["cwd"] as? String)
            ?? (raw["working_directory"] as? String)
            ?? (raw["workingDirectory"] as? String)

        guard let sessionID else { throw DecodeError.missingCommonField("session_id") }
        guard let cwd else { throw DecodeError.missingCommonField("cwd") }

        let transcriptPath =
            (raw["transcript_path"] as? String) ?? (raw["transcriptPath"] as? String)

        return ClaudeHookEvent.Common(
            sessionID: sessionID,
            cwd: cwd,
            transcriptPath: transcriptPath
        )
    }

    private static func worktreePath(in raw: [String: Any]) -> String {
        if let path = raw["worktree_path"] as? String { return path }
        if let path = raw["worktreePath"] as? String { return path }
        if let hsi = raw["hookSpecificOutput"] as? [String: Any],
            let path = hsi["worktreePath"] as? String
        {
            return path
        }
        return ""
    }

    private static func codableMap(_ raw: [String: Any]) -> [String: AnyCodable] {
        var result: [String: AnyCodable] = [:]
        for (key, value) in raw {
            result[key] = AnyCodable(value)
        }
        return result
    }
}

/// Type-erased Codable container for forward-compatible decoding of arbitrary JSON values.
/// We don't carry rich semantics for `tool_input` payloads in PR #1 — adapters opt in to the
/// fields they care about. This keeps the contract additive.
public struct AnyCodable: @unchecked Sendable, Equatable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case (let l as String, let r as String): return l == r
        case (let l as Int, let r as Int): return l == r
        case (let l as Double, let r as Double): return l == r
        case (let l as Bool, let r as Bool): return l == r
        default: return false
        }
    }
}
