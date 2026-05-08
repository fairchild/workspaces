//
//  WorkspaceService.swift
//  WorkspaceManager
//
//  Workspace creation, copying, lifecycle hooks, and management
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "WorkspaceService")

public actor WorkspaceService: WorkspaceServiceProtocol {
    public static let shared = WorkspaceService()

    private let gitService: any GitServiceProtocol
    private let claudeRunnerFactory: (@Sendable () -> HeadlessClaudeRunner)?

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
        self.claudeRunnerFactory = { HeadlessClaudeRunner() }
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

    /// Test-only initializer. Lets tests inject a stub
    /// `HeadlessClaudeRunner` (or skip the warm-up entirely with `nil`).
    /// Production code uses the zero-arg `init`.
    public init(
        gitService: any GitServiceProtocol,
        claudeRunnerFactory: (@Sendable () -> HeadlessClaudeRunner)?
    ) {
        self.gitService = gitService
        self.claudeRunnerFactory = claudeRunnerFactory
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
        await progress?(.copyingRepository)
        try await copyRepository(from: repoLocalURL, to: workspaceDir)

        var warnings: [String] = []

        let branchName = "workspace/\(sanitizedName)"
        await progress?(.creatingBranch)
        do {
            try await gitService.createBranch(branchName, at: workspaceDir)
        } catch {
            let msg = "Could not create branch '\(branchName)': \(error)"
            log.warning("\(msg)")
            warnings.append(msg)
        }

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

        // Channel 5: optional headless `claude -p` warm-up. Driven by
        // `.workspaces/claude-setup.json` (per-project) or
        // `Resources/Defaults/claude-setup.json` (app default). Failures here
        // never fail workspace creation — we log + continue.
        await runClaudeWarmupIfConfigured(in: workspaceDir)

        await progress?(.finished)

        return NewWorkspaceInfo(
            name: name,
            path: workspaceDir,
            gitBranch: currentBranch ?? branchName,
            warnings: warnings
        )
    }

    // MARK: - Copy Repository

    private func copyRepository(from source: URL, to destination: URL) async throws {
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/ditto",
            arguments: ["--rsrc", source.path, destination.path]
        )

        guard result.success else {
            let reason = result.stderr.isEmpty ? "Unknown error" : result.stderr
            throw WorkspaceError.copyFailed(reason: reason)
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
            try FileManager.default.removeItem(at: workspaceURL)

            let parentDir = workspaceURL.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: parentDir.path),
                contents.isEmpty
            {
                try? FileManager.default.removeItem(at: parentDir)
            }
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

    // MARK: - Claude Warm-up (Channel 5)

    /// Runs the optional Channel-5 `claude -p` warm-up if a config is found
    /// for the workspace. Internal — exposed indirectly through
    /// `createWorkspace`. Never throws: the warm-up is best-effort.
    func runClaudeWarmupIfConfigured(in workspaceDir: URL) async {
        guard let factory = claudeRunnerFactory else { return }
        guard let config = WorkspaceClaudeSetup.loadConfig(for: workspaceDir) else { return }

        let runner = factory()
        log.info(
            "running headless claude warm-up in \(workspaceDir.path, privacy: .public)"
        )
        _ = await WorkspaceClaudeSetup.runWarmup(
            config: config,
            in: workspaceDir,
            runner: runner,
            eventSink: { event in
                if case .textDelta = event { return }  // log noise
                if case .unknown = event { return }
                log.info("headless event: \(String(describing: event), privacy: .public)")
            }
        )
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
    case copyFailed(reason: String)
    case deletionFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .notAGitRepo:
            return "The selected folder is not a git repository"
        case .alreadyExists(let name):
            return "A workspace named '\(name)' already exists"
        case .invalidName(let name):
            return "Workspace name '\(name)' is not valid"
        case .copyFailed(let reason):
            return "Failed to copy repository: \(reason)"
        case .deletionFailed(let reason):
            return "Failed to delete workspace: \(reason)"
        }
    }
}
