//
//  WorkspaceDirectoryRemover.swift
//  WorkspaceManager
//
//  Removes host workspace directories while preserving git worktree metadata.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "WorkspaceDirectoryRemover")

enum WorkspaceDirectoryRemover {
    static func remove(at workspaceURL: URL) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: workspaceURL.path) else {
            cleanupEmptyParent(of: workspaceURL, fileManager: fileManager)
            return
        }

        if isLinkedGitWorktree(at: workspaceURL, fileManager: fileManager) {
            let branchName: String?
            do {
                branchName = try await currentBranchName(at: workspaceURL)
            } catch {
                branchName = nil
                log.warning(
                    "Failed to read current branch for workspace cleanup at \(workspaceURL.path): \(error.localizedDescription)"
                )
            }

            let commonGitDirectoryURL: URL?
            do {
                commonGitDirectoryURL = try await commonGitDirectory(at: workspaceURL)
            } catch {
                commonGitDirectoryURL = nil
                log.warning(
                    "Failed to read common git directory for workspace cleanup at \(workspaceURL.path): \(error.localizedDescription)"
                )
            }

            let removalArguments: [String]
            if let commonGitDirectory = commonGitDirectoryURL {
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
                currentDirectory: workspaceURL.deletingLastPathComponent(),
                timeout: 30
            )

            guard result.success else {
                let reason = result.stderr.isEmpty ? "Unknown error" : result.stderr
                throw WorkspaceError.deletionFailed(reason: reason)
            }

            if let branchName,
                branchName.hasPrefix("workspace/"),
                let commonGitDirectory = commonGitDirectoryURL
            {
                let branchDeletionArguments = ["--git-dir", commonGitDirectory.path, "branch", "-D", branchName]
                do {
                    let branchDeletionResult = try await ProcessRunner.run(
                        executable: "/usr/bin/git",
                        arguments: branchDeletionArguments,
                        timeout: 30
                    )
                    if !branchDeletionResult.success {
                        let reason = branchDeletionResult.stderr.isEmpty ? "Unknown error" : branchDeletionResult.stderr
                        log.warning(
                            "Failed best-effort workspace branch cleanup for \(branchName) at \(commonGitDirectory.path): \(reason)"
                        )
                    }
                } catch {
                    log.warning(
                        "Failed best-effort workspace branch cleanup for \(branchName) at \(commonGitDirectory.path): \(error.localizedDescription)"
                    )
                }
            }
        } else {
            try fileManager.removeItem(at: workspaceURL)
        }

        cleanupEmptyParent(of: workspaceURL, fileManager: fileManager)
    }

    static func isLinkedGitWorktree(at workspaceURL: URL, fileManager: FileManager) -> Bool {
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
            currentDirectory: workspaceURL,
            timeout: 30
        )
        guard result.success else {
            let reason = result.stderr.isEmpty ? "Unknown error" : result.stderr
            throw GitError.commandFailed(args: ["branch", "--show-current"], stderr: reason)
        }
        let branchName = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return branchName.isEmpty ? nil : branchName
    }

    static func commonGitDirectory(at workspaceURL: URL) async throws -> URL? {
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            currentDirectory: workspaceURL,
            timeout: 30
        )
        guard result.success else {
            let reason = result.stderr.isEmpty ? "Unknown error" : result.stderr
            throw GitError.commandFailed(
                args: ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                stderr: reason
            )
        }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    static func cleanupEmptyParent(of workspaceURL: URL, fileManager: FileManager) {
        let parentDir = workspaceURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parentDir.path) else { return }

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: parentDir.path)
            if contents.isEmpty {
                try fileManager.removeItem(at: parentDir)
            }
        } catch {
            log.warning(
                "Failed best-effort empty parent cleanup at \(parentDir.path): \(error.localizedDescription)"
            )
        }
    }
}
