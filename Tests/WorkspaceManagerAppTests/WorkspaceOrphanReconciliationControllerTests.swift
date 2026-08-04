//
//  WorkspaceOrphanReconciliationControllerTests.swift
//  WorkspaceManagerAppTests
//
//  Coverage for the main window's leftover-cleanup bookkeeping: which scanned orphans stay
//  visible across rescans, and what a confirmed cleanup does for each orphan kind.
//

import Foundation
import SwiftData
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("WorkspaceOrphanReconciliation")
struct WorkspaceOrphanReconciliationControllerTests {
    private let controller = WorkspaceOrphanReconciliationController()

    // MARK: - Fixtures

    private func makeItem(
        id: String,
        kind: WorkspaceOrphanKind = .gitWorktreeWithoutRecord,
        workspaceID: UUID? = nil,
        resourceName: String = "leftover",
        hasPrunableGitMetadata: Bool = false,
        storagePath: String? = nil
    ) -> WorkspaceOrphanItem {
        WorkspaceOrphanItem(
            id: id,
            kind: kind,
            repoID: nil,
            repoName: nil,
            repoLocalPath: nil,
            workspaceID: workspaceID,
            workspaceName: nil,
            resourceName: resourceName,
            path: "/tmp/workspaces/\(resourceName)",
            storagePath: storagePath,
            gitBranch: nil,
            hasPrunableGitMetadata: hasPrunableGitMetadata
        )
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }

    // MARK: - Visibility and dismissal

    @Test("Dismissed items drop out of the banner while the rest stay")
    func dismissalHidesOnlyVisibleItems() {
        var state = WorkspaceOrphanReconciliationState()
        state.applyScanResult([makeItem(id: "a"), makeItem(id: "b")])

        state.dismissVisibleItems()

        #expect(state.visibleItems.isEmpty)
        #expect(state.items.count == 2)
    }

    @Test("A leftover found after a dismissal still surfaces the banner")
    func newItemAfterDismissalIsVisible() {
        var state = WorkspaceOrphanReconciliationState()
        state.applyScanResult([makeItem(id: "a")])
        state.dismissVisibleItems()

        state.applyScanResult([makeItem(id: "a"), makeItem(id: "b")])

        #expect(state.visibleItems.map(\.id) == ["b"])
    }

    @Test("A dismissed leftover that disappears and returns is offered again")
    func dismissalDoesNotSurviveTheItemLeavingTheScan() {
        var state = WorkspaceOrphanReconciliationState()
        state.applyScanResult([makeItem(id: "a")])
        state.dismissVisibleItems()

        state.applyScanResult([])
        state.applyScanResult([makeItem(id: "a")])

        #expect(state.visibleItems.map(\.id) == ["a"])
    }

    // MARK: - Cleanup in flight

    @Test("A second confirmation while a cleanup is running is ignored")
    func repeatCleanupIsRejectedWhileInFlight() {
        var state = WorkspaceOrphanReconciliationState()
        let item = makeItem(id: "a")
        state.applyScanResult([item])

        let startedFirst = state.beginCleaning(item)
        let startedAgain = state.beginCleaning(item)
        #expect(startedFirst)
        #expect(startedAgain == false)
        #expect(state.isCleaning(item))

        state.endCleaning(item)
        #expect(state.isCleaning(item) == false)

        let startedAfterFinishing = state.beginCleaning(item)
        #expect(startedAfterFinishing)
    }

    @Test("A cleaned item leaves the banner and forgets its dismissal")
    func cleanedItemIsRemovedWithItsDismissal() {
        var state = WorkspaceOrphanReconciliationState()
        let item = makeItem(id: "a")
        state.applyScanResult([item, makeItem(id: "b")])
        state.dismissVisibleItems()

        state.removeCleanedItem(item)

        #expect(state.items.map(\.id) == ["b"])
        #expect(state.dismissedItemIDs == ["b"])
    }

    // MARK: - Per-kind cleanup steps

    @Test("An orphaned worktree only prunes git")
    func worktreeWithoutRecordPrunesOnly() {
        let steps = controller.cleanupSteps(for: makeItem(id: "a", kind: .gitWorktreeWithoutRecord))
        #expect(steps == [.pruneGitWorktree])
    }

    @Test("A record with surviving git metadata prunes before the record is deleted")
    func recordWithPrunableMetadataPrunesFirst() {
        let item = makeItem(
            id: "a",
            kind: .workspaceRecordMissingDirectory,
            hasPrunableGitMetadata: true
        )
        #expect(controller.cleanupSteps(for: item) == [.pruneGitWorktree, .deleteWorkspaceRecord])
    }

