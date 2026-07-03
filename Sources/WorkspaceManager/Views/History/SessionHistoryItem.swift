//
//  SessionHistoryItem.swift
//  WorkspaceManager
//
//  Display model for the session history browser: a durable-session continuity
//  row projected into what the list needs (title, path, time, model, whether the
//  Claude transcript still exists), plus a pure day-grouping fold. The mapping is
//  a static function so it is unit-testable without a store.
//

import Foundation
import WorkspaceManagerCore

struct SessionHistoryItem: Identifiable, Equatable {
    let id: UUID  // hostSessionID
    let title: String
    let path: String
    let timestamp: Date
    let endedAt: Date?
    let modelDisplayName: String?
    let agentKind: String?
    let agentSessionID: String?
    let agentCwd: String?
    /// Non-nil when the Claude transcript still exists on disk — the same
    /// predicate as "resumable", carrying the URL for the detail view.
    let transcriptURL: URL?

    var isResumable: Bool { transcriptURL != nil }

    static func make(
        from row: TerminalSessionContinuityRow,
        resumability: ClaudeTranscriptResumability
    ) -> SessionHistoryItem {
        let path = row.targetPath ?? row.directoryPath
        let transcriptURL: URL? = {
            guard let agentSessionID = row.agentSessionID, let agentCwd = row.agentCwd else { return nil }
            return resumability.existingTranscriptURL(agentSessionID: agentSessionID, cwd: agentCwd)
        }()
        return SessionHistoryItem(
            id: row.hostSessionID,
            title: displayTitle(for: path),
            path: path,
            timestamp: row.lastSeenAt,
            endedAt: row.endedAt,
            modelDisplayName: row.agentModelDisplayName,
            agentKind: row.agentKind,
            agentSessionID: row.agentSessionID,
            agentCwd: row.agentCwd,
            transcriptURL: transcriptURL
        )
    }

    private static func displayTitle(for path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let last = (trimmed as NSString).lastPathComponent
        return last.isEmpty ? trimmed : last
    }
}

/// A day bucket of history items, newest day first, items within kept in input
/// order (the store already returns newest `last_seen_at` first).
struct SessionHistoryDaySection: Identifiable, Equatable {
    let id: Date  // start-of-day
    let items: [SessionHistoryItem]
}

enum SessionHistoryGrouping {
    /// Fold a newest-first item list into day sections. `calendar`/`now` are
    /// injectable so the fold is deterministic under test.
    static func byDay(
        _ items: [SessionHistoryItem],
        calendar: Calendar = .current
    ) -> [SessionHistoryDaySection] {
        var order: [Date] = []
        var buckets: [Date: [SessionHistoryItem]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item.timestamp)
            if buckets[day] == nil {
                order.append(day)
            }
            buckets[day, default: []].append(item)
        }
        return order.map { SessionHistoryDaySection(id: $0, items: buckets[$0] ?? []) }
    }
}
