//
//  WorkspaceOrphanReconciliationBannerRenderTests.swift
//  WorkspaceManagerAppTests
//
//  Renders the leftover-cleanup banner from `WorkspaceOrphanReconciliationState` so the
//  extracted state drives the same visible surface the main window shows. Writes PNGs for
//  PR evidence when `WORKSPACES_EVIDENCE_DIR` is set; otherwise it is a layout smoke test.
//

import AppKit
import SwiftUI
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("WorkspaceOrphanReconciliationBanner render")
struct WorkspaceOrphanReconciliationBannerRenderTests {
    private func makeItem(
        id: String,
        kind: WorkspaceOrphanKind,
        resourceName: String
    ) -> WorkspaceOrphanItem {
        WorkspaceOrphanItem(
            id: id,
            kind: kind,
            repoID: UUID(),
            repoName: "workspaces",
            repoLocalPath: "/Users/dev/code/workspaces",
            workspaceID: kind == .workspaceRecordMissingDirectory ? UUID() : nil,
            workspaceName: resourceName,
            resourceName: resourceName,
            path: "/Users/dev/code/workspaces/.workspaces/\(resourceName)",
            storagePath: kind == .lumeVMWithoutWorkspace ? "/Users/dev/.lume/workspaces" : nil,
            gitBranch: "feature/\(resourceName)",
            hasPrunableGitMetadata: kind == .workspaceRecordMissingDirectory
        )
    }

    private func render(
        _ state: WorkspaceOrphanReconciliationState,
        to fileName: String
    ) throws {
        let orphanController = WorkspaceOrphanReconciliationController()
        let banner = WorkspaceOrphanReconciliationBanner(
            items: state.visibleItems,
            cleaningItemIDs: state.cleaningItemIDs,
            adoptingItemIDs: state.adoptingItemIDs,
            canAdopt: { orphanController.canAdopt($0) },
            onClean: { _ in },
            onAdopt: { _ in },
            onDismiss: {},
            initiallyExpanded: true
        )
        .frame(width: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: banner)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)

        guard let dir = ProcessInfo.processInfo.environment["WORKSPACES_EVIDENCE_DIR"],
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            return
        }
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(fileName))
    }

    @Test("Banner renders every scanned leftover kind")
    func rendersAllScannedItems() throws {
        var state = WorkspaceOrphanReconciliationState()
        state.applyScanResult([
            makeItem(id: "git", kind: .gitWorktreeWithoutRecord, resourceName: "stale-worktree"),
            makeItem(
                id: "record", kind: .workspaceRecordMissingDirectory, resourceName: "missing-dir"),
            makeItem(id: "lume", kind: .lumeVMWithoutWorkspace, resourceName: "orphan-vm"),
        ])

        #expect(state.visibleItems.count == 3)
        try render(state, to: "orphan-banner-all-items.png")
    }

    @Test("Banner shows only the leftover found after a dismissal")
    func rendersOnlyNewItemAfterDismissal() throws {
        var state = WorkspaceOrphanReconciliationState()
        let existing = makeItem(
            id: "git", kind: .gitWorktreeWithoutRecord, resourceName: "stale-worktree")
        state.applyScanResult([existing])
        state.dismissVisibleItems()

        state.applyScanResult([
            existing,
            makeItem(id: "lume", kind: .lumeVMWithoutWorkspace, resourceName: "orphan-vm"),
        ])

        #expect(state.visibleItems.map(\.id) == ["lume"])
        try render(state, to: "orphan-banner-after-dismissal.png")
    }

    /// Adopt is offered beside Clean for a live worktree with no record — the row a person
    /// created with `workspaces ws new` and the app never saw (#1390) — but not for the other
    /// two kinds, which have no live filesystem state to adopt.
    @Test("Adopt is offered only for a worktree that can be adopted as-is")
    func adoptOfferedOnlyForAdoptableWorktree() throws {
        var state = WorkspaceOrphanReconciliationState()
        state.applyScanResult([
            makeItem(id: "git", kind: .gitWorktreeWithoutRecord, resourceName: "issue-1390"),
            makeItem(
                id: "record", kind: .workspaceRecordMissingDirectory, resourceName: "missing-dir"),
            makeItem(id: "lume", kind: .lumeVMWithoutWorkspace, resourceName: "orphan-vm"),
        ])

        let orphanController = WorkspaceOrphanReconciliationController()
        #expect(state.visibleItems.map { orphanController.canAdopt($0) } == [true, false, false])
        try render(state, to: "orphan-banner-adopt-offered.png")
    }
}
