//
//  WorkspaceService.swift
//  WorkspaceManager
//
//  Workspace creation, git worktree materialization, lifecycle hooks, and management
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "WorkspaceService")

public actor WorkspaceService: WorkspaceServiceProtocol {
    public static let shared = WorkspaceService()

    private let gitService: any GitServiceProtocol

    // MARK: - Workspace Root Configuration

    private static let defaultWorkspacesRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("workspaces")
    }()

    public var workspacesRoot: URL {
        if let customPath = UserDefaults.standard.string(forKey: "workspacesRoot"),
            !customPath.isEmpty
        {
            return URL(fileURLWithPath: customPath)
        }
        return Self.defaultWorkspacesRoot
    }

    public func setWorkspacesRoot(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "workspacesRoot")
    }

    public func resetWorkspacesRoot() {
        UserDefaults.standard.removeObject(forKey: "workspacesRoot")
    }

    public init(gitService: any GitServiceProtocol = GitService.shared) {
        self.gitService = gitService
        do {
            try FileManager.default.createDirectory(
                at: Self.defaultWorkspacesRoot,
                withIntermediateDirectories: true
            )
        } catch {
            log.warning(
                "Failed to create default workspaces root at \(Self.defaultWorkspacesRoot.path): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Create Workspace

    public func createWorkspace(
        repoName: String,
        repoLocalURL: URL,
        name: String,
        progress: WorkspaceCreationProgressHandler? = nil
    ) async throws -> NewWorkspaceInfo {
        let sanitizedName = Self.sanitizeWorkspaceNameComponent(name)
        guard Self.isValidWorkspaceNameComponent(sanitizedName) else {
            throw WorkspaceError.invalidName(name: name)
        }

        let repoDir = workspacesRoot.appendingPathComponent(repoName, isDirectory: true)
        let workspaceDir = repoDir.appendingPathComponent(sanitizedName, isDirectory: true)
        let normalizedRepoDir = repoDir.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedWorkspaceDir = workspaceDir.standardizedFileURL.resolvingSymlinksInPath()

        guard path(normalizedWorkspaceDir.path, isInside: normalizedRepoDir.path) else {
            throw WorkspaceError.invalidName(name: name)
        }

        if FileManager.default.fileExists(atPath: workspaceDir.path) {
            throw WorkspaceError.alreadyExists(name: sanitizedName)
        }

        try FileManager.default.createDirectory(
            at: repoDir,
            withIntermediateDirectories: true
        )

        await progress?(.preparing)

        var warnings: [String] = []

        let branchName = "workspace/\(sanitizedName)"
        await progress?(.creatingWorktree)
        do {
            try await gitService.createWorktree(
                branchName: branchName,
                at: workspaceDir,
                from: repoLocalURL
            )
        } catch {
            try? await WorkspaceDirectoryRemover.remove(at: workspaceDir)
            throw WorkspaceError.worktreeCreationFailed(reason: error.localizedDescription)
        }

        do {
            let currentBranch = try? await gitService.getCurrentBranch(at: workspaceDir)

            await progress?(.runningSetupScript)
            let setupResult = try await runLifecycleScript("setup.sh", in: workspaceDir)
            if !setupResult.stdout.isEmpty {
                log.info("setup.sh output: \(setupResult.stdout)")
            }
            if setupResult.exitCode != 0 {
                let msg = "setup.sh exited with code \(setupResult.exitCode): \(setupResult.stderr)"
                log.warning("\(msg)")
                warnings.append(msg)
            }

            await progress?(.finished)

            return NewWorkspaceInfo(
                name: name,
                path: workspaceDir,
                gitBranch: currentBranch ?? branchName,
                warnings: warnings
            )
        } catch {
            try? await WorkspaceDirectoryRemover.remove(at: workspaceDir)
            throw error
        }
    }

    // MARK: - Archive Workspace

    public func archiveWorkspace(at workspaceURL: URL) async throws {
        let archiveResult = try await runLifecycleScript("archive.sh", in: workspaceURL)
        if !archiveResult.stdout.isEmpty {
            log.info("archive.sh output: \(archiveResult.stdout)")
        }
        if archiveResult.exitCode != 0 {
            log.warning("archive.sh exited with code \(archiveResult.exitCode): \(archiveResult.stderr)")
        }
    }

    // MARK: - Delete Workspace

    public func deleteWorkspace(at workspaceURL: URL, deleteFiles: Bool) async throws {
        _ = try await runLifecycleScript("archive.sh", in: workspaceURL)

        if deleteFiles {
            try await WorkspaceDirectoryRemover.remove(at: workspaceURL)
        }
    }

    // MARK: - Lifecycle Scripts

    public struct ScriptResult: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        public var success: Bool { exitCode == 0 }

        public init(exitCode: Int32, stdout: String, stderr: String) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public func runLifecycleScript(_ scriptName: String, in directory: URL) async throws -> ScriptResult {
        let scriptPath = directory.appendingPathComponent(scriptName)

        guard FileManager.default.fileExists(atPath: scriptPath.path) else {
            return ScriptResult(exitCode: 0, stdout: "", stderr: "")
        }

        // Ensure script is executable
        if let attributes = try? FileManager.default.attributesOfItem(atPath: scriptPath.path),
            let permissions = attributes[.posixPermissions] as? NSNumber
        {
            let mode = permissions.uint16Value
            if mode & 0o111 == 0 {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: mode | 0o111)],
                    ofItemAtPath: scriptPath.path
                )
            }
        }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")

        let result = try await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: [scriptPath.path],
            currentDirectory: directory,
            environment: env
        )

        return ScriptResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }

    // MARK: - Workspace Stats

    public func getWorkspaceSize(at workspaceURL: URL) async throws -> Int64 {
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]

        let fileURLs: [URL] = {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: workspaceURL,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles]
                )
            else {
                return []
            }
            return enumerator.compactMap { $0 as? URL }
        }()

        var totalSize: Int64 = 0
        for fileURL in fileURLs {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                let isDirectory = resourceValues.isDirectory,
                !isDirectory,
                let fileSize = resourceValues.fileSize
            else {
                continue
            }
            totalSize += Int64(fileSize)
        }

        return totalSize
    }

    // MARK: - Helpers

    public func sanitizeFilename(_ name: String) -> String {
        Self.sanitizeWorkspaceNameComponent(name)
    }

    public nonisolated static func sanitizeWorkspaceNameComponent(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?*\"<>|")
        let sanitized =
            name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)

        return
            sanitized
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
    }

    public nonisolated static func isValidWorkspaceNameComponent(_ component: String) -> Bool {
        guard !component.isEmpty else { return false }
        guard component != ".", component != ".." else { return false }
        guard !component.contains("/"), !component.contains("\\") else { return false }
        return true
    }

    private func path(_ path: String, isInside root: String) -> Bool {
        if path == root { return true }
        guard root != "/" else { return true }
        return path.hasPrefix(root + "/")
    }

    public var root: URL {
        workspacesRoot
    }
}

// MARK: - Errors

public enum WorkspaceError: LocalizedError {
    case notAGitRepo
    case alreadyExists(name: String)
    case invalidName(name: String)
    case worktreeCreationFailed(reason: String)
    case deletionFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .notAGitRepo:
            return "The selected folder is not a git repository"
        case .alreadyExists(let name):
            return "A workspace named '\(name)' already exists"
        case .invalidName(let name):
            return "Workspace name '\(name)' is not valid"
        case .worktreeCreationFailed(let reason):
            return "Failed to create git worktree: \(reason)"
        case .deletionFailed(let reason):
            return "Failed to delete workspace: \(reason)"
        }
    }
}
