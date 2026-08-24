//
//  WorkspaceNote.swift
//  WorkspaceManagerCore
//
//  Normalization for a **Workspace Note** — the one short line about where a work
//  stream stands. Every writer (the sidebar affordance, the automation verb) goes
//  through here, so a note is a single line of bounded length wherever it came from
//  and the sidebar row never has to defend itself against a pasted paragraph.
//

import Foundation

public enum WorkspaceNote {
    /// Longest note kept. The sidebar renders one truncated line, so a longer note is
    /// storage nobody reads; a caller with more to say has the Workspace Journal.
    public static let maxLength = 120

    /// The stored form of `rawValue`: whitespace trimmed, interior newlines and tabs
    /// collapsed to single spaces, truncated with an ellipsis. Empty or
    /// whitespace-only input is `nil`, so clearing a note and never setting one are
    /// the same state rather than two.
    public static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let collapsed =
            rawValue
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength - 1)) + "…"
    }
}
