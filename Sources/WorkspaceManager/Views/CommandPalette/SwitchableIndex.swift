//
//  SwitchableIndex.swift
//  WorkspaceManager
//
//  Filtering + ranking for the command palette. Pure value semantics so it can
//  be tested without any UI.
//

import Foundation
import WorkspaceManagerCore

struct SwitchableIndex {
    /// Filter `items` by `query` and rank the matches.
    ///
    /// Ranking:
    ///   1. Title prefix matches (case-insensitive)
    ///   2. Title substring matches
    ///   3. Other matches (subtitle, branch, etc.)
    ///
    /// Within each tier, items are sorted by `sortKey` descending.
    static func rank<Item: SwitchableItem>(
        _ items: [Item],
        query: String,
        limit: Int = 50
    ) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(items.sorted { $0.sortKey > $1.sortKey }.prefix(limit))
        }

        let scored: [(item: Item, tier: Int)] = items.compactMap { item in
            guard item.matches(trimmed) else { return nil }
            let lowercaseTitle = item.title.lowercased()
            let lowercaseQuery = trimmed.lowercased()
            if lowercaseTitle.hasPrefix(lowercaseQuery) {
                return (item, 0)
            } else if lowercaseTitle.contains(lowercaseQuery) {
                return (item, 1)
            } else {
                return (item, 2)
            }
        }

        let sorted = scored.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            return lhs.item.sortKey > rhs.item.sortKey
        }
        return Array(sorted.prefix(limit).map(\.item))
    }
}
