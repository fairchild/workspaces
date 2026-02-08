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

    public func createWorkspace(repoName: String, repoLocalURL: URL, name: String) async throws -> NewWorkspaceInfo {
        let sanitizedName = sanitizeFilename(name)

        let repoDir = workspacesRoot.appendingPathComponent(repoName, isDirectory: true)
        let workspaceDir = repoDir.appendingPathComponent(sanitizedName, isDirectory: true)

        if FileManager.default.fileExists(atPath: workspaceDir.path) {
            throw WorkspaceError.alreadyExists(name: sanitizedName)
        }

        try FileManager.default.createDirectory(
            at: repoDir,
            withIntermediateDirectories: true
        )

        try await copyRepository(from: repoLocalURL, to: workspaceDir)

        let branchName = "workspace/\(sanitizedName)"
        do {
            try await gitService.createBranch(branchName, at: workspaceDir)
        } catch {
            print("Warning: Could not create branch '\(branchName)': \(error)")
        }

        let currentBranch = try? await gitService.getCurrentBranch(at: workspaceDir)

        let setupResult = try await runLifecycleScript("setup.sh", in: workspaceDir)
        if !setupResult.stdout.isEmpty {
            print("setup.sh output:\n\(setupResult.stdout)")
        }
        if setupResult.exitCode != 0 {
            print("setup.sh warning (exit \(setupResult.exitCode)):\n\(setupResult.stderr)")
        }

        return NewWorkspaceInfo(
            name: name,
            path: workspaceDir,
            gitBranch: currentBranch ?? branchName
        )
    }

    // MARK: - Copy Repository

    private func copyRepository(from source: URL, to destination: URL) async throws {
        try await runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["--rsrc", source.path, destination.path],
            errorMapper: { stderr in WorkspaceError.copyFailed(reason: stderr) }
        )
    }

    // MARK: - Archive Workspace

    public func archiveWorkspace(at workspaceURL: URL) async throws {
        let archiveResult = try await runLifecycleScript("archive.sh", in: workspaceURL)
        if !archiveResult.stdout.isEmpty {
            print("archive.sh output:\n\(archiveResult.stdout)")
        }
        if archiveResult.exitCode != 0 {
            print("archive.sh warning (exit \(archiveResult.exitCode)):\n\(archiveResult.stderr)")
        }
    }

    // MARK: - Delete Workspace

    public func deleteWorkspace(at workspaceURL: URL, deleteFiles: Bool) async throws {
        _ = try await runLifecycleScript("archive.sh", in: workspaceURL)

        if deleteFiles {
            try FileManager.default.removeItem(at: workspaceURL)

            let parentDir = workspaceURL.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: parentDir.path),
               contents.isEmpty {
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

    public func runLifecycleScript(_ scriptName: String, in directory: URL) async throws -> ScriptResult {
        let scriptPath = directory.appendingPathComponent(scriptName)

        guard FileManager.default.fileExists(atPath: scriptPath.path) else {
            return ScriptResult(exitCode: 0, stdout: "", stderr: "")
        }

        // Ensure script is executable
        if let attributes = try? FileManager.default.attributesOfItem(atPath: scriptPath.path),
           let permissions = attributes[.posixPermissions] as? NSNumber {
            let mode = permissions.uint16Value
            if mode & 0o111 == 0 {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: mode | 0o755)],
                    ofItemAtPath: scriptPath.path
                )
            }
        }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath.path]
            process.currentDirectoryURL = directory
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { _ in
                let stdout = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                continuation.resume(returning: ScriptResult(
                    exitCode: process.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Workspace Stats

    public func getWorkspaceSize(at workspaceURL: URL) async throws -> Int64 {
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]

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
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?*\"<>|")
        let sanitized = name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)

        return sanitized
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
    }

    public var root: URL {
        workspacesRoot
    }

    // MARK: - Async Process Execution

    /// Run a process asynchronously using terminationHandler instead of blocking waitUntilExit().
    private func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        errorMapper: @Sendable @escaping (String) -> Error
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let dir = currentDirectory {
                process.currentDirectoryURL = dir
            }

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            process.terminationHandler = { _ in
                if process.terminationStatus != 0 {
                    let stderr = String(
                        data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? "Unknown error"
                    continuation.resume(throwing: errorMapper(stderr))
                } else {
                    continuation.resume()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
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
