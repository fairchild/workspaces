//
//  WorkspaceDirectoryArchiver.swift
//  WorkspaceManager
//
//  Moves a workspace directory into (and back out of) the `.archived/` area of
//  the workspaces root, preserving git worktree metadata via `git worktree move`.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "WorkspaceDirectoryArchiver")

public enum WorkspaceDirectoryArchiver {
    /// Archived layout mirrors the live layout one level down a `.archived/` dir:
    /// a workspace at `<root>/<repo>/<name>` archives to `<root>/.archived/<repo>/<name>`.
    public static let archivedDirectoryComponent = ".archived"

    /// Destination for archiving `<root>/<repo>/<name>` → `<root>/.archived/<repo>/<name>`.
    public static func archivedDestination(for source: URL) -> URL {
        let name = source.lastPathComponent
        let repoDir = source.deletingLastPathComponent()
        let repo = repoDir.lastPathComponent
        let root = repoDir.deletingLastPathComponent()
        return
            root
            .appendingPathComponent(archivedDirectoryComponent, isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Destination for restoring `<root>/.archived/<repo>/<name>` → `<root>/<repo>/<name>`.
    public static func restoredDestination(for archivedSource: URL) -> URL {
        let name = archivedSource.lastPathComponent
        let repoDir = archivedSource.deletingLastPathComponent()
        let repo = repoDir.lastPathComponent
        let archivedRoot = repoDir.deletingLastPathComponent()
        let root = archivedRoot.deletingLastPathComponent()
        return
            root
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Moves a workspace directory, keeping git worktree bookkeeping consistent.
    ///
    /// A linked worktree's `.git` file and `.git/worktrees/<id>/gitdir` both encode
    /// absolute paths, so a plain `FileManager.moveItem` would orphan the worktree —
    /// `git worktree move` updates both sides atomically.
    public static func move(from sourceURL: URL, to destinationURL: URL) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw WorkspaceError.deletionFailed(reason: "No workspace directory at \(sourceURL.path)")
        }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceError.alreadyExists(name: destinationURL.lastPathComponent)
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if WorkspaceDirectoryRemover.isLinkedGitWorktree(at: sourceURL, fileManager: fileManager) {
            try await moveGitWorktree(from: sourceURL, to: destinationURL)
        } else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }

        WorkspaceDirectoryRemover.cleanupEmptyParent(of: sourceURL, fileManager: fileManager)
    }

    private static func moveGitWorktree(from sourceURL: URL, to destinationURL: URL) async throws {
        let commonGitDirectoryURL: URL?
        do {
            commonGitDirectoryURL = try await WorkspaceDirectoryRemover.commonGitDirectory(at: sourceURL)
        } catch {
            commonGitDirectoryURL = nil
            log.warning(
                "Failed to read common git directory for workspace move at \(sourceURL.path): \(error.localizedDescription)"
            )
        }

        let arguments: [String]
        if let commonGitDirectory = commonGitDirectoryURL {
            arguments = [
                "--git-dir", commonGitDirectory.path,
                "worktree", "move", sourceURL.path, destinationURL.path,
            ]
        } else {
            arguments = ["worktree", "move", sourceURL.path, destinationURL.path]
        }

        let result = try await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectory: sourceURL.deletingLastPathComponent(),
            timeout: 30
        )

        guard result.success else {
            let reason = result.stderr.isEmpty ? "Unknown error" : result.stderr
            throw WorkspaceError.deletionFailed(reason: reason)
        }
    }
}