    @Test("A record with nothing left to prune only deletes the record")
    func recordWithoutPrunableMetadataSkipsPrune() {
        let item = makeItem(
            id: "a",
            kind: .workspaceRecordMissingDirectory,
            hasPrunableGitMetadata: false
        )
        #expect(controller.cleanupSteps(for: item) == [.deleteWorkspaceRecord])
    }

    @Test("An orphaned Lume VM only deletes the VM")
    func lumeOrphanDeletesVM() {
        let steps = controller.cleanupSteps(for: makeItem(id: "a", kind: .lumeVMWithoutWorkspace))
        #expect(steps == [.deleteLumeVM])
    }

    // MARK: - Record deletion

    @Test("Deleting a record removes the workspace it names")
    func deleteWorkspaceRecordRemovesWorkspace() throws {
        let context = try makeContext()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        repo.workspaces = [workspace]
        context.insert(repo)
        context.insert(workspace)

        let item = makeItem(
            id: "record",
            kind: .workspaceRecordMissingDirectory,
            workspaceID: workspace.id
        )
        try controller.deleteWorkspaceRecord(for: item, in: [repo], modelContext: context)

        let remaining = try context.fetch(FetchDescriptor<Workspace>())
        #expect(remaining.isEmpty)
    }

    @Test("Deleting a record for an unknown workspace is rejected, not silently skipped")
    func deleteWorkspaceRecordRejectsUnknownWorkspace() throws {
        let context = try makeContext()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        context.insert(repo)

        let item = makeItem(
            id: "record",
            kind: .workspaceRecordMissingDirectory,
            workspaceID: UUID()
        )

        #expect(throws: WorkspaceOrphanReconciliationError.unsupportedCleanupItem) {
            try controller.deleteWorkspaceRecord(for: item, in: [repo], modelContext: context)
        }
    }

    @Test("A worktree orphan carries no workspace id, so record deletion is rejected")
    func deleteWorkspaceRecordRejectsItemWithoutWorkspaceID() throws {
        let context = try makeContext()
        let item = makeItem(id: "git", kind: .gitWorktreeWithoutRecord, workspaceID: nil)

        #expect(throws: WorkspaceOrphanReconciliationError.unsupportedCleanupItem) {
            try controller.deleteWorkspaceRecord(for: item, in: [], modelContext: context)
        }
    }

    @Test("A Lume orphan without storage has no cleanup target and is rejected")
    func deleteLumeVMRejectsItemWithoutStorage() async throws {
        let item = makeItem(id: "lume", kind: .lumeVMWithoutWorkspace, storagePath: nil)

        do {
            try await controller.deleteLumeVM(
                for: item,
                registry: WorkspaceProviderRegistry(providers: [])
            )
            Issue.record("Expected the cleanup to be rejected")
        } catch {
            #expect(
                error as? WorkspaceOrphanReconciliationError == .unsupportedCleanupItem
            )
        }
    }

    // MARK: - Snapshots and copy

    @Test("Repository snapshots carry the fields the reconciler matches on")
    func repositorySnapshotsPreserveWorkspaceFields() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        repo.workspaces = [workspace]

        let snapshots = controller.repositorySnapshots(repos: [repo])

        #expect(snapshots.count == 1)
        #expect(snapshots[0].id == repo.id)
        #expect(snapshots[0].name == "alpha")
        #expect(snapshots[0].localPath == repo.localPath)
        #expect(snapshots[0].workspaces.count == 1)
        #expect(snapshots[0].workspaces[0].id == workspace.id)
        #expect(snapshots[0].workspaces[0].path == workspace.path)
        #expect(snapshots[0].workspaces[0].backendIdentifier == workspace.backendIdentifier)
    }

    @Test("Confirmation copy names what the destructive action removes")
    func confirmationCopyIsKindSpecific() {
        let worktree = makeItem(id: "a", kind: .gitWorktreeWithoutRecord, resourceName: "feature-a")
        let record = makeItem(
            id: "b", kind: .workspaceRecordMissingDirectory, resourceName: "feature-b")
        let vm = makeItem(id: "c", kind: .lumeVMWithoutWorkspace, resourceName: "vm-c")

        #expect(controller.confirmationTitle(for: worktree) == "Remove Orphaned Worktree?")
        #expect(controller.confirmationTitle(for: record) == "Remove Missing Workspace Record?")
        #expect(controller.confirmationTitle(for: vm) == "Delete Orphaned Lume VM?")

        #expect(controller.confirmationMessage(for: worktree).contains("feature-a"))
        #expect(controller.confirmationMessage(for: record).contains("feature-b"))
        #expect(controller.confirmationMessage(for: vm).contains("vm-c"))
    }

    @Test("With no pending item the alert falls back to generic copy")
    func confirmationCopyWithoutItem() {
        #expect(controller.confirmationTitle(for: nil) == "Clean Workspace Leftover?")
        #expect(controller.confirmationMessage(for: nil).isEmpty)
    }
}
