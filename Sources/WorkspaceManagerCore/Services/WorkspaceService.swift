//
//  WorkspaceService.swift
//  WorkspaceManager
//
//  Workspace creation, lifecycle hooks, and management
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "WorkspaceService")

struct WorkspaceCleanupFailure: Sendable, Equatable {
    let context: String
    let targetPath: String
    let errorDescription: String
}

private let defaultCleanupFailureReporter: @Sendable (WorkspaceCleanupFailure) -> Void = { failure in
    log.warning(
        "Failed best-effort workspace cleanup after \(failure.context) at \(failure.targetPath): \(failure.errorDescription)"
    )
}

public actor WorkspaceService: WorkspaceServiceProtocol {
    public static let shared = WorkspaceService()

    private let materializer: any WorkspaceMaterializer
    private let cleanupFailureReporter: @Sendable (WorkspaceCleanupFailure) -> Void

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
        self.init(materializer: GitWorktreeWorkspaceMaterializer(gitService: gitService))
    }

    init(
        materializer: any WorkspaceMaterializer,
        cleanupFailureReporter: @escaping @Sendable (WorkspaceCleanupFailure) -> Void = defaultCleanupFailureReporter
    ) {
        self.materializer = materializer
        self.cleanupFailureReporter = cleanupFailureReporter
        Self.ensureDefaultWorkspacesRootExists()
    }

    private static func ensureDefaultWorkspacesRootExists() {
        do {
            try FileManager.default.createDirectory(
                at: defaultWorkspacesRoot,
                withIntermediateDirectories: true
            )
        } catch {
            log.warning(
                "Failed to create default workspaces root at \(defaultWorkspacesRoot.path): \(error.localizedDescription)"
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

        await progress?(.creatingWorktree)
        let materializedWorkspace: MaterializedWorkspace
        do {
            materializedWorkspace = try await materializer.materializeWorkspace(
                named: sanitizedName,
                at: workspaceDir,
                from: repoLocalURL
            )
        } catch {
            await cleanupMaterializedWorkspace(at: workspaceDir, context: "materialization failure")
            throw WorkspaceError.materializationFailed(
                operation: materializer.failureOperationDescription,
                reason: error.localizedDescription
            )
        }
        guard FileManager.default.fileExists(atPath: workspaceDir.path) else {
            await cleanupMaterializedWorkspace(at: workspaceDir, context: "missing workspace directory")
            throw WorkspaceError.materializationFailed(
                operation: materializer.failureOperationDescription,
                reason: "Materializer did not create workspace directory at \(workspaceDir.path)"
            )
        }

        do {
            await progress?(.runningSetupScript)
            let setupRun = try await runLifecycleAction(.setup, in: workspaceDir)
            if !setupRun.result.stdout.isEmpty {
                log.info("\(setupRun.scriptName ?? "setup") output: \(setupRun.result.stdout)")
            }
            if setupRun.result.exitCode != 0 {
                let scriptName = setupRun.scriptName ?? "setup"
                let msg = "\(scriptName) exited with code \(setupRun.result.exitCode): \(setupRun.result.stderr)"
                log.warning("\(msg)")
                warnings.append(msg)
            }

            await progress?(.finished)

            return NewWorkspaceInfo(
                name: name,
                path: workspaceDir,
                gitBranch: materializedWorkspace.gitBranch,
                warnings: warnings
            )
        } catch {
            await cleanupMaterializedWorkspace(at: workspaceDir, context: "setup lifecycle failure")
            throw error
        }
    }

    private func cleanupMaterializedWorkspace(at workspaceURL: URL, context: String) async {
        do {
            try await materializer.removeWorkspace(at: workspaceURL)
        } catch {
            cleanupFailureReporter(
                WorkspaceCleanupFailure(
                    context: context,
                    targetPath: workspaceURL.path,
                    errorDescription: error.localizedDescription
                )
            )
        }
    }

    // MARK: - Archive Workspace

    public func archiveWorkspace(at workspaceURL: URL) async throws {
        try await runTeardownLifecycle(in: workspaceURL)
    }

    // MARK: - Delete Workspace

    public func deleteWorkspace(at workspaceURL: URL, deleteFiles: Bool) async throws {
        try await runTeardownLifecycle(in: workspaceURL)

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
        return try await runLifecycleScript(at: scriptPath, in: directory)
    }

    private struct LifecycleScriptRun: Sendable {
        let scriptName: String?
        let result: ScriptResult
    }

    private enum LifecycleScriptAction: String, Sendable {
        case setup
        case stop
        case archive

        var legacyScriptName: String? {
            switch self {
            case .setup:
                return "setup.sh"
            case .stop:
                return nil
            case .archive:
                return "archive.sh"
            }
        }

        var candidateScriptNames: [String] {
            var candidates = [
                "scripts/\(rawValue)",
                "scripts/\(rawValue).sh",
            ]
            if let legacyScriptName {
                candidates.append(legacyScriptName)
            }
            return candidates
        }
    }

    private func runLifecycleAction(
        _ action: LifecycleScriptAction,
        in directory: URL
    ) async throws -> LifecycleScriptRun {
        for scriptName in action.candidateScriptNames {
            let scriptPath = directory.appendingPathComponent(scriptName)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: scriptPath.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else {
                continue
            }

            let result = try await runLifecycleScript(at: scriptPath, in: directory)
            return LifecycleScriptRun(scriptName: scriptName, result: result)
        }

        return LifecycleScriptRun(
            scriptName: nil,
            result: ScriptResult(exitCode: 0, stdout: "", stderr: "")
        )
    }

    private func runTeardownLifecycle(in directory: URL) async throws {
        for action in [LifecycleScriptAction.stop, .archive] {
            let run = try await runLifecycleAction(action, in: directory)
            guard let scriptName = run.scriptName else {
                continue
            }
            if !run.result.stdout.isEmpty {
                log.info("\(scriptName) output: \(run.result.stdout)")
            }
            if run.result.exitCode != 0 {
                log.warning("\(scriptName) exited with code \(run.result.exitCode): \(run.result.stderr)")
            }
        }
    }

    private func runLifecycleScript(at scriptPath: URL, in directory: URL) async throws -> ScriptResult {

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
            environment: env,
            timeout: 600
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
    case materializationFailed(operation: String, reason: String)
    case deletionFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .notAGitRepo:
            return "The selected folder is not a git repository"
        case .alreadyExists(let name):
            return "A workspace named '\(name)' already exists"
        case .invalidName(let name):
            return "Workspace name '\(name)' is not valid"
        case .materializationFailed(let operation, let reason):
            return "Failed to \(operation): \(reason)"
        case .deletionFailed(let reason):
            return "Failed to delete workspace: \(reason)"
        }
    }
}
