//
//  WorkspaceOrphanReconciler.swift
//  WorkspaceManagerCore
//
//  Detects leftover workspace resources whose persisted records and host
//  resources have drifted apart after interrupted creation or cleanup.
//

import Foundation
import os.log

private let workspaceOrphanLog = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "WorkspaceOrphanReconciler"
)

public enum WorkspaceOrphanKind: String, Sendable, Codable {
    case gitWorktreeWithoutRecord
    case workspaceRecordMissingDirectory
    case lumeVMWithoutWorkspace
}

public struct WorkspaceOrphanWorkspaceSnapshot: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let path: String
    public let gitBranch: String?
    public let backendIdentifier: String
    public let remoteId: String?
    public let backendMetadataRaw: String
    public let usesHostWorkspaceFiles: Bool

    public init(
        id: UUID,
        name: String,
        path: String,
        gitBranch: String?,
        backendIdentifier: String,
        remoteId: String?,
        backendMetadataRaw: String,
        usesHostWorkspaceFiles: Bool
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.gitBranch = gitBranch
        self.backendIdentifier = backendIdentifier
        self.remoteId = remoteId
        self.backendMetadataRaw = backendMetadataRaw
        self.usesHostWorkspaceFiles = usesHostWorkspaceFiles
    }
}

public struct WorkspaceOrphanRepositorySnapshot: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let localPath: String
    public let workspaces: [WorkspaceOrphanWorkspaceSnapshot]

    public init(
        id: UUID,
        name: String,
        localPath: String,
        workspaces: [WorkspaceOrphanWorkspaceSnapshot]
    ) {
        self.id = id
        self.name = name
        self.localPath = localPath
        self.workspaces = workspaces
    }

    public var localURL: URL {
        URL(fileURLWithPath: localPath, isDirectory: true)
    }
}

public struct WorkspaceOrphanItem: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let kind: WorkspaceOrphanKind
    public let repoID: UUID?
    public let repoName: String?
    public let repoLocalPath: String?
    public let workspaceID: UUID?
    public let workspaceName: String?
    public let resourceName: String
    public let path: String?
    public let storagePath: String?
    public let gitBranch: String?
    public let hasPrunableGitMetadata: Bool

    /// Memberwise construction for callers outside this module — the UI-fixture seam
    /// (synthetic banner items) and tests. Scan results keep using the static factories.
    public init(
        id: String,
        kind: WorkspaceOrphanKind,
        repoID: UUID?,
        repoName: String?,
        repoLocalPath: String?,
        workspaceID: UUID?,
        workspaceName: String?,
        resourceName: String,
        path: String?,
        storagePath: String?,
        gitBranch: String?,
        hasPrunableGitMetadata: Bool
    ) {
        self.id = id
        self.kind = kind
        self.repoID = repoID
        self.repoName = repoName
        self.repoLocalPath = repoLocalPath
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.resourceName = resourceName
        self.path = path
        self.storagePath = storagePath
        self.gitBranch = gitBranch
        self.hasPrunableGitMetadata = hasPrunableGitMetadata
    }

    public var pathURL: URL? {
        path.map { URL(fileURLWithPath: $0) }
    }

    public var repoLocalURL: URL? {
        repoLocalPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func lumeCleanupTarget() -> WorkspaceProviderTarget? {
        guard kind == .lumeVMWithoutWorkspace,
            let storagePath
        else { return nil }

        let metadata = LumeWorkspaceMetadata(
            vmName: resourceName,
            storagePath: storagePath,
            guestOS: .linux,
            sharedHostPath: ""
        )
        guard let data = try? JSONEncoder().encode(metadata),
            let rawMetadata = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return WorkspaceProviderTarget(
            id: UUID(),
            name: resourceName,
            path: Workspace.remotePathSentinel,
            gitBranch: nil,
            status: .archived,
            backendIdentifier: LumeWorkspaceProvider.identifier,
            remoteId: resourceName,
            sessionRoutingID: nil,
            backendMetadataRaw: rawMetadata
        )
    }

    static func gitWorktreeWithoutRecord(
        repo: WorkspaceOrphanRepositorySnapshot,
        entry: GitWorktreeEntry
    ) -> WorkspaceOrphanItem {
        let normalizedPath = normalizePath(entry.path)
        return WorkspaceOrphanItem(
            id: "git:\(repo.id.uuidString):\(normalizedPath)",
            kind: .gitWorktreeWithoutRecord,
            repoID: repo.id,
            repoName: repo.name,
            repoLocalPath: repo.localPath,
            workspaceID: nil,
            workspaceName: nil,
            resourceName: URL(fileURLWithPath: normalizedPath).lastPathComponent,
            path: normalizedPath,
            storagePath: nil,
            gitBranch: entry.branch,
            hasPrunableGitMetadata: entry.isPrunable
        )
    }

    static func workspaceRecordMissingDirectory(
        repo: WorkspaceOrphanRepositorySnapshot,
        workspace: WorkspaceOrphanWorkspaceSnapshot,
        prunableEntry: GitWorktreeEntry?
    ) -> WorkspaceOrphanItem {
        let normalizedPath = normalizePath(workspace.path)
        return WorkspaceOrphanItem(
            id: "record:\(workspace.id.uuidString):\(normalizedPath)",
            kind: .workspaceRecordMissingDirectory,
            repoID: repo.id,
            repoName: repo.name,
            repoLocalPath: repo.localPath,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            resourceName: workspace.name,
            path: normalizedPath,
            storagePath: nil,
            gitBranch: prunableEntry?.branch ?? workspace.gitBranch,
            hasPrunableGitMetadata: prunableEntry != nil
        )
    }

    static func lumeVMWithoutWorkspace(
        vmName: String,
        vmDirectory: URL,
        storageURL: URL
    ) -> WorkspaceOrphanItem {
        let normalizedPath = normalizePath(vmDirectory.path)
        return WorkspaceOrphanItem(
            id: "lume:\(normalizePath(storageURL.path)):\(vmName)",
            kind: .lumeVMWithoutWorkspace,
            repoID: nil,
            repoName: nil,
            repoLocalPath: nil,
            workspaceID: nil,
            workspaceName: nil,
            resourceName: vmName,
            path: normalizedPath,
            storagePath: normalizePath(storageURL.path),
            gitBranch: nil,
            hasPrunableGitMetadata: false
        )
    }
}

