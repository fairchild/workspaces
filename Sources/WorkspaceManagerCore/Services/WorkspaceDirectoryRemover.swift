//
//  WorkspaceDirectoryRemover.swift
//  WorkspaceManager
//
//  Removes host workspace directories while preserving git worktree metadata.
//

import Foundation

enum WorkspaceDirectoryRemover {
    static func remove(at workspaceURL: URL) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: workspaceURL.path) else {
            cleanupEmptyParent(of: workspaceURL, fileManager: fileManager)
            return
        }

        if isLinkedGitWorktree(at: workspaceURL, fileManager: fileManager) {
            let branchName = try? await currentBranchName(at: workspaceURL)
            let commonGitDirectory = try? await commonGitDirectory(at: workspaceURL)
            let removalArguments: [String]
            if let commonGitDirectory {
                removalArguments = [
                    "--git-dir",
                    commonGitDirectory.path,
                    "worktree",
                    "remove",
                    "--force",
                    workspaceURL.path,
                ]
            } else {
                removalArguments = ["worktree", "remove", "--force", workspaceURL.path]
            }
            let result = try await ProcessRunner.run(
                executable: "/usr/bin/git",
                arguments: removalArguments,
                currentDirectory: workspaceURL.deletingLastPathComponent()
            )

            guard result.success else {
                let reason = result.stderr.isEmpty ? "Unknown error" : result.stderr
                throw WorkspaceError.deletionFailed(reason: reason)
            }

            if let branchName,
                branchName.hasPrefix("workspace/"),
                let commonGitDirectory
            {
                _ = try? await ProcessRunner.run(
                    executable: "/usr/bin/git",
                    arguments: ["--git-dir", commonGitDirectory.path, "branch", "-D", branchName]
                )
            }
        } else {
            try fileManager.removeItem(at: workspaceURL)
        }

        cleanupEmptyParent(of: workspaceURL, fileManager: fileManager)
    }

    private static func isLinkedGitWorktree(at workspaceURL: URL, fileManager: FileManager) -> Bool {
        let gitFileURL = workspaceURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitFileURL.path, isDirectory: &isDirectory) else {
            return false
        }

        return !isDirectory.boolValue
    }

    private static func currentBranchName(at workspaceURL: URL) async throws -> String? {
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["branch", "--show-current"],
            currentDirectory: workspaceURL
        )
        guard result.success else { return nil }
        let branchName = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return branchName.isEmpty ? nil : branchName
    }

    private static func commonGitDirectory(at workspaceURL: URL) async throws -> URL? {
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            currentDirectory: workspaceURL
        )
        guard result.success else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    private static func cleanupEmptyParent(of workspaceURL: URL, fileManager: FileManager) {
        let parentDir = workspaceURL.deletingLastPathComponent()
        if let contents = try? fileManager.contentsOfDirectory(atPath: parentDir.path),
            contents.isEmpty
        {
            try? fileManager.removeItem(at: parentDir)
        }
    }
}
