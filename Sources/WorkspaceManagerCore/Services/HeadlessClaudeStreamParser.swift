//
//  HeadlessClaudeStreamParser.swift
//  WorkspaceManagerCore
//
//  Line-by-line NDJSON parser for `claude -p --output-format stream-json --verbose
//  --include-partial-messages`. Mirrors the web-side parser at
//  `web/src/lib/agent-runtime/vercel-sandbox.ts:parseStreamJsonLine` so the host and
//  web agree on event semantics; this parser is richer because the host needs to
//  drive `AgentSessionRegistry`, while the web side only needs streaming text.
//
//  Forward-compatibility: unknown event shapes round-trip as `.unknown(raw:)` so
//  new claude releases never break the runner — the registry simply ignores them.
//

import Foundation

/// Normalized event from a `claude -p` stream. Cases are additive — never rename
/// or repurpose. Channels added later can attach optional fields via the
/// `.unknown(raw:)` escape hatch without breaking existing consumers.
public enum HeadlessClaudeEvent: Sendable, Equatable {
    /// First event in every stream. `tools` is the list of tool names the model
    /// was given access to (mirrors `--allowedTools` plus built-ins).
    case systemInit(model: String?, sessionID: String?, tools: [String])
    /// Streaming assistant text fragment (`text_delta`).
    case textDelta(String)
    /// Assistant initiated a tool call. `input` is opaque JSON encoded as a
    /// string so we don't pull `AnyCodable` into the event surface.
    case toolUse(name: String, inputJSON: String?)
    /// Tool returned. `content` is the tool result body (string or stringified
    /// JSON) — callers that care about structure can parse it.
    case toolResult(content: String?)
    /// API call retry surfaced by the CLI (rate limit / transient 5xx). The
    /// runner forwards these so the UI can show a "retrying…" affordance.
    case apiRetry(attempt: Int?, maxRetries: Int?, delayMS: Int?, errorCategory: String?)
    /// Terminal event with the final response and aggregate stats. The
    /// `sessionID` here is what we persist for `--resume`.
    case result(text: String?, totalCostUSD: Double?, durationMS: Int?, numTurns: Int?, sessionID: String?)
    /// Forward-compatibility escape hatch: any line we couldn't classify is
    /// surfaced verbatim so the caller can log it without losing data.
    case unknown(raw: String)
}

/// Stateful NDJSON parser. Feed bytes via ``feed(_:)`` as they arrive from
/// stdout; pump events via ``drainEvents()``. The parser tolerates partial
/// lines (no trailing `\n`) and resumes on the next chunk.
public struct HeadlessClaudeStreamParser: Sendable {
    private var buffer: String = ""

    public init() {}

    /// Append a chunk of stdout bytes. Returns the events parsed from any
    /// newline-terminated lines completed by this chunk.
    public mutating func feed(_ chunk: String) -> [HeadlessClaudeEvent] {
        buffer.append(chunk)
        return drainCompleteLines()
    }

    /// Flush any buffered content as a final line. Call after the process
    /// exits to surface a trailing line that lacked a `\n`.
    public mutating func flush() -> [HeadlessClaudeEvent] {
        guard !buffer.isEmpty else { return [] }
        let trailing = buffer
        buffer.removeAll(keepingCapacity: false)
        if let event = Self.parseLine(trailing) {
            return [event]
        }
        return []
    }

