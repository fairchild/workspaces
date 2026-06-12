//
//  WorkspaceOrphanReconcilerTests.swift
//  WorkspaceManagerTests
//
//  Coverage for startup reconciliation of workspace records, git worktrees,
//  and Lume workspace VM storage.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

private struct OrphanReconcilerGitCommandError: Error, CustomStringConvertible {
    let args: [String]
    let stderr: String

    var description: String {
        "git \(args.joined(separator: " ")) failed: \(stderr)"
    }
}

@Suite("WorkspaceOrphanReconciler", .serialized)
struct WorkspaceOrphanReconcilerTests {
    final class CountingFileSystem: WorkspaceOrphanFileSystem, @unchecked Sendable {
        private let fileManager = FileManager.default
        private let lock = NSLock()
        private var directoryExistsCallCountStorage = 0

        var directoryExistsCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return directoryExistsCallCountStorage
        }

        func directoryExists(at url: URL) -> Bool {
            lock.lock()
            directoryExistsCallCountStorage += 1
            lock.unlock()

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return false
            }
            return isDirectory.boolValue
        }

        func directoryNames(in url: URL) throws -> [String] {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { return [] }

            return try fileManager.contentsOfDirectory(
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
            try fileManager.removeItem(at: url)
        }
    }

    struct StaticWorktreeLister: WorkspaceOrphanWorktreeListing {
        let entries: [GitWorktreeEntry]

        func worktrees(for repositoryURL: URL) async throws -> [GitWorktreeEntry] {
            entries
        }
    }

    @Test("Detects git worktrees without SwiftData records")
    func detectsGitWorktreesWithoutRecords() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }
        try repo.createFile("README.md", content: "hello\n")
        try repo.commit(message: "initial")

        let testRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let workspacesRoot = testRoot.appendingPathComponent("workspaces", isDirectory: true)
        let worktreeURL =
            workspacesRoot
            .appendingPathComponent("sample-repo", isDirectory: true)
            .appendingPathComponent("orphan-worktree", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktreeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try runGit(
            ["worktree", "add", "-b", "workspace/orphan-worktree", worktreeURL.path, "HEAD"],
            at: repo.url
        )

        let reconciler = WorkspaceOrphanReconciler(
            workspacesRoot: workspacesRoot,
            lumeWorkspaceStorageURL: nil
        )
        let result = await reconciler.scan(
            repositories: [
                repoSnapshot(
                    name: "sample-repo",
                    localPath: repo.url.path,
                    workspaces: []
                )
            ]
        )

        let item = try #require(result.items.first)
        #expect(result.items.count == 1)
        #expect(item.kind == .gitWorktreeWithoutRecord)
        #expect(item.resourceName == "orphan-worktree")
        #expect(item.gitBranch == "workspace/orphan-worktree")
    }

    @Test("Detects workspace records whose directory no longer exists")
    func detectsWorkspaceRecordsWithoutDirectories() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }
        try repo.createFile("README.md", content: "hello\n")
        try repo.commit(message: "initial")

        let testRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let workspacesRoot = testRoot.appendingPathComponent("workspaces", isDirectory: true)
        let worktreeURL =
            workspacesRoot
            .appendingPathComponent("sample-repo", isDirectory: true)
            .appendingPathComponent("missing-directory", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktreeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try runGit(
            ["worktree", "add", "-b", "workspace/missing-directory", worktreeURL.path, "HEAD"],
            at: repo.url
        )
        try FileManager.default.removeItem(at: worktreeURL)

        let workspace = workspaceSnapshot(
            name: "missing-directory",
            path: worktreeURL.path,
            gitBranch: "workspace/missing-directory"
        )
        let reconciler = WorkspaceOrphanReconciler(
            workspacesRoot: workspacesRoot,
            lumeWorkspaceStorageURL: nil
        )
        let result = await reconciler.scan(
            repositories: [
                repoSnapshot(
                    name: "sample-repo",
                    localPath: repo.url.path,
                    workspaces: [workspace]
                )
            ]
        )

        let item = try #require(result.items.first)
        #expect(result.items.count == 1)
        #expect(item.kind == .workspaceRecordMissingDirectory)
        #expect(item.workspaceID == workspace.id)
        #expect(item.hasPrunableGitMetadata)
    }

    @Test("Detects Lume workspace VMs without workspace records")
    func detectsLumeVMsWithoutWorkspaceRecords() async throws {
        let testRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let workspacesRoot = testRoot.appendingPathComponent("workspaces", isDirectory: true)
        let vmStorageURL =
            testRoot
            .appendingPathComponent("LumeStorage", isDirectory: true)
            .appendingPathComponent("workspace-vms", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vmStorageURL.appendingPathComponent("recorded-vm", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: vmStorageURL.appendingPathComponent("orphan-vm", isDirectory: true),
            withIntermediateDirectories: true
        )
        let workspaceDirectory =
            workspacesRoot
            .appendingPathComponent("sample-repo", isDirectory: true)
            .appendingPathComponent("vm", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)

        let metadata = LumeWorkspaceMetadata(
            vmName: "recorded-vm",
            storagePath: vmStorageURL.path,
            guestOS: .linux,
            sharedHostPath: workspaceDirectory.path
        )
        let metadataRaw = String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? ""
        let workspace = workspaceSnapshot(
            name: "vm",
            path: workspaceDirectory.path,
            backendIdentifier: LumeWorkspaceProvider.identifier,
            remoteId: "recorded-vm",
            backendMetadataRaw: metadataRaw
        )
        let reconciler = WorkspaceOrphanReconciler(
            workspacesRoot: workspacesRoot,
            lumeWorkspaceStorageURL: vmStorageURL,
            worktreeLister: StaticWorktreeLister(entries: []),
            fileSystem: DefaultWorkspaceOrphanFileSystem()
        )

        let result = await reconciler.scan(
            repositories: [
                repoSnapshot(
                    name: "sample-repo",
                    localPath: testRoot.appendingPathComponent("repo", isDirectory: true).path,
                    workspaces: [workspace]
                )
            ]
        )

        let item = try #require(result.items.first)
        #expect(result.items.count == 1)
        #expect(item.kind == .lumeVMWithoutWorkspace)
        #expect(item.resourceName == "orphan-vm")
    }

    @Test("Does not mark legacy Lume metadata without storage path as orphaned")
    func skipsLegacyLumeMetadataWithoutStoragePath() async throws {
        let testRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let workspacesRoot = testRoot.appendingPathComponent("workspaces", isDirectory: true)
        let vmStorageURL =
            testRoot
            .appendingPathComponent("LumeStorage", isDirectory: true)
            .appendingPathComponent("workspace-vms", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vmStorageURL.appendingPathComponent("legacy-vm", isDirectory: true),
            withIntermediateDirectories: true
        )

        let metadata = LumeWorkspaceMetadata(
            vmName: "legacy-vm",
            guestOS: .linux,
            sharedHostPath: "/tmp/legacy-vm"
        )
        let metadataRaw = String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? ""
        let workspace = workspaceSnapshot(
            name: "legacy-vm",
            path: Workspace.remotePathSentinel,
            backendIdentifier: LumeWorkspaceProvider.identifier,
            remoteId: "legacy-vm",
            backendMetadataRaw: metadataRaw,
            usesHostWorkspaceFiles: false
        )
        let reconciler = WorkspaceOrphanReconciler(
            workspacesRoot: workspacesRoot,
            lumeWorkspaceStorageURL: vmStorageURL,
            worktreeLister: StaticWorktreeLister(entries: []),
            fileSystem: DefaultWorkspaceOrphanFileSystem()
        )

        let result = await reconciler.scan(
            repositories: [
                repoSnapshot(
                    name: "sample-repo",
                    localPath: testRoot.appendingPathComponent("repo", isDirectory: true).path,
                    workspaces: [workspace]
                )
            ]
        )

        #expect(result.items.isEmpty)
    }

    @Test("Skips directory existence checks when live worktree and record paths match")
    func skipsDirectoryChecksWhenCountsAndPathsMatch() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }
        try repo.createFile("README.md", content: "hello\n")
        try repo.commit(message: "initial")

        let testRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let workspacesRoot = testRoot.appendingPathComponent("workspaces", isDirectory: true)
        let worktreeURL =
            workspacesRoot
            .appendingPathComponent("sample-repo", isDirectory: true)
            .appendingPathComponent("known-worktree", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktreeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try runGit(
            ["worktree", "add", "-b", "workspace/known-worktree", worktreeURL.path, "HEAD"],
            at: repo.url
        )

        let fileSystem = CountingFileSystem()
        let reconciler = WorkspaceOrphanReconciler(
            workspacesRoot: workspacesRoot,
            lumeWorkspaceStorageURL: nil,
            worktreeLister: GitPorcelainWorktreeLister(),
            fileSystem: fileSystem
        )
        let result = await reconciler.scan(
            repositories: [
                repoSnapshot(
                    name: "sample-repo",
                    localPath: repo.url.path,
                    workspaces: [
                        workspaceSnapshot(
                            name: "known-worktree",
                            path: worktreeURL.path,
                            gitBranch: "workspace/known-worktree"
                        )
                    ]
                )
            ]
        )

        #expect(result.items.isEmpty)
        #expect(fileSystem.directoryExistsCallCount == 0)
    }

    @Test("Archived workspace under .archived produces no orphan items")
    func archivedWorkspaceProducesNoOrphans() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }
        try repo.createFile("README.md", content: "hello\n")
        try repo.commit(message: "initial")

        let testRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let workspacesRoot = testRoot.appendingPathComponent("workspaces", isDirectory: true)
        let worktreeURL =
            workspacesRoot
            .appendingPathComponent("sample-repo", isDirectory: true)
            .appendingPathComponent("to-archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktreeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try runGit(
            ["worktree", "add", "-b", "workspace/to-archive", worktreeURL.path, "HEAD"],
            at: repo.url
        )

        // Archive moves the worktree into <workspacesRoot>/.archived/sample-repo/to-archive.
        let archivedURL = WorkspaceDirectoryArchiver.archivedDestination(for: worktreeURL)
        try await WorkspaceDirectoryArchiver.move(from: worktreeURL, to: archivedURL)

        let workspace = workspaceSnapshot(
            name: "to-archive",
            path: archivedURL.path,
            gitBranch: "workspace/to-archive"
        )
        let reconciler = WorkspaceOrphanReconciler(
            workspacesRoot: workspacesRoot,
            lumeWorkspaceStorageURL: nil
        )
        let result = await reconciler.scan(
            repositories: [
                repoSnapshot(
                    name: "sample-repo",
                    localPath: repo.url.path,
                    workspaces: [workspace]
                )
            ]
        )

        #expect(result.items.isEmpty)
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceOrphanReconcilerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func repoSnapshot(
        id: UUID = UUID(),
        name: String,
        localPath: String,
        workspaces: [WorkspaceOrphanWorkspaceSnapshot]
    ) -> WorkspaceOrphanRepositorySnapshot {
        WorkspaceOrphanRepositorySnapshot(
            id: id,
            name: name,
            localPath: localPath,
            workspaces: workspaces
        )
    }

    private func workspaceSnapshot(
        id: UUID = UUID(),
        name: String,
        path: String,
        gitBranch: String? = nil,
        backendIdentifier: String = "local",
        remoteId: String? = nil,
        backendMetadataRaw: String = "",
        usesHostWorkspaceFiles: Bool = true
    ) -> WorkspaceOrphanWorkspaceSnapshot {
        WorkspaceOrphanWorkspaceSnapshot(
            id: id,
            name: name,
            path: path,
            gitBranch: gitBranch,
            backendIdentifier: backendIdentifier,
            remoteId: remoteId,
            backendMetadataRaw: backendMetadataRaw,
            usesHostWorkspaceFiles: usesHostWorkspaceFiles
        )
    }

    private func runGit(_ args: [String], at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output =
            String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        let errorOutput =
            String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""

        guard process.terminationStatus == 0 else {
            throw OrphanReconcilerGitCommandError(args: args, stderr: errorOutput)
        }

        return output
    }
}
