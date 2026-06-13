//
//  TranscriptRecord.swift
//  WorkspaceManagerCore
//
//  Tolerant decoder for Claude Code transcript JSONL records.
//
//  Transcript JSONL reader. Transcripts live at
//  ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl. Hook payloads carry
//  `transcript_path`; we never derive the path. Schema is technically internal
//  and slow-moving — unknown record types decode to `.opaque(raw:)` and pass
//  through. Only canonical types get rich rendering.
//

import Foundation

/// One record from a Claude Code transcript JSONL file. Decoded from a single
/// line of the JSONL. New record types must be additive — never rename an
/// existing case. Anything unrecognised lands in `.opaque`.
public enum TranscriptRecord: Sendable, Equatable {
    case user(TranscriptUser)
    case assistant(TranscriptAssistant)
    case toolUse(TranscriptToolUse)
    case toolResult(TranscriptToolResult)
    case summary(TranscriptSummary)
    case opaque(rawType: String, rawJSON: Data)

    public struct TranscriptUser: Sendable, Equatable {
        public let uuid: String?
        public let timestamp: Date?
        public let text: String

        public init(uuid: String?, timestamp: Date?, text: String) {
            self.uuid = uuid
            self.timestamp = timestamp
            self.text = text
        }
    }

    public struct TranscriptAssistant: Sendable, Equatable {
        public let uuid: String?
        public let timestamp: Date?
        public let text: String
        public let model: String?

        public init(uuid: String?, timestamp: Date?, text: String, model: String?) {
            self.uuid = uuid
            self.timestamp = timestamp
            self.text = text
            self.model = model
        }
    }

    public struct TranscriptToolUse: Sendable, Equatable {
        public let uuid: String?
        public let timestamp: Date?
        public let toolName: String
        public let inputSummary: String?

        public init(uuid: String?, timestamp: Date?, toolName: String, inputSummary: String?) {
            self.uuid = uuid
            self.timestamp = timestamp
            self.toolName = toolName
            self.inputSummary = inputSummary
        }
    }

    public struct TranscriptToolResult: Sendable, Equatable {
        public let uuid: String?
        public let timestamp: Date?
        public let toolName: String?
        public let durationMS: Int?
        public let isError: Bool
        public let outputSummary: String?

        public init(
            uuid: String?,
            timestamp: Date?,
            toolName: String?,
            durationMS: Int?,
            isError: Bool,
            outputSummary: String?
        ) {
            self.uuid = uuid
            self.timestamp = timestamp
            self.toolName = toolName
            self.durationMS = durationMS
            self.isError = isError
            self.outputSummary = outputSummary
        }
    }

    public struct TranscriptSummary: Sendable, Equatable {
        public let uuid: String?
        public let timestamp: Date?
        public let summary: String

        public init(uuid: String?, timestamp: Date?, summary: String) {
            self.uuid = uuid
            self.timestamp = timestamp
            self.summary = summary
        }
    }

    public var rawTypeName: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .toolUse: return "tool_use"
        case .toolResult: return "tool_result"
        case .summary: return "summary"
        case .opaque(let name, _): return name
        }
    }

    public var timestamp: Date? {
        switch self {
        case .user(let u): return u.timestamp
        case .assistant(let a): return a.timestamp
        case .toolUse(let t): return t.timestamp
        case .toolResult(let r): return r.timestamp
        case .summary(let s): return s.timestamp
        case .opaque: return nil
        }
    }
}

/// Tolerant single-line decoder. Errors decode-attempts return `.opaque`; only
/// outright invalid JSON or empty lines return nil.
public enum TranscriptDecoder {
    public static func decode(line: Data) -> TranscriptRecord? {
        guard !line.isEmpty,
            let raw = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else {
            return nil
        }

        let typeName = (raw["type"] as? String) ?? "unknown"
        let uuid = raw["uuid"] as? String
        let timestamp = parseTimestamp(raw["timestamp"])

        switch typeName {
        case "user":
            return .user(
                .init(uuid: uuid, timestamp: timestamp, text: extractText(raw))
            )

        case "assistant":
            let model =
                (raw["model"] as? String)
                ?? ((raw["message"] as? [String: Any])?["model"] as? String)
            return .assistant(
                .init(uuid: uuid, timestamp: timestamp, text: extractText(raw), model: model)
            )

        case "tool_use":
            let toolName =
                (raw["tool_name"] as? String)
                ?? (raw["name"] as? String)
                ?? "tool"
            let inputSummary = extractInputSummary(raw)
            return .toolUse(
                .init(
                    uuid: uuid,
                    timestamp: timestamp,
                    toolName: toolName,
                    inputSummary: inputSummary
                )
            )

        case "tool_result":
            let toolName =
                (raw["tool_name"] as? String)
                ?? (raw["name"] as? String)
            let durationMS = (raw["duration_ms"] as? Int) ?? (raw["durationMS"] as? Int)
            let isError = (raw["is_error"] as? Bool) ?? (raw["isError"] as? Bool) ?? false
            return .toolResult(
                .init(
                    uuid: uuid,
                    timestamp: timestamp,
                    toolName: toolName,
                    durationMS: durationMS,
                    isError: isError,
                    outputSummary: extractText(raw)
                )
            )

        case "summary":
            let summary =
                (raw["summary"] as? String)
                ?? (raw["text"] as? String)
                ?? ""
            return .summary(.init(uuid: uuid, timestamp: timestamp, summary: summary))

        default:
            return .opaque(rawType: typeName, rawJSON: line)
        }
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let s = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = formatter.date(from: s) { return d }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: s)
        }
        if let n = value as? Double { return Date(timeIntervalSince1970: n) }
        if let n = value as? Int { return Date(timeIntervalSince1970: TimeInterval(n)) }
        return nil
    }

    private static func extractText(_ raw: [String: Any]) -> String {
        if let s = raw["text"] as? String { return s }
        if let s = raw["content"] as? String { return s }
        if let message = raw["message"] as? [String: Any] {
            if let s = message["content"] as? String { return s }
            if let parts = message["content"] as? [[String: Any]] {
                let texts = parts.compactMap { $0["text"] as? String }
                if !texts.isEmpty { return texts.joined(separator: "\n") }
            }
        }
        return ""
    }

    private static func extractInputSummary(_ raw: [String: Any]) -> String? {
        if let s = raw["input_summary"] as? String { return s }
        if let input = raw["input"] as? [String: Any] {
            if let cmd = input["command"] as? String { return cmd }
            if let path = input["file_path"] as? String { return path }
            if let path = input["path"] as? String { return path }
        }
        return nil
    }
}