public struct WorkspaceOrphanScanResult: Sendable, Equatable {
    public let items: [WorkspaceOrphanItem]

    public init(items: [WorkspaceOrphanItem]) {
        self.items = items
    }
}

public enum WorkspaceOrphanReconciliationError: LocalizedError, Equatable {
    case unsupportedCleanupItem
    case gitCommandFailed(args: [String], stderr: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedCleanupItem:
            return "This cleanup item does not contain enough information to clean safely."
        case .gitCommandFailed(let args, let stderr):
            return "git \(args.joined(separator: " ")) failed: \(stderr)"
        }
    }
}

public struct WorkspaceOrphanReconciler: Sendable {
    private let workspacesRoot: URL
    private let lumeWorkspaceStorageURL: URL?
    private let worktreeLister: any WorkspaceOrphanWorktreeListing
    private let fileSystem: any WorkspaceOrphanFileSystem

    public init(
        workspacesRoot: URL,
        lumeWorkspaceStorageURL: URL?
    ) {
        self.init(
            workspacesRoot: workspacesRoot,
            lumeWorkspaceStorageURL: lumeWorkspaceStorageURL,
            worktreeLister: GitPorcelainWorktreeLister(),
            fileSystem: DefaultWorkspaceOrphanFileSystem()
        )
    }

    init(
        workspacesRoot: URL,
        lumeWorkspaceStorageURL: URL?,
        worktreeLister: any WorkspaceOrphanWorktreeListing,
        fileSystem: any WorkspaceOrphanFileSystem
    ) {
        self.workspacesRoot = workspacesRoot
        self.lumeWorkspaceStorageURL = lumeWorkspaceStorageURL
        self.worktreeLister = worktreeLister
        self.fileSystem = fileSystem
    }

    public func scan(
        repositories: [WorkspaceOrphanRepositorySnapshot]
    ) async -> WorkspaceOrphanScanResult {
        var items: [WorkspaceOrphanItem] = []

        for repository in repositories {
            do {
                items.append(contentsOf: try await scan(repository: repository))
            } catch {
                workspaceOrphanLog.warning(
                    "Failed to scan workspace orphans for \(repository.name): \(error.localizedDescription)"
                )
            }
        }

        do {
            items.append(contentsOf: try scanLumeVMs(repositories: repositories))
        } catch {
            workspaceOrphanLog.warning(
                "Failed to scan Lume workspace VM orphans: \(error.localizedDescription)"
            )
        }

        return WorkspaceOrphanScanResult(
            items: items.sorted { lhs, rhs in
                if lhs.kind.rawValue != rhs.kind.rawValue {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                return lhs.resourceName.localizedCaseInsensitiveCompare(rhs.resourceName) == .orderedAscending
            }
        )
    }

    public func cleanupGitWorktree(_ item: WorkspaceOrphanItem) async throws {
        guard let path = item.path,
            let repoLocalURL = item.repoLocalURL,
            item.kind == .gitWorktreeWithoutRecord || item.hasPrunableGitMetadata
        else {
            throw WorkspaceOrphanReconciliationError.unsupportedCleanupItem
        }

        let arguments = ["worktree", "remove", "--force", path]
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectory: repoLocalURL
        )
        guard result.success else {
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkspaceOrphanReconciliationError.gitCommandFailed(
                args: arguments,
                stderr: reason.isEmpty ? "Unknown error" : reason
            )
        }

        if let branch = item.gitBranch, branch.hasPrefix("workspace/") {
            await deleteWorkspaceBranchBestEffort(branch, at: repoLocalURL)
        }

        cleanupEmptyParent(of: URL(fileURLWithPath: path))
    }

