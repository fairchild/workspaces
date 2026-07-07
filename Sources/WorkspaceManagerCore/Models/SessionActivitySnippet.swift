//
//  SessionActivitySnippet.swift
//  WorkspaceManagerCore
//
//  The latest-activity line shown on a session card, formatted purely from an agent's
//  run state (#680). Surfaces the states worth glancing at — a running tool and its
//  detail, a per-reason "awaiting input", an error — and stays silent for idle/complete
//  so the card carries no filler. UI-free and unit-tested; the switcher row feeds it into
//  its existing preview slot and falls back to a neutral descriptor when this is nil.
//

import Foundation

public enum SessionActivitySnippet {
    /// Default single-line character budget for a card snippet.
    public static let defaultMaxLength = 120

    /// A one-line activity snippet for `run`, or `nil` when the state warrants no line
    /// (idle/complete). Output is always collapsed to a single line and truncated.
    public static func text(for run: AgentRunState, maxLength: Int = defaultMaxLength) -> String? {
        switch run {
        case .idle, .complete:
            return nil
        case .thinking:
            return "Thinking…"
        case .runningTool(let name, let detail):
            let base = "Running \(name)"
            if let detail = detail?.singleLineTruncated(maxLength: maxLength), !detail.isEmpty {
                return "\(base): \(detail)".singleLineTruncated(maxLength: maxLength)
            }
            return base.singleLineTruncated(maxLength: maxLength)
        case .awaitingInput(let reason):
            return awaitingPhrase(reason)
        case .errored(let category, let message):
            if let message = message?.singleLineTruncated(maxLength: maxLength), !message.isEmpty {
                return message
            }
            // Reuse the one error-category vocabulary ("Rate limited", "Auth error", …).
            return AgentChromeProjection.runState(.errored(category: category, message: nil)).summaryText
        }
    }

    private static func awaitingPhrase(_ reason: AwaitingReason) -> String {
        switch reason {
        case .permissionPrompt: return "Waiting for permission"
        case .idlePrompt: return "Waiting for your reply"
        case .custom: return "Awaiting input"
        }
    }
}

extension String {
    /// Collapse all whitespace (including newlines) to single spaces, trim, and truncate to
    /// `maxLength` with a trailing ellipsis. Returns an empty string when nothing remains.
    func singleLineTruncated(maxLength: Int) -> String {
        let collapsed =
            split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: max(0, maxLength - 1))
        return String(collapsed[collapsed.startIndex..<end]) + "…"
    }
}
