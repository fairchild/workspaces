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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alphabetical:
            return "Alphabetical"
        case .lastAccessed:
            return "Last Accessed"
        }
    }
}

struct SidebarRepoSortController {
    func snapshot(for repos: [Repo]) -> [UUID: Date] {
        Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0.lastAccessedAt) })
    }

    func sortedRepos(
        _ repos: [Repo],
        mode: SidebarRepoSortMode,
        lastAccessedSnapshot: [UUID: Date]
    ) -> [Repo] {
        switch mode {
        case .alphabetical:
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