    private func scan(
        repository: WorkspaceOrphanRepositorySnapshot
    ) async throws -> [WorkspaceOrphanItem] {
        let entries = try await worktreeLister.worktrees(for: repository.localURL)
        let workspaceRoot = workspacesRoot.appendingPathComponent(repository.name, isDirectory: true)
        let normalizedWorkspaceRoot = normalizePath(workspaceRoot.path)
        let relevantEntries = entries.filter {
            isPath(normalizePath($0.path), inside: normalizedWorkspaceRoot)
        }

        let liveEntries = relevantEntries.filter { !$0.isPrunable }
        let prunableEntries = relevantEntries.filter(\.isPrunable)
        let liveEntriesByPath = Dictionary(grouping: liveEntries) { normalizePath($0.path) }
        let prunableEntriesByPath = Dictionary(grouping: prunableEntries) { normalizePath($0.path) }
        let liveWorktreePaths = Set(liveEntriesByPath.keys)

        let workspaceRecords = repository.workspaces.filter(\.usesHostWorkspaceFiles)
        let recordedPaths = Set(workspaceRecords.map { normalizePath($0.path) })

        var items: [WorkspaceOrphanItem] = []
        for entry in liveEntries where !recordedPaths.contains(normalizePath(entry.path)) {
            items.append(.gitWorktreeWithoutRecord(repo: repository, entry: entry))
        }
        for entry in prunableEntries where !recordedPaths.contains(normalizePath(entry.path)) {
            items.append(.gitWorktreeWithoutRecord(repo: repository, entry: entry))
        }

        let canSkipDirectoryChecks =
            liveWorktreePaths == recordedPaths
            && prunableEntriesByPath.isEmpty
        guard !canSkipDirectoryChecks else {
            return items
        }

        for workspace in workspaceRecords {
            let normalizedPath = normalizePath(workspace.path)
            guard !fileSystem.directoryExists(at: URL(fileURLWithPath: normalizedPath, isDirectory: true)) else {
                continue
            }

            items.append(
                .workspaceRecordMissingDirectory(
                    repo: repository,
                    workspace: workspace,
                    prunableEntry: prunableEntriesByPath[normalizedPath]?.first
                )
            )
        }

        return items
    }

    private func scanLumeVMs(
        repositories: [WorkspaceOrphanRepositorySnapshot]
    ) throws -> [WorkspaceOrphanItem] {
        guard let storageURL = lumeWorkspaceStorageURL else { return [] }

        let storagePath = normalizePath(storageURL.path)
        let recordedVMNames = Set(
            repositories.flatMap(\.workspaces)
                .filter { $0.backendIdentifier == LumeWorkspaceProvider.identifier }
                .flatMap { workspace -> [String] in
                    lumeVMNames(for: workspace, expectedStoragePath: storagePath)
                }
        )

        let vmNames = try fileSystem.directoryNames(in: storageURL)
        return
            vmNames
            .filter { !recordedVMNames.contains($0) }
            .map { vmName in
                WorkspaceOrphanItem.lumeVMWithoutWorkspace(
                    vmName: vmName,
                    vmDirectory: storageURL.appendingPathComponent(vmName, isDirectory: true),
                    storageURL: storageURL
                )
            }
    }

    private func lumeVMNames(
        for workspace: WorkspaceOrphanWorkspaceSnapshot,
        expectedStoragePath: String
    ) -> [String] {
        var names: [String] = []
        if let metadata = decodeLumeMetadata(workspace.backendMetadataRaw) {
            if let storagePath = metadata.storagePath {
                if normalizePath(storagePath) == expectedStoragePath {
                    names.append(metadata.vmName)
                }
            } else {
                names.append(metadata.vmName)
            }
        } else if let remoteId = workspace.remoteId?.trimmedNonEmpty {
            names.append(remoteId)
        }
        return names
    }

