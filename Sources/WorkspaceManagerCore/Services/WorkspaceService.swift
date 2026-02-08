//
//  WorkspaceService.swift
//  WorkspaceManager
//
//  Workspace creation, copying, lifecycle hooks, and management
//

import Foundation

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
           !customPath.isEmpty {
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
        try? FileManager.default.createDirectory(
            at: Self.defaultWorkspacesRoot,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Create Workspace

    public func createWorkspace(from repo: Repo, name: String) async throws -> Workspace {
        // Sanitize name for filesystem
        let sanitizedName = sanitizeFilename(name)

        // Create workspace directory path: {workspacesRoot}/{repo-name}/{workspace-name}
        let repoDir = workspacesRoot.appendingPathComponent(repo.name, isDirectory: true)
        let workspaceDir = repoDir.appendingPathComponent(sanitizedName, isDirectory: true)

        // Check if workspace already exists
        if FileManager.default.fileExists(atPath: workspaceDir.path) {
            throw WorkspaceError.alreadyExists(name: sanitizedName)
        }

        // Create parent directory if needed
        try FileManager.default.createDirectory(
            at: repoDir,
            withIntermediateDirectories: true
        )

        // Copy repository to workspace
        try await copyRepository(from: repo.localURL, to: workspaceDir)

        // Create a new branch for this workspace
        let branchName = "workspace/\(sanitizedName)"
        do {
            try await gitService.createBranch(branchName, at: workspaceDir)
        } catch {
            // Branch creation failed, but workspace was created - continue
            print("Warning: Could not create branch '\(branchName)': \(error)")
        }

        // Get actual branch name
        let currentBranch = try? await gitService.getCurrentBranch(at: workspaceDir)

        // Run setup.sh if it exists
        let setupResult = try await runLifecycleScript("setup.sh", in: workspaceDir)
        if !setupResult.stdout.isEmpty {
            print("setup.sh output:\n\(setupResult.stdout)")
        }
        if setupResult.exitCode != 0 {
            print("setup.sh warning (exit \(setupResult.exitCode)):\n\(setupResult.stderr)")
        }

        return Workspace(
            name: name,
            path: workspaceDir,
            sourceRepo: repo,
            gitBranch: currentBranch ?? branchName
        )
    }

    // MARK: - Copy Repository

    private func copyRepository(from source: URL, to destination: URL) async throws {
        // Use ditto for efficient copy (preserves resource forks, permissions, etc.)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "--rsrc",           // Preserve resource forks
            source.path,
            destination.path
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "Unknown error"
            throw WorkspaceError.copyFailed(reason: stderr)
        }
    }

    // MARK: - Archive Workspace

    /// Archive a workspace (runs archive.sh, caller updates status)
    public func archiveWorkspace(_ workspace: Workspace) async throws {
        // Run archive.sh if it exists
        let archiveResult = try await runLifecycleScript("archive.sh", in: workspace.workspaceURL)
        if !archiveResult.stdout.isEmpty {
            print("archive.sh output:\n\(archiveResult.stdout)")
        }
        if archiveResult.exitCode != 0 {
            print("archive.sh warning (exit \(archiveResult.exitCode)):\n\(archiveResult.stderr)")
        }

        // Status update to .archived happens in caller (SwiftData context)
    }

    // MARK: - Delete Workspace

    public func deleteWorkspace(_ workspace: Workspace, deleteFiles: Bool) async throws {
        // Run archive.sh before deletion (cleanup)
        _ = try await runLifecycleScript("archive.sh", in: workspace.workspaceURL)

        if deleteFiles {
            try FileManager.default.removeItem(at: workspace.workspaceURL)

            // Clean up empty parent directory
            let parentDir = workspace.workspaceURL.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: parentDir.path),
               contents.isEmpty {
                try? FileManager.default.removeItem(at: parentDir)
            }
        }

        // SwiftData deletion happens in caller
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

    /// Run a lifecycle script (setup.sh or archive.sh) in the workspace directory
    /// - Parameters:
    ///   - scriptName: Name of the script file
    ///   - directory: Directory to run the script in
    /// - Returns: Script execution result (success if script doesn't exist)
    public func runLifecycleScript(_ scriptName: String, in directory: URL) async throws -> ScriptResult {
        let scriptPath = directory.appendingPathComponent(scriptName)

        // Check if script exists - silently skip if not
        guard FileManager.default.fileExists(atPath: scriptPath.path) else {
            return ScriptResult(exitCode: 0, stdout: "", stderr: "")
        }

        // Ensure script is executable
        if let attributes = try? FileManager.default.attributesOfItem(atPath: scriptPath.path),
           let permissions = attributes[.posixPermissions] as? NSNumber {
            let mode = permissions.uint16Value
            if mode & 0o111 == 0 {
                // Not executable, add execute permission
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: mode | 0o755)],
                    ofItemAtPath: scriptPath.path
                )
            }
        }

        // Run script with bash
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath.path]
        process.currentDirectoryURL = directory

        // Inherit user's environment with augmented PATH
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        return ScriptResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    // MARK: - Workspace Stats

    public func getWorkspaceSize(_ workspace: Workspace) async throws -> Int64 {
        let workspaceURL = workspace.workspaceURL
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]

        // Collect file URLs synchronously to avoid Swift 6 iterator isolation warning
        let fileURLs: [URL] = {
            guard let enumerator = FileManager.default.enumerator(
                at: workspaceURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            return enumerator.compactMap { $0 as? URL }
        }()

        var totalSize: Int64 = 0
        for fileURL in fileURLs {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                  let isDirectory = resourceValues.isDirectory,
                  !isDirectory,
                  let fileSize = resourceValues.fileSize else {
                continue
            }
            totalSize += Int64(fileSize)
        }

        return totalSize
    }

    // MARK: - Helpers

    public func sanitizeFilename(_ name: String) -> String {
        // Remove or replace invalid filename characters
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?*\"<>|")
        let sanitized = name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)

        // Replace spaces with hyphens and lowercase
        return sanitized
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
    }

    // MARK: - Get Workspaces Root (for display)

    public var root: URL {
        workspacesRoot
    }
}

// MARK: - Errors

public enum WorkspaceError: LocalizedError {
    case notAGitRepo
    case alreadyExists(name: String)
    case copyFailed(reason: String)
    case deletionFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .notAGitRepo:
            return "The selected folder is not a git repository"
        case .alreadyExists(let name):
            return "A workspace named '\(name)' already exists"
        case .copyFailed(let reason):
            return "Failed to copy repository: \(reason)"
        case .deletionFailed(let reason):
            return "Failed to delete workspace: \(reason)"
        }
    }
}
