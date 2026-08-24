//
//  SidebarRepoSortController.swift
//  WorkspaceManager
//
//  Stable sorting rules for the repository sidebar.
//

import Foundation
import WorkspaceManagerCore

enum SidebarRepoSortMode: String, CaseIterable, Identifiable {
    static let storageKey = "mainWindow.sidebarRepoSortMode"

    case alphabetical
    case lastAccessed
    /// Flat, date-bucketed list of workspaces and active repo roots
    /// (`SidebarRecentArrangement`) instead of the repo tree.
    case recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alphabetical:
            return "Alphabetical"
        case .lastAccessed:
            return "Last Accessed"
        case .recent:
            return "Recent"
        }
    }
}

struct SidebarRepoSortController {
    private var cachedSnapshot: [UUID: Date] = [:]
    private var lastRepoIDSet: Set<UUID> = []

    mutating func snapshot(for repos: [Repo]) -> [UUID: Date] {
        let repoIDs = Set(repos.map(\.id))
        if repoIDs != lastRepoIDSet {
            lastRepoIDSet = repoIDs
            cachedSnapshot = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0.lastAccessedAt) })
        } else {
            for repo in repos {
                cachedSnapshot[repo.id] = repo.lastAccessedAt
            }
        }
        return cachedSnapshot
    }

    func sortedRepos(
        _ repos: [Repo],
        mode: SidebarRepoSortMode,
        lastAccessedSnapshot: [UUID: Date]
    ) -> [Repo] {
        switch mode {
        case .alphabetical, .recent:
            return repos.sorted(by: compareAlphabetically)
        case .lastAccessed:
            return repos.sorted { lhs, rhs in
                let lhsDate = lastAccessedSnapshot[lhs.id] ?? .distantPast
                let rhsDate = lastAccessedSnapshot[rhs.id] ?? .distantPast

                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }

                return compareAlphabetically(lhs, rhs)
            }
        }
    }

    func prunedSnapshot(
        _ snapshot: [UUID: Date],
        validRepoIDs: Set<UUID>
    ) -> [UUID: Date] {
        snapshot.filter { validRepoIDs.contains($0.key) }
    }

    private func compareAlphabetically(_ lhs: Repo, _ rhs: Repo) -> Bool {
        let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        let pathComparison = lhs.localPath.localizedCaseInsensitiveCompare(rhs.localPath)
        if pathComparison != .orderedSame {
            return pathComparison == .orderedAscending
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// Memoizes the sidebar's repo ordering. Sorting uses localized ICU
/// comparisons, which must not run on every sidebar body evaluation — under
/// agent-event load the sidebar re-renders once per coalescing window, while
/// its ordering inputs change only when repos are added, renamed, re-accessed,
/// or the mode flips (#1347 B2). Held in the view's `@State` so the instance
/// survives body evaluations without registering observation.
@MainActor
final class SidebarRepoSortCache {
    private struct Fingerprint: Equatable {
        let mode: SidebarRepoSortMode
        let repoIDs: [UUID]
        let names: [String]
        let paths: [String]
        let snapshot: [UUID: Date]
    }

    private var fingerprint: Fingerprint?
    private var cachedOrder: [Repo] = []

    func sortedRepos(
        _ repos: [Repo],
        mode: SidebarRepoSortMode,
        lastAccessedSnapshot: [UUID: Date],
        controller: SidebarRepoSortController
    ) -> [Repo] {
        let next = Fingerprint(
            mode: mode,
            repoIDs: repos.map(\.id),
            names: repos.map(\.name),
            paths: repos.map(\.localPath),
            snapshot: mode == .lastAccessed ? lastAccessedSnapshot : [:]
        )
        if next == fingerprint { return cachedOrder }

        let sorted = controller.sortedRepos(
            repos,
            mode: mode,
            lastAccessedSnapshot: lastAccessedSnapshot
        )
        fingerprint = next
        cachedOrder = sorted
        return sorted
    }
}