    private func decodeLumeMetadata(_ rawValue: String) -> LumeWorkspaceMetadata? {
        guard let data = rawValue.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LumeWorkspaceMetadata.self, from: data)
    }

    private func deleteWorkspaceBranchBestEffort(_ branch: String, at repoURL: URL) async {
        do {
            let result = try await ProcessRunner.run(
                executable: "/usr/bin/git",
                arguments: ["branch", "-D", branch],
                currentDirectory: repoURL
            )
            if !result.success {
                let reason = result.stderr.isEmpty ? "Unknown error" : result.stderr
                workspaceOrphanLog.warning(
                    "Failed best-effort workspace branch cleanup for \(branch) at \(repoURL.path): \(reason)"
                )
            }
        } catch {
            workspaceOrphanLog.warning(
                "Failed best-effort workspace branch cleanup for \(branch) at \(repoURL.path): \(error.localizedDescription)"
            )
        }
    }

    private func cleanupEmptyParent(of workspaceURL: URL) {
        let parentURL = workspaceURL.deletingLastPathComponent()
        do {
            guard fileSystem.directoryExists(at: parentURL) else { return }
            if try fileSystem.directoryNames(in: parentURL).isEmpty {
                try fileSystem.removeItem(at: parentURL)
            }
        } catch {
            workspaceOrphanLog.warning(
                "Failed best-effort empty parent cleanup at \(parentURL.path): \(error.localizedDescription)"
            )
        }
    }
}

protocol WorkspaceOrphanWorktreeListing: Sendable {
    func worktrees(for repositoryURL: URL) async throws -> [GitWorktreeEntry]
}

struct GitPorcelainWorktreeLister: WorkspaceOrphanWorktreeListing {
    func worktrees(for repositoryURL: URL) async throws -> [GitWorktreeEntry] {
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["worktree", "list", "--porcelain"],
            currentDirectory: repositoryURL
        )
        guard result.success else {
            let reason = result.stderr.isEmpty ? "Unknown error" : result.stderr
            throw WorkspaceOrphanReconciliationError.gitCommandFailed(
                args: ["worktree", "list", "--porcelain"],
                stderr: reason
            )
        }
        return GitWorktreeEntry.parsePorcelain(result.stdout)
    }
}

protocol WorkspaceOrphanFileSystem: Sendable {
    func directoryExists(at url: URL) -> Bool
    func directoryNames(in url: URL) throws -> [String]
    func removeItem(at url: URL) throws
}

struct DefaultWorkspaceOrphanFileSystem: WorkspaceOrphanFileSystem {
    func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    func directoryNames(in url: URL) throws -> [String] {
        guard directoryExists(at: url) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .compactMap { childURL -> String? in
            let values = try childURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }
            return childURL.lastPathComponent
        }
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

struct GitWorktreeEntry: Sendable, Equatable {
    let path: String
    let branch: String?
    let isPrunable: Bool

    static func parsePorcelain(_ output: String) -> [GitWorktreeEntry] {
        var entries: [GitWorktreeEntry] = []
        var currentPath: String?
        var currentBranch: String?
        var isPrunable = false

        func finishEntry() {
            guard let currentPath else { return }
            entries.append(
                GitWorktreeEntry(
                    path: currentPath,
                    branch: currentBranch,
                    isPrunable: isPrunable
                )
            )
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty {
                finishEntry()
                currentPath = nil
                currentBranch = nil
                isPrunable = false
                continue
            }

            if let path = line.dropPrefix("worktree ") {
                if currentPath != nil {
                    finishEntry()
                }
                currentPath = path
                currentBranch = nil
                isPrunable = false
            } else if let branchRef = line.dropPrefix("branch refs/heads/") {
                currentBranch = branchRef
            } else if line.hasPrefix("prunable") {
                isPrunable = true
            }
        }

        finishEntry()
        return entries
    }
}

private func normalizePath(_ path: String) -> String {
    let resolved = URL(fileURLWithPath: path)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
    if resolved == "/var" {
        return "/private/var"
    }
    if resolved.hasPrefix("/var/") {
        return "/private\(resolved)"
    }
    if resolved == "/tmp" {
        return "/private/tmp"
    }
    if resolved.hasPrefix("/tmp/") {
        return "/private\(resolved)"
    }
    return resolved
}

private func isPath(_ path: String, inside directoryPath: String) -> Bool {
    path.hasPrefix(directoryPath + "/")
}

extension String {
    fileprivate var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    fileprivate func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
