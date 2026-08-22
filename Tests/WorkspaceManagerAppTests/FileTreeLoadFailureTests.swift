//
//  FileTreeLoadFailureTests.swift
//  WorkspaceManagerAppTests
//
//  Pins file-tree failure classification, recovery routing, and state replacement.
//

import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("FileTreeLoadFailure")
struct FileTreeLoadFailureTests {
    @Test("Finder selects an existing workspace directory")
    func finderSelectsExistingTarget() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)

        let location = FileTreeFinderLocation.resolve(directoryURL: target)

        #expect(location.selectedPath == target.path)
        #expect(location.viewerRootPath == root.path)
    }

    @Test("Finder opens the parent when a workspace directory is missing")
    func finderOpensExistingParent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingTarget = root.appendingPathComponent("missing-workspace", isDirectory: true)

        let location = FileTreeFinderLocation.resolve(directoryURL: missingTarget)

        #expect(location.selectedPath == nil)
        #expect(location.viewerRootPath == root.path)
    }

    @Test("Finder walks a deeply missing path to the nearest existing ancestor")
    func finderOpensNearestExistingAncestor() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existingAncestor = root.appendingPathComponent("repos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: existingAncestor,
            withIntermediateDirectories: false
        )
        let deeplyMissingTarget =
            existingAncestor
            .appendingPathComponent("team", isDirectory: true)
            .appendingPathComponent("project", isDirectory: true)
            .appendingPathComponent("worktree", isDirectory: true)

        let location = FileTreeFinderLocation.resolve(directoryURL: deeplyMissingTarget)

        #expect(location.selectedPath == nil)
        #expect(location.viewerRootPath == existingAncestor.path)
    }

    @Test("Distinguishable errors provide safe reasons and route one recovery action")
    func errorsProvideSafeReasonsAndRouteRecovery() {
        let unavailable = FileTreeLoadFailure.classify(GitError.fileTreeRootUnavailable)
        let permission = FileTreeLoadFailure.classify(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        )
        let unreadable = FileTreeLoadFailure.classify(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
        )

        #expect(unavailable == .directoryUnavailable)
        #expect(unavailable.reason == "This folder is no longer available on this Mac.")
        #expect(unavailable.recoveryAction == .revealInFinder)
        #expect(permission == .permissionDenied)
        #expect(permission.reason == "WorkSpaces does not have permission to read this folder.")
        #expect(permission.recoveryAction == .revealInFinder)
        #expect(unreadable == .unreadable)
        #expect(unreadable.reason == "The file tree could not be read.")
        #expect(unreadable.recoveryAction == .retry)

        var routedAction = ""
        unreadable.recoveryAction.perform(
            retry: { routedAction = "retry" },
            revealInFinder: { routedAction = "finder" }
        )
        #expect(routedAction == "retry")

        unavailable.recoveryAction.perform(
            retry: { routedAction = "retry" },
            revealInFinder: { routedAction = "finder" }
        )
        #expect(routedAction == "finder")

        let state = RightPaneSessionState()
        let refreshRequestID = state.refreshRequestID
        unreadable.recoveryAction.perform(
            retry: state.requestRefresh,
            revealInFinder: {}
        )
        #expect(state.refreshRequestID != refreshRequestID)
    }

    @Test("A successful empty directory replaces the previous failure without becoming an error")
    func successfulEmptyDirectoryClearsFailure() {
        let state = RightPaneSessionState()
        state.applyFileTreeResult(.failure(.permissionDenied))

        #expect(state.fileTree == nil)
        #expect(state.fileTreeFailure == .permissionDenied)

        let emptyRoot = FileNode(
            name: "empty",
            path: "",
            isDirectory: true,
            children: []
        )
        state.applyFileTreeResult(.success(emptyRoot))

        #expect(state.fileTree == emptyRoot)
        #expect(state.fileTreeFailure == nil)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-tree-finder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
