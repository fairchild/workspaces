//
//  MainWindowOrderCache.swift
//  WorkspaceManager
//
//  Memoizes the orderings the main window builds inside `body`: the sidebar's Pinned section,
//  each repo's active and archived workspaces, each repo's and workspace's web sources, the
//  global Web section, the Recent buckets, and the repo landing page's two lists. #1354
//  memoized the repo ordering and left the rest as an inventory; this is that inventory
//  (#1366). Every one of them allocates a sorted array and most run ICU collation, while their
//  inputs change only when someone adds, renames, pins, archives, or opens something — these
//  views re-render far more often than that.
//

import Foundation
import WorkspaceManagerCore

/// One element's contribution to an ordering fingerprint.
///
/// `identity` rides alongside `id` for the reason review found in #1354: SwiftData can hand back
/// a replacement instance carrying identical values, and a cache keyed on values alone would go
/// on serving the superseded object. `date`, `name`, and `rank` are the fields the comparators
/// read; `stateCode` carries whatever else decides membership — a status, a pinned flag — so a
/// row leaving or joining a filtered section invalidates the ordering it left or joined.
struct MainWindowOrderSignature: Equatable {
    let id: UUID
    let identity: ObjectIdentifier
    let date: Date
    let name: String
    let rank: Int?
    let stateCode: Int

    init(
        id: UUID,
        identity: ObjectIdentifier,
        date: Date = .distantPast,
        name: String = "",
        rank: Int? = nil,
        stateCode: Int = 0
    ) {
        self.id = id
        self.identity = identity
        self.date = date
        self.name = name
        self.rank = rank
        self.stateCode = stateCode
    }
}

/// A memoized ordering, keyed by the container it belongs to (a repo id, a workspace id, or
/// `globalKey` for the sections that have no container).
///
/// Held in the sidebar's `@State` so the instance survives body evaluations without registering
/// observation, the same shape `SidebarRepoSortCache` and `PathNormalizationCache` use. Capacity
/// is bounded by clearing wholesale and re-missing rather than by eviction bookkeeping: the
/// keys are model ids, so the bound is only ever reached by a store far larger than a sidebar.
@MainActor
final class MainWindowOrderSlot<Value> {
    private static var capacity: Int { 512 }

    private var fingerprints: [UUID: [MainWindowOrderSignature]] = [:]
    private var values: [UUID: [Value]] = [:]

    /// How many times this slot has actually sorted. A memo whose hit rate is invisible is a memo
    /// nobody can prove works: every input is fingerprinted, so a hit and a miss return the same
    /// answer and no assertion over the *result* can tell them apart. Reading the count is what
    /// lets a test prove a hit, and lets one pin the caller-shape hazard that would defeat it.
    private(set) var buildCount = 0

    func ordered(
        key: UUID,
        fingerprint: [MainWindowOrderSignature],
        build: () -> [Value]
    ) -> [Value] {
        if fingerprints[key] == fingerprint, let cached = values[key] {
            return cached
        }
        buildCount += 1
        if fingerprints.count >= Self.capacity {
            fingerprints.removeAll(keepingCapacity: true)
            values.removeAll(keepingCapacity: true)
        }
        let built = build()
        fingerprints[key] = fingerprint
        values[key] = built
        return built
    }
}

/// The sidebar's orderings, each behind its own fingerprint.
@MainActor
final class MainWindowOrderCache {
    /// Stands in for a container id where the ordering has no container. A fresh UUID per cache
    /// instance rather than a literal: the slot it keys is private to this object, so it only
    /// has to be distinct from the model ids sharing the same slot, which it is by construction.
    private let globalKey = UUID()

