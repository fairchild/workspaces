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

    /// Records every URL the reconciler asks the filesystem about, delegating
    /// to the real filesystem for answers.
    final class RecordingFileSystem: WorkspaceOrphanFileSystem, @unchecked Sendable {
        private let real = DefaultWorkspaceOrphanFileSystem()
        private let lock = NSLock()
        private var touchedPathsStorage: [String] = []

        var touchedPaths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return touchedPathsStorage
        }

        private func record(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            touchedPathsStorage.append(url.path)
        }

        func directoryExists(at url: URL) -> Bool {
            record(url)
            return real.directoryExists(at: url)
        }

        func directoryNames(in url: URL) throws -> [String] {
            record(url)
            return try real.directoryNames(in: url)
        }

        func removeItem(at url: URL) throws {
            record(url)
            try real.removeItem(at: url)
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

    @Test("Scan completes past a hanging git and still reaches later phases")
    func scanCompletesWhenGitHangs() async throws {
        let testRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let workspacesRoot = testRoot.appendingPathComponent("workspaces", isDirectory: true)
        let vmStorageURL = testRoot.appendingPathComponent("workspace-vms", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vmStorageURL.appendingPathComponent("orphan-vm", isDirectory: true),
            withIntermediateDirectories: true
        )
        let hangingGit = try makeHangingGitStub(in: testRoot)

        let reconciler = WorkspaceOrphanReconciler(
            workspacesRoot: workspacesRoot,
            lumeWorkspaceStorageURL: vmStorageURL,
            worktreeLister: GitPorcelainWorktreeLister(executable: hangingGit.path, timeout: 0.5),
            fileSystem: DefaultWorkspaceOrphanFileSystem()
        )

        let start = ContinuousClock.now
        let result = await reconciler.scan(
            repositories: [
                repoSnapshot(name: "sample-repo", localPath: testRoot.path, workspaces: [])
            ]
        )
        let elapsed = ContinuousClock.now - start

        // The hung repo scan expires with a typed warning and the scan still
        // reaches the Lume VM phase instead of wedging at git.
        let item = try #require(result.items.first)
        #expect(result.items.count == 1)
        #expect(item.kind == .lumeVMWithoutWorkspace)
        // The bound scales from this machine's measured launch cost so loaded-CI
        // spawn overhead widens it, while the 25s ceiling keeps it under the
        // stub's 30s sleep — past that the assertion proves nothing.
        let bound = await LaunchBudget.deadline(launches: 1, floor: 5, ceiling: 25)
        #expect(elapsed < .seconds(bound))
    }

    @Test("Cleanup of a hanging git worktree removal throws the typed timeout")
    func cleanupSurfacesTypedTimeoutWhenGitHangs() async throws {
        let testRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let workspacesRoot = testRoot.appendingPathComponent("workspaces", isDirectory: true)
        let hangingGit = try makeHangingGitStub(in: testRoot)

        let repo = repoSnapshot(name: "sample-repo", localPath: testRoot.path, workspaces: [])
        let stuckWorktreePath =
            workspacesRoot
            .appendingPathComponent("sample-repo", isDirectory: true)
            .appendingPathComponent("stuck-worktree", isDirectory: true)
            .path
        let entry = GitWorktreeEntry(path: stuckWorktreePath, branch: nil, isPrunable: false)
        let item = WorkspaceOrphanItem.gitWorktreeWithoutRecord(repo: repo, entry: entry)
        let path = try #require(item.path)

        let reconciler = WorkspaceOrphanReconciler(
            workspacesRoot: workspacesRoot,
            lumeWorkspaceStorageURL: nil,
            worktreeLister: StaticWorktreeLister(entries: []),
            fileSystem: DefaultWorkspaceOrphanFileSystem(),
            gitExecutable: hangingGit.path,
            gitCommandTimeout: 0.5
        )

        let start = ContinuousClock.now
        await #expect(
            throws: WorkspaceOrphanReconciliationError.gitCommandTimedOut(
                args: ["worktree", "remove", "--force", path],
                timeout: 0.5
            )
        ) {
            try await reconciler.cleanupGitWorktree(item)
        }
        let elapsed = ContinuousClock.now - start

        // The bound scales from this machine's measured launch cost so loaded-CI
        // spawn overhead widens it, while the 25s ceiling keeps it under the
        // stub's 30s sleep — past that the assertion proves nothing.
        let bound = await LaunchBudget.deadline(launches: 1, floor: 5, ceiling: 25)
        #expect(elapsed < .seconds(bound))
    }

    private func makeHangingGitStub(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("hanging-git", isDirectory: false)
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url

    @Test("Synthetic root set: the real workspaces root and Lume storage are never statted")
    func syntheticRootNeverStatsRealRoots() async throws {
        let testRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let realRoot = testRoot.appendingPathComponent("real-workspaces", isDirectory: true)
        let syntheticRoot = testRoot.appendingPathComponent("synthetic-root", isDirectory: true)
        let realLumeStorage = testRoot.appendingPathComponent("real-lume/workspace-vms", isDirectory: true)
        let staleWorktreeURL =
            realRoot
            .appendingPathComponent("sample-repo", isDirectory: true)
            .appendingPathComponent("stale-worktree", isDirectory: true)
        for directory in [syntheticRoot, staleWorktreeURL, realLumeStorage.appendingPathComponent("orphan-vm")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Caller "forgets" the boundary and hands the reconciler real host roots
        // carrying residue; the record path points at the real root too.
        let fileSystem = RecordingFileSystem()
        let reconciler = WorkspaceOrphanReconciler(
            workspacesRoot: realRoot,
            lumeWorkspaceStorageURL: realLumeStorage,
            worktreeLister: StaticWorktreeLister(entries: [
                GitWorktreeEntry(path: staleWorktreeURL.path, branch: "workspace/stale", isPrunable: false)
            ]),
            fileSystem: fileSystem,
            environment: [SyntheticRunRoot.environmentKey: syntheticRoot.path]
        )
        let result = await reconciler.scan(
            repositories: [
                repoSnapshot(
                    name: "sample-repo",
                    localPath: testRoot.appendingPathComponent("repo", isDirectory: true).path,
                    workspaces: [
                        workspaceSnapshot(
                            name: "real-record",
                            path: realRoot.appendingPathComponent("sample-repo/real-record").path
                        )
                    ]
                )
            ]
        )

        #expect(result.items.isEmpty)
        let syntheticPrefix = syntheticRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for touched in fileSystem.touchedPaths {
            let normalized = URL(fileURLWithPath: touched).standardizedFileURL.resolvingSymlinksInPath().path
            #expect(
                normalized.hasPrefix(syntheticPrefix),
                "reconciler statted a path outside the synthetic root: \(touched)"
            )
        }
    }

    @Test("Synthetic root set: orphans inside the boundary are still detected")
    func syntheticRootStillScansInsideBoundary() async throws {
        let testRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let syntheticRoot = testRoot.appendingPathComponent("synthetic-root", isDirectory: true)
        let lumeStorage = syntheticRoot.appendingPathComponent("lume/workspace-vms", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lumeStorage.appendingPathComponent("orphan-vm", isDirectory: true),
            withIntermediateDirectories: true
        )
        let missingWorkspaceURL =
            syntheticRoot
            .appendingPathComponent("sample-repo", isDirectory: true)
            .appendingPathComponent("missing-workspace", isDirectory: true)

        let workspace = workspaceSnapshot(
            name: "missing-workspace",
            path: missingWorkspaceURL.path
        )
        let reconciler = WorkspaceOrphanReconciler(
            workspacesRoot: syntheticRoot,
            lumeWorkspaceStorageURL: lumeStorage,
            worktreeLister: StaticWorktreeLister(entries: []),
            fileSystem: DefaultWorkspaceOrphanFileSystem(),
            environment: [SyntheticRunRoot.environmentKey: syntheticRoot.path]
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

        #expect(result.items.count == 2)
        #expect(result.items.contains { $0.kind == .workspaceRecordMissingDirectory && $0.workspaceID == workspace.id })
        #expect(result.items.contains { $0.kind == .lumeVMWithoutWorkspace && $0.resourceName == "orphan-vm" })
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
