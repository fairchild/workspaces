//
//  SidebarRecentArrangement.swift
//  WorkspaceManager
//
//  Flattens repos and workspaces into date-bucketed rows for the sidebar's Recent
//  arrangement. Pure and snapshot-driven, so the list never reorders under the cursor.
//

import Foundation
import WorkspaceManagerCore

/// One row of the flat Recent list: a workspace, or a repo root that has open panes.
enum RecentRow: Identifiable {
    case workspace(Workspace)
    case repoRoot(Repo)

    var id: UUID {
        switch self {
        case .workspace(let workspace):
            return workspace.id
        case .repoRoot(let repo):
            return repo.id
        }
    }

    var name: String {
        switch self {
        case .workspace(let workspace):
            return workspace.name
        case .repoRoot(let repo):
            return repo.name
        }
    }
}

enum RecentBucketKind: String, CaseIterable {
    case today
    case thisWeek
    case earlier

    var title: String {
        switch self {
        case .today:
            return "Today"
        case .thisWeek:
            return "This Week"
        case .earlier:
            return "Earlier"
        }
    }
}

/// A rendered section of the Recent list: its header title and its ordered rows.
struct RecentBucket: Identifiable {
    let kind: RecentBucketKind
    let rows: [RecentRow]

    var id: String { kind.rawValue }
    var title: String { kind.title }
}

/// Builds the Recent arrangement from live models plus a date snapshot. Every
/// ordering decision reads the snapshot rather than the models, so rows hold their
/// place until the view deliberately refreshes it.
enum SidebarRecentArrangement {
    /// "This Week" is the six calendar days before today: a row seven days back is a
    /// full week old and reads as Earlier.
    private static let thisWeekDayRange = 1...6

    static func buckets(
        repos: [Repo],
        snapshot: [UUID: Date],
        repoRootPaneCounts: [UUID: Int],
        now: Date,
        calendar: Calendar
    ) -> [RecentBucket] {
        var entriesByKind: [RecentBucketKind: [Entry]] = [:]

        func add(_ row: RecentRow, at date: Date) {
            let kind = bucketKind(for: date, now: now, calendar: calendar)
            entriesByKind[kind, default: []].append(Entry(row: row, date: date))
        }

        for repo in repos {
            if repoRootPaneCounts[repo.id, default: 0] > 0 {
                add(.repoRoot(repo), at: snapshot[repo.id] ?? repo.lastAccessedAt)
            }
            for workspace in repo.workspaces where workspace.status != .archived {
                add(.workspace(workspace), at: snapshot[workspace.id] ?? workspace.lastAccessedAt)
            }
        }

        return RecentBucketKind.allCases.compactMap { kind in
            guard let entries = entriesByKind[kind], !entries.isEmpty else { return nil }
            return RecentBucket(kind: kind, rows: entries.sorted(by: isOrderedBefore).map(\.row))
        }
    }

    /// Which bucket a date belongs to, measured in calendar-local whole days so a
    /// 23:59 stamp is still today and a 00:01 stamp yesterday is already This Week.
    /// Dates ahead of `now` (the fixture seeder bumps one) count as today.
    static func bucketKind(for date: Date, now: Date, calendar: Calendar) -> RecentBucketKind {
        let days =
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: date),
                to: calendar.startOfDay(for: now)
            ).day ?? 0

        if days <= 0 {
            return .today
        }
        return thisWeekDayRange.contains(days) ? .thisWeek : .earlier
    }

    /// The `lastAccessedAt` of every repo and workspace, keyed by id. Workspaces the
    /// snapshot has not seen fall back to their live date rather than to the distant
    /// past, so a workspace created between refreshes still lands in Today.
    static func snapshot(for repos: [Repo]) -> [UUID: Date] {
        var snapshot: [UUID: Date] = [:]
        for repo in repos {
            snapshot[repo.id] = repo.lastAccessedAt
            for workspace in repo.workspaces {
                snapshot[workspace.id] = workspace.lastAccessedAt
            }
        }
        return snapshot
    }

    static func identifiers(in repos: [Repo]) -> Set<UUID> {
        var identifiers: Set<UUID> = []
        for repo in repos {
            identifiers.insert(repo.id)
            identifiers.formUnion(repo.workspaces.map(\.id))
        }
        return identifiers
    }

    static func prunedSnapshot(_ snapshot: [UUID: Date], validIDs: Set<UUID>) -> [UUID: Date] {
        snapshot.filter { validIDs.contains($0.key) }
    }

    private struct Entry {
        let row: RecentRow
        let date: Date
    }

    private static func isOrderedBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.date != rhs.date {
            return lhs.date > rhs.date
        }

        let nameComparison = lhs.row.name.localizedCaseInsensitiveCompare(rhs.row.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        return lhs.row.id.uuidString < rhs.row.id.uuidString
    }
}