    private let allWorkspaceSlot = MainWindowOrderSlot<Workspace>()
    private let activeWorkspaceSlot = MainWindowOrderSlot<Workspace>()
    private let archivedWorkspaceSlot = MainWindowOrderSlot<Workspace>()
    private let pinnedWorkspaceSlot = MainWindowOrderSlot<Workspace>()
    private let repoWebSourceSlot = MainWindowOrderSlot<WebSource>()
    private let workspaceWebSourceSlot = MainWindowOrderSlot<WebSource>()
    private let globalWebSourceSlot = MainWindowOrderSlot<WebSource>()
    private var recentFingerprint: [MainWindowOrderSignature]?
    private var recentTakenAt: Date?
    private var recentBuckets: [RecentBucket] = []
    private var recentBuildCount = 0

    /// How many orderings this cache has actually built, across every slot. See
    /// `MainWindowOrderSlot.buildCount` for why the count rather than the result is what a test
    /// has to read.
    var buildCount: Int {
        allWorkspaceSlot.buildCount + activeWorkspaceSlot.buildCount
            + archivedWorkspaceSlot.buildCount + pinnedWorkspaceSlot.buildCount
            + repoWebSourceSlot.buildCount + workspaceWebSourceSlot.buildCount
            + globalWebSourceSlot.buildCount + recentBuildCount
    }

    /// Every workspace of a repo, most recently accessed first — what the repo landing page
    /// lists, archived rows included.
    func workspaces(for repo: Repo) -> [Workspace] {
        allWorkspaceSlot.ordered(
            key: repo.id,
            fingerprint: Self.workspaceSignatures(repo.workspaces)
        ) {
            Self.byLastAccessed(repo.workspaces)
        }
    }

    /// A repo's non-archived workspaces, most recently accessed first.
    func activeWorkspaces(for repo: Repo) -> [Workspace] {
        activeWorkspaceSlot.ordered(
            key: repo.id,
            fingerprint: Self.workspaceSignatures(repo.workspaces)
        ) {
            Self.byLastAccessed(repo.workspaces).filter { $0.status != .archived }
        }
    }

    /// A repo's archived workspaces, most recently accessed first. Its own slot rather than a
    /// second filter over one cached sort: the sidebar asks for both on every expanded repo, and
    /// two cached arrays cost less than the one sort they replace.
    func archivedWorkspaces(for repo: Repo) -> [Workspace] {
        archivedWorkspaceSlot.ordered(
            key: repo.id,
            fingerprint: Self.workspaceSignatures(repo.workspaces)
        ) {
            Self.byLastAccessed(repo.workspaces).filter { $0.status == .archived }
        }
    }

    /// The Pinned section in display order. The sidebar reads this twice per evaluation — once
    /// for the rows, once to decide which header carries the inline actions — so the memo pays
    /// for itself before any coalescing window is considered.
    func pinnedWorkspaces(
        in workspaces: [Workspace],
        controller: SidebarPinController
    ) -> [Workspace] {
        pinnedWorkspaceSlot.ordered(
            key: globalKey,
            fingerprint: Self.pinSignatures(workspaces)
        ) {
            controller.pinnedWorkspaces(in: workspaces)
        }
    }

    func repoWebSources(for repo: Repo) -> [WebSource] {
        repoWebSourceSlot.ordered(
            key: repo.id,
            fingerprint: Self.webSourceSignatures(repo.webSources)
        ) {
            Self.byLastAccessed(repo.webSources)
        }
    }

    func workspaceWebSources(for workspace: Workspace) -> [WebSource] {
        workspaceWebSourceSlot.ordered(
            key: workspace.id,
            fingerprint: Self.webSourceSignatures(workspace.webSources)
        ) {
            Self.byLastAccessed(workspace.webSources)
        }
    }

    func globalWebSources(in sources: [WebSource]) -> [WebSource] {
        globalWebSourceSlot.ordered(
            key: globalKey,
            fingerprint: Self.webSourceSignatures(sources)
        ) {
            Self.byLastAccessed(sources.filter(\.isGlobal))
        }
    }

