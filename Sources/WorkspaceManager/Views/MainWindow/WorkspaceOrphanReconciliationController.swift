//
//  WorkspaceOrphanReconciliationController.swift
//  WorkspaceManager
//
//  Main-window bookkeeping for the workspace-leftover cleanup banner: which scanned
//  orphans are still visible, which are mid-cleanup, and what a confirmed cleanup does
//  for each orphan kind. Scanning and worktree removal live in `WorkspaceOrphanReconciler`;
//  this owns the view-facing state and the per-kind decision the main window acts on.
//

import Foundation
import SwiftData
import WorkspaceManagerCore

/// Banner and confirmation state for workspace-leftover cleanup, held in one `@State`.
///
/// Dismissal is recorded per item id rather than as a single "banner hidden" flag, so a
/// later scan that surfaces a leftover the user has not seen still shows the banner while
/// previously dismissed items stay quiet.
struct WorkspaceOrphanReconciliationState: Equatable {
    private(set) var items: [WorkspaceOrphanItem] = []
    private(set) var dismissedItemIDs: Set<String> = []
    private(set) var cleaningItemIDs: Set<String> = []
    private(set) var adoptingItemIDs: Set<String> = []

    /// The item awaiting destructive-action confirmation. Non-nil drives the alert.
    var pendingCleanup: WorkspaceOrphanItem?

    var visibleItems: [WorkspaceOrphanItem] {
        items.filter { !dismissedItemIDs.contains($0.id) }
    }

    func isCleaning(_ item: WorkspaceOrphanItem) -> Bool {
        cleaningItemIDs.contains(item.id)
    }

    func isAdopting(_ item: WorkspaceOrphanItem) -> Bool {
        adoptingItemIDs.contains(item.id)
    }

    /// Replaces the scanned set. Dismissals for items the scan no longer reports are
    /// dropped, so a leftover that is cleaned and later reappears is offered again.
    mutating func applyScanResult(_ scannedItems: [WorkspaceOrphanItem]) {
        items = scannedItems
        dismissedItemIDs.formIntersection(Set(scannedItems.map(\.id)))
    }

    mutating func dismissVisibleItems() {
        dismissedItemIDs.formUnion(visibleItems.map(\.id))
    }

    /// Marks an item as in-flight. Callers guard on `isCleaning(_:)` first so a repeat
    /// confirmation returns without writing state back at all.
    mutating func beginCleaning(_ item: WorkspaceOrphanItem) {
        cleaningItemIDs.insert(item.id)
    }

    mutating func endCleaning(_ item: WorkspaceOrphanItem) {
        cleaningItemIDs.remove(item.id)
    }

    /// Marks an item as in-flight for adoption. Callers guard on `isAdopting(_:)` first, the
    /// same non-reentrancy rule `beginCleaning` follows.
    mutating func beginAdopting(_ item: WorkspaceOrphanItem) {
        adoptingItemIDs.insert(item.id)
    }

    mutating func endAdopting(_ item: WorkspaceOrphanItem) {
        adoptingItemIDs.remove(item.id)
    }

    /// Drops an item that was cleaned or adopted successfully, ahead of the confirming rescan.
    mutating func removeCleanedItem(_ item: WorkspaceOrphanItem) {
        items.removeAll { $0.id == item.id }
        dismissedItemIDs.remove(item.id)
    }
}

/// Decisions and copy for workspace-leftover cleanup. Every member is a projection or a
/// scoped effect taking its dependencies as parameters, so the per-kind cleanup rule is
/// assertable without a window.
@MainActor
struct WorkspaceOrphanReconciliationController {
    /// One unit of destructive work in a confirmed cleanup, in execution order.
    enum CleanupStep: Equatable {
        case pruneGitWorktree
        case deleteWorkspaceRecord
        case deleteLumeVM
    }

    func repositorySnapshots(repos: [Repo]) -> [WorkspaceOrphanRepositorySnapshot] {
        repos.map { repo in
            WorkspaceOrphanRepositorySnapshot(
                id: repo.id,
                name: repo.name,
                localPath: repo.localPath,
                workspaces: repo.workspaces.map { workspace in
                    WorkspaceOrphanWorkspaceSnapshot(
                        id: workspace.id,
                        name: workspace.name,
                        path: workspace.path,
                        gitBranch: workspace.gitBranch,
                        backendIdentifier: workspace.backendIdentifier,
                        remoteId: workspace.remoteId,
                        backendMetadataRaw: workspace.backendMetadataRaw,
                        usesHostWorkspaceFiles: workspace.usesHostWorkspaceFiles
                    )
                }
            )
        }
    }