    private mutating func drainCompleteLines() -> [HeadlessClaudeEvent] {
        var events: [HeadlessClaudeEvent] = []
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            if let event = Self.parseLine(line) {
                events.append(event)
            }
        }
        return events
    }

    /// Pure helper. Returns `nil` for blank lines so callers don't need to
    /// filter; everything else round-trips through `.unknown(raw:)` if it
    /// can't be classified.
    public static func parseLine(_ rawLine: String) -> HeadlessClaudeEvent? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        guard let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .unknown(raw: trimmed)
        }

        let type = (object["type"] as? String) ?? ""

        switch type {
        case "system":
            // Per claude-code stream-json: { type: "system", subtype: "init",
            // model, session_id, tools: [...] }
            let subtype = (object["subtype"] as? String) ?? ""
            if subtype == "init" || subtype.isEmpty {
                let model = object["model"] as? String
                let sessionID =
                    (object["session_id"] as? String) ?? (object["sessionId"] as? String)
                let tools = (object["tools"] as? [String]) ?? []
                return .systemInit(model: model, sessionID: sessionID, tools: tools)
            }
            return .unknown(raw: trimmed)

        case "stream_event":
            return parseStreamEvent(object, raw: trimmed)

        case "assistant":
            // Some stream-json modes emit consolidated assistant messages
            // rather than deltas. Surface text content if present.
            return parseAssistantBlock(object, raw: trimmed)

        case "user":
            // Tool results are wrapped in user messages with a tool_result block.
            return parseUserBlock(object, raw: trimmed)

        case "result":
            let text = (object["result"] as? String) ?? (object["text"] as? String)
            let cost = object["total_cost_usd"] as? Double ?? object["totalCostUsd"] as? Double
            let duration =
                (object["duration_ms"] as? Int) ?? (object["durationMs"] as? Int)
            let numTurns =
                (object["num_turns"] as? Int) ?? (object["numTurns"] as? Int)
            let sessionID =
                (object["session_id"] as? String) ?? (object["sessionId"] as? String)
            return .result(
                text: text,
                totalCostUSD: cost,
                durationMS: duration,
                numTurns: numTurns,
                sessionID: sessionID
            )

        default:
            // Some lines are wrappers — try the inner heuristics anyway.
            if let stream = parseStreamEvent(object, raw: trimmed) { return stream }
            return .unknown(raw: trimmed)
        }
    }

    private static func parseStreamEvent(_ object: [String: Any], raw: String) -> HeadlessClaudeEvent? {
        // The stream_event envelope wraps an Anthropic API event in `event`.
        // The web parser keys off `event.delta.type == "text_delta"` and
        // `event.type == "content_block_start"` for tool starts; we mirror it
        // here and add api_error_retry for retry surfacing.
        guard let inner = object["event"] as? [String: Any] else { return nil }

        if let delta = inner["delta"] as? [String: Any],
            (delta["type"] as? String) == "text_delta",
            let text = delta["text"] as? String
        {
            return .textDelta(text)
        }

        if (inner["type"] as? String) == "content_block_start",
            let block = inner["content_block"] as? [String: Any],
            (block["type"] as? String) == "tool_use",
            let name = block["name"] as? String
        {
            let inputJSON = serialize(block["input"])
            return .toolUse(name: name, inputJSON: inputJSON)
        }

        // API retry events surface as `api_error_retry` in some stream-json
        // versions; the canonical Anthropic message is `error` with
        // `request_retry`. Both shapes funnel here.
        if let retryType = inner["type"] as? String,
            retryType.contains("retry") || retryType.contains("error")
        {
            let attempt = (inner["attempt"] as? Int) ?? (inner["retry_count"] as? Int)
            let maxRetries = (inner["max_retries"] as? Int) ?? (inner["maxRetries"] as? Int)
            let delayMS = (inner["delay_ms"] as? Int) ?? (inner["delayMs"] as? Int)
            let category = (inner["error_category"] as? String) ?? (inner["errorCategory"] as? String)
            return .apiRetry(
                attempt: attempt,
                maxRetries: maxRetries,
                delayMS: delayMS,
                errorCategory: category
            )
        }

        return nil
    }

    private static func parseAssistantBlock(_ object: [String: Any], raw: String) -> HeadlessClaudeEvent? {
        // Look for { message: { content: [{ type: "text", text: "..." }] } }
        // or { message: { content: [{ type: "tool_use", name, input }] } }.
        guard let message = object["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]],
            let first = content.first
        else {
            return .unknown(raw: raw)
        }
        if (first["type"] as? String) == "text", let text = first["text"] as? String {
            return .textDelta(text)
        }
        if (first["type"] as? String) == "tool_use", let name = first["name"] as? String {
            return .toolUse(name: name, inputJSON: serialize(first["input"]))
        }
        return .unknown(raw: raw)
    }

    private static func parseUserBlock(_ object: [String: Any], raw: String) -> HeadlessClaudeEvent? {
        guard let message = object["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]],
            let first = content.first,
            (first["type"] as? String) == "tool_result"
        else {
            return .unknown(raw: raw)
        }
        // tool_result.content is either a string or an array of blocks.
        if let contentString = first["content"] as? String {
            return .toolResult(content: contentString)
        }
        if let blocks = first["content"] as? [[String: Any]] {
            // Concatenate any text blocks; otherwise serialize.
            let joined = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return .toolResult(content: joined.isEmpty ? serialize(blocks) : joined)
        }
        return .toolResult(content: serialize(first["content"]))
    }

    private static func serialize(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let s = value as? String { return s }
        if JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value),
            let s = String(data: data, encoding: .utf8)
        {
            return s
        }
        return String(describing: value)
    }
}