    /// The Recent arrangement's buckets. Its inputs are already snapshot-driven, so the
    /// fingerprint is the snapshot itself plus the pane counts that decide which repo roots
    /// appear — the arrangement reorders only when the sidebar deliberately re-takes them.
    ///
    /// `now` is compared exactly, which makes the memo only as good as the caller's `now`. The
    /// sidebar passes `recentSnapshotTakenAt`, `@State` re-taken solely by
    /// `syncRecentSnapshot(forceRefresh:)` — on mode change, on appear, when the repo or
    /// workspace set changes, and when the app resigns active, never during a redraw. A caller
    /// that passed a freshly constructed `Date()` per access would miss every time; that is what
    /// `MainWindowOrderCacheTests.freshInstantPerAccessDefeatsTheRecentMemo` pins, so the hazard
    /// fails a test rather than going quiet.
    func recentBuckets(
        repos: [Repo],
        snapshot: [UUID: Date],
        repoRootPaneCounts: [UUID: Int],
        now: Date,
        calendar: Calendar
    ) -> [RecentBucket] {
        let fingerprint = Self.recentSignatures(
            repos: repos,
            snapshot: snapshot,
            repoRootPaneCounts: repoRootPaneCounts
        )
        if fingerprint == recentFingerprint, now == recentTakenAt {
            return recentBuckets
        }
        recentBuildCount += 1
        recentBuckets = SidebarRecentArrangement.buckets(
            repos: repos,
            snapshot: snapshot,
            repoRootPaneCounts: repoRootPaneCounts,
            now: now,
            calendar: calendar
        )
        recentFingerprint = fingerprint
        recentTakenAt = now
        return recentBuckets
    }

    // MARK: - Fingerprints

    private static func workspaceSignatures(_ workspaces: [Workspace]) -> [MainWindowOrderSignature] {
        workspaces.map { workspace in
            MainWindowOrderSignature(
                id: workspace.id,
                identity: ObjectIdentifier(workspace),
                date: workspace.lastAccessedAt,
                stateCode: statusCode(workspace.status)
            )
        }
    }

    private static func pinSignatures(_ workspaces: [Workspace]) -> [MainWindowOrderSignature] {
        workspaces.map { workspace in
            MainWindowOrderSignature(
                id: workspace.id,
                identity: ObjectIdentifier(workspace),
                name: workspace.name,
                rank: workspace.pinOrder,
                stateCode: statusCode(workspace.status)
            )
        }
    }

    private static func webSourceSignatures(_ sources: [WebSource]) -> [MainWindowOrderSignature] {
        sources.map { source in
            MainWindowOrderSignature(
                id: source.id,
                identity: ObjectIdentifier(source),
                date: source.lastAccessedAt,
                stateCode: source.isGlobal ? 1 : 0
            )
        }
    }

    private static func recentSignatures(
        repos: [Repo],
        snapshot: [UUID: Date],
        repoRootPaneCounts: [UUID: Int]
    ) -> [MainWindowOrderSignature] {
        var signatures: [MainWindowOrderSignature] = []
        for repo in repos {
            signatures.append(
                MainWindowOrderSignature(
                    id: repo.id,
                    identity: ObjectIdentifier(repo),
                    date: snapshot[repo.id] ?? repo.lastAccessedAt,
                    name: repo.name,
                    rank: repoRootPaneCounts[repo.id, default: 0]
                )
            )
            for workspace in repo.workspaces {
                signatures.append(
                    MainWindowOrderSignature(
                        id: workspace.id,
                        identity: ObjectIdentifier(workspace),
                        date: snapshot[workspace.id] ?? workspace.lastAccessedAt,
                        name: workspace.name,
                        rank: workspace.pinOrder,
                        stateCode: statusCode(workspace.status)
                    )
                )
            }
        }
        return signatures
    }

    private static func statusCode(_ status: WorkspaceStatus) -> Int {
        switch status {
        case .active: return 0
        case .provisioning: return 1
        case .stopped: return 2
        case .archived: return 3
        }
    }

    private static func byLastAccessed(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    private static func byLastAccessed(_ sources: [WebSource]) -> [WebSource] {
        sources.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }
}