    /// What a confirmed cleanup does for this item. A record whose directory is gone only
    /// prunes the worktree when git metadata for it survives — otherwise there is nothing
    /// to prune and the record deletion stands alone.
    func cleanupSteps(for item: WorkspaceOrphanItem) -> [CleanupStep] {
        switch item.kind {
        case .gitWorktreeWithoutRecord:
            return [.pruneGitWorktree]
        case .workspaceRecordMissingDirectory:
            return item.hasPrunableGitMetadata
                ? [.pruneGitWorktree, .deleteWorkspaceRecord]
                : [.deleteWorkspaceRecord]
        case .lumeVMWithoutWorkspace:
            return [.deleteLumeVM]
        }
    }

    /// Whether adoption is offered for this item at all. Only a live, undamaged worktree with
    /// no record is something the app can adopt as-is — a record whose directory is gone or a
    /// leftover Lume VM are cleanup-only, since there is no live filesystem state to adopt.
    func canAdopt(_ item: WorkspaceOrphanItem) -> Bool {
        item.kind == .gitWorktreeWithoutRecord && !item.hasPrunableGitMetadata
    }

    /// Creates the `Workspace` record for an existing worktree the app did not create.
    ///
    /// Marked `isAdopted` so the archived-workspace purge sweep never deletes this directory on
    /// a timer the user does not directly act on (#1390) — the sweep is the one path that flag
    /// closes; archiving or manually deleting an adopted workspace still works like any other.
    ///
    /// Returns the created workspace so the caller can select it and, when a live tmux session
    /// was bound, realize its terminal attached to that session rather than a fresh shell.
    func adoptGitWorktree(
        _ item: WorkspaceOrphanItem,
        in repos: [Repo],
        modelContext: ModelContext
    ) throws -> Workspace {
        guard canAdopt(item),
            let path = item.path,
            let repoID = item.repoID,
            let repo = repos.first(where: { $0.id == repoID })
        else {
            throw WorkspaceOrphanReconciliationError.unsupportedCleanupItem
        }

        let workspace = Workspace(
            name: item.resourceName,
            path: URL(fileURLWithPath: path, isDirectory: true),
            sourceRepo: repo,
            gitBranch: item.gitBranch,
            isAdopted: true
        )
        modelContext.insert(workspace)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        return workspace
    }

    func deleteWorkspaceRecord(
        for item: WorkspaceOrphanItem,
        in repos: [Repo],
        modelContext: ModelContext
    ) throws {
        guard let workspaceID = item.workspaceID,
            let workspace = repos.flatMap(\.workspaces).first(where: { $0.id == workspaceID })
        else {
            throw WorkspaceOrphanReconciliationError.unsupportedCleanupItem
        }

        modelContext.delete(workspace)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func deleteLumeVM(
        for item: WorkspaceOrphanItem,
        registry: WorkspaceProviderRegistry
    ) async throws {
        guard let target = item.lumeCleanupTarget(),
            let provider = registry.provider(for: LumeWorkspaceProvider.identifier)
        else {
            throw WorkspaceOrphanReconciliationError.unsupportedCleanupItem
        }

        do {
            try await provider.deleteWorkspace(target)
        } catch {
            // The VM directory was just found on disk, so a Lume not-found here means the
            // `workspaces` storage location isn't registered — surface that instead of "Not found".
            guard let diagnostic = LumeErrorHeuristics.missingWorkspacesStorageDiagnostic(for: error) else {
                throw error
            }
            throw WorkspaceProviderError.unavailable(diagnostic)
        }
    }

    func confirmationTitle(for item: WorkspaceOrphanItem?) -> String {
        guard let item else { return "Clean Workspace Leftover?" }
        switch item.kind {
        case .gitWorktreeWithoutRecord:
            return "Remove Orphaned Worktree?"
        case .workspaceRecordMissingDirectory:
            return "Remove Missing Workspace Record?"
        case .lumeVMWithoutWorkspace:
            return "Delete Orphaned Lume VM?"
        }
    }

    func confirmationMessage(for item: WorkspaceOrphanItem?) -> String {
        guard let item else { return "" }
        switch item.kind {
        case .gitWorktreeWithoutRecord:
            return
                "This removes the git worktree '\(item.resourceName)' and its workspace branch when it is a workspace-owned branch."
        case .workspaceRecordMissingDirectory:
            return
                "This removes the workspace record for '\(item.resourceName)'. No workspace directory exists at its saved path."
        case .lumeVMWithoutWorkspace:
            return "This deletes the Lume VM '\(item.resourceName)' from workspace VM storage."
        }
    }

    func cleanupFailureMessage(for item: WorkspaceOrphanItem, error: Error) -> String {
        "Could not clean '\(item.resourceName)': \(error.localizedDescription)"
    }
}
