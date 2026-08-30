//
//  WorkspaceServiceTests.swift
//  WorkspaceManagerTests
//
//  Tests for WorkspaceService: workspace lifecycle, scripts, sanitization
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("WorkspaceService", .serialized)
struct WorkspaceServiceTests {
    actor PhaseRecorder {
        private var phases: [WorkspaceCreationPhase] = []

        func record(_ phase: WorkspaceCreationPhase) {
            phases.append(phase)
        }

        func snapshot() -> [WorkspaceCreationPhase] {
            phases
        }
    }

    final class CleanupFailureRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var failures: [WorkspaceCleanupFailure] = []

        func record(_ failure: WorkspaceCleanupFailure) {
            lock.lock()
            defer { lock.unlock() }
            failures.append(failure)
        }

        func snapshot() -> [WorkspaceCleanupFailure] {
            lock.lock()
            defer { lock.unlock() }
            return failures
        }
    }

    struct CleanupError: LocalizedError {
        let errorDescription: String? = "cleanup failed"
    }

    final class RecordingWorkspaceMaterializer: WorkspaceMaterializer, @unchecked Sendable {
        var materializeCalls: [(sanitizedName: String, destination: URL, source: URL, fromRef: String?)] = []
        var removeCalls: [URL] = []
        var materializeError: Error?
        var removeError: Error?
        var resultBranch = "workspace/recorded"
        var createsDestination = false

        var failureOperationDescription: String {
            "record workspace materialization"
        }

        func materializeWorkspace(
            named sanitizedName: String,
            at destination: URL,
            from sourceRepository: URL,
            fromRef: String?
        ) async throws -> MaterializedWorkspace {
            materializeCalls.append(
                (
                    sanitizedName: sanitizedName,
                    destination: destination,
                    source: sourceRepository,
                    fromRef: fromRef
                ))
            if createsDestination {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            if let materializeError {
                throw materializeError
            }
            return MaterializedWorkspace(gitBranch: resultBranch)
        }

        func removeWorkspace(at workspaceURL: URL) async throws {
            removeCalls.append(workspaceURL)
            if let removeError {
                throw removeError
            }
            try? await WorkspaceDirectoryRemover.remove(at: workspaceURL)
        }
    }

    // MARK: - Helpers

    /// Creates a temp directory with a fake repo and a separate workspaces root.
    /// Returns (testRoot, repoDir, wsRoot) — caller must defer cleanup of testRoot.
    private func makeWorkspaceFixture() throws -> (testRoot: URL, repoDir: URL, wsRoot: URL) {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSTest-\(UUID().uuidString)")
        let repoDir = testRoot.appendingPathComponent("repos/test-repo")
        let wsRoot = testRoot.appendingPathComponent("workspaces")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repoDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        return (testRoot, repoDir, wsRoot)
    }

    /// Sets UserDefaults workspacesRoot, returns the previous value for restore.
    private func setWorkspacesRoot(_ url: URL) -> String? {
        let key = "workspacesRoot"
        let original = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(url.path, forKey: key)
        return original
    }

    /// Restores UserDefaults workspacesRoot to its previous value.
    private func restoreWorkspacesRoot(_ original: String?) {
        let key = "workspacesRoot"
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceServiceTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeGitWorkspaceFixture() throws -> (testRoot: URL, repoDir: URL, wsRoot: URL) {
        let testRoot = try makeTempDir()
        let repoDir = testRoot.appendingPathComponent("repos/test-repo", isDirectory: true)
        let wsRoot = testRoot.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)

        _ = try runGit(["init"], at: repoDir)
        _ = try runGit(["config", "user.email", "test@example.com"], at: repoDir)
        _ = try runGit(["config", "user.name", "Test User"], at: repoDir)
        try "root file\n".write(to: repoDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try runGit(["add", "-A"], at: repoDir)
        _ = try runGit(["commit", "-m", "initial commit"], at: repoDir)

        return (testRoot, repoDir, wsRoot)
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

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        let errorOutput = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw TestGitCommandError(args: args, stderr: errorOutput)
        }

        return output
    }

    private func branchExists(_ name: String, at directory: URL) throws -> Bool {
        let output = try runGit(["branch", "--list", name], at: directory)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func worktreeList(_ output: String, contains url: URL) -> Bool {
        if output.contains("worktree \(url.path)") {
            return true
        }
        if url.path.hasPrefix("/var/"),
            output.contains("worktree /private\(url.path)")
        {
            return true
        }
        return false
    }

    // MARK: - Workspace Root Configuration Tests

    @Test("workspacesRoot prefers the synthetic run root over the configured root")
    func workspacesRootPrefersSyntheticRoot() async throws {
        let testRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let customRoot = testRoot.appendingPathComponent("custom-root", isDirectory: true)
        let syntheticRoot = testRoot.appendingPathComponent("synthetic-root", isDirectory: true)

        let original = setWorkspacesRoot(customRoot)
        defer { restoreWorkspacesRoot(original) }

        let service = WorkspaceService(
            materializer: RecordingWorkspaceMaterializer(),
            environment: [SyntheticRunRoot.environmentKey: syntheticRoot.path]
        )
        let resolvedRoot = await service.workspacesRoot
        #expect(resolvedRoot.path == syntheticRoot.path)
        // Init creates the synthetic root, not a root outside the boundary.
        #expect(FileManager.default.fileExists(atPath: syntheticRoot.path))
    }

    // MARK: - runLifecycleScript Tests

    @Test("Returns success when script is missing")
    func returnsSuccessWhenScriptMissing() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try await WorkspaceService.shared.runLifecycleScript("nonexistent.sh", in: tempDir)
        #expect(result.success)
        #expect(result.stdout.isEmpty)
    }

    @Test("Executes existing script and captures stdout")
    func executesScriptAndCapturesStdout() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        #!/bin/bash
        echo "Hello from script"
        """.write(to: tempDir.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)

        let result = try await WorkspaceService.shared.runLifecycleScript("test.sh", in: tempDir)
        #expect(result.success)
        #expect(result.stdout.contains("Hello from script"))
    }

    @Test("Captures stderr from script")
    func capturesStderr() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        #!/bin/bash
        echo "Error message" >&2
        """.write(to: tempDir.appendingPathComponent("stderr-test.sh"), atomically: true, encoding: .utf8)

        let result = try await WorkspaceService.shared.runLifecycleScript("stderr-test.sh", in: tempDir)
        #expect(result.success)
        #expect(result.stderr.contains("Error message"))
    }

    @Test("Makes script executable if needed")
    func makesScriptExecutable() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptPath = tempDir.appendingPathComponent("nonexec.sh")
        try """
        #!/bin/bash
        echo "Made executable"
        """.write(to: scriptPath, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: scriptPath.path
        )

        let result = try await WorkspaceService.shared.runLifecycleScript("nonexec.sh", in: tempDir)
        #expect(result.success)
        #expect(result.stdout.contains("Made executable"))
    }

    @Test("Reports non-zero exit code")
    func reportsNonZeroExitCode() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        #!/bin/bash
        exit 42
        """.write(to: tempDir.appendingPathComponent("fail.sh"), atomically: true, encoding: .utf8)

        let result = try await WorkspaceService.shared.runLifecycleScript("fail.sh", in: tempDir)
        #expect(!result.success)
        #expect(result.exitCode == 42)
    }

    // MARK: - sanitizeFilename Tests

    @Test("Replaces invalid characters with hyphens")
    func replacesInvalidChars() async throws {
        let testCases: [(input: String, expected: String)] = [
            ("my:file", "my-file"),
            ("path/name", "path-name"),
            ("back\\slash", "back-slash"),
            ("what?ever", "what-ever"),
            ("star*file", "star-file"),
            ("quote\"file", "quote-file"),
            ("less<greater>", "less-greater-"),
            ("pipe|char", "pipe-char"),
        ]

        for (input, expected) in testCases {
            let result = await WorkspaceService.shared.sanitizeFilename(input)
            #expect(result == expected, "Expected '\(expected)' but got '\(result)' for input '\(input)'")
        }
    }

    @Test("Replaces spaces with hyphens")
    func replacesSpacesWithHyphens() async throws {
        let result = await WorkspaceService.shared.sanitizeFilename("my file name")
        #expect(result == "my-file-name")
    }

    @Test("Converts to lowercase")
    func convertsToLowercase() async throws {
        let result = await WorkspaceService.shared.sanitizeFilename("MyFileName")
        #expect(result == "myfilename")
    }

    @Test("Trims whitespace")
    func trimsWhitespace() async throws {
        let result = await WorkspaceService.shared.sanitizeFilename("  spaced  ")
        #expect(result == "spaced")
    }

    @Test("Handles combined transformations")
    func handlesCombinedTransformations() async throws {
        let result = await WorkspaceService.shared.sanitizeFilename("  My Feature: Add Tests  ")
        #expect(result == "my-feature--add-tests")
    }

    // MARK: - createWorkspace Tests

    @Test("createWorkspace delegates directory creation to the injected materializer")
    func createWorkspaceDelegatesDirectoryCreationToInjectedMaterializer() async throws {
        let materializer = RecordingWorkspaceMaterializer()
        materializer.resultBranch = "workspace/my-feature"
        materializer.createsDestination = true
        let service = WorkspaceService(materializer: materializer)
        let (testRoot, repoDir, wsRoot) = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        _ = try await service.createWorkspace(repoName: "test-repo", repoLocalURL: repoDir, name: "my-feature")

        let workspaceDir =
            wsRoot
            .appendingPathComponent("test-repo", isDirectory: true)
            .appendingPathComponent("my-feature", isDirectory: true)
        #expect(materializer.materializeCalls.count == 1)
        #expect(materializer.materializeCalls[0].sanitizedName == "my-feature")
        #expect(materializer.materializeCalls[0].destination == workspaceDir)
        #expect(materializer.materializeCalls[0].source == repoDir)
    }

    @Test("default materializer creates a git worktree branch")
    func defaultMaterializerCreatesGitWorktreeBranch() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let (testRoot, repoDir, wsRoot) = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        _ = try await service.createWorkspace(repoName: "test-repo", repoLocalURL: repoDir, name: "my-feature")

        let workspaceDir =
            wsRoot
            .appendingPathComponent("test-repo", isDirectory: true)
            .appendingPathComponent("my-feature", isDirectory: true)
        #expect(mockGit.createWorktreeCalls.count == 1)
        #expect(mockGit.createWorktreeCalls[0].branchName == "workspace/my-feature")
        #expect(mockGit.createWorktreeCalls[0].destination == workspaceDir)
        #expect(mockGit.createWorktreeCalls[0].source == repoDir)
        #expect(mockGit.createWorktreeCalls[0].startPoint == nil)
        #expect(mockGit.fetchAllCalls.isEmpty)
    }

    @Test("default materializer fetches and branches from requested ref")
    func defaultMaterializerUsesRequestedRef() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let (testRoot, repoDir, wsRoot) = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        _ = try await service.createWorkspace(
            repoName: "test-repo",
            repoLocalURL: repoDir,
            name: "my-feature",
            fromRef: "origin/main"
        )

        #expect(mockGit.fetchAllCalls == [repoDir])
        #expect(mockGit.createWorktreeCalls.count == 1)
        #expect(mockGit.createWorktreeCalls[0].startPoint == "origin/main")
    }

    @Test("createWorkspace rejects unsafe fromRef values before git")
    func createWorkspaceRejectsUnsafeFromRef() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let (testRoot, repoDir, wsRoot) = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        await #expect(throws: WorkspaceError.self) {
            _ = try await service.createWorkspace(
                repoName: "test-repo",
                repoLocalURL: repoDir,
                name: "my-feature",
                fromRef: "origin/main; rm -rf /"
            )
        }

        #expect(mockGit.fetchAllCalls.isEmpty)
        #expect(mockGit.createWorktreeCalls.isEmpty)
    }

    @Test("sequential race fan-out keeps earlier workspaces when a later one fails")
    func sequentialRaceFanOutFailFast() async throws {
        let materializer = RecordingWorkspaceMaterializer()
        materializer.createsDestination = true
        let service = WorkspaceService(materializer: materializer)
        let (testRoot, repoDir, wsRoot) = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        let plan = RaceGroupPlanner.plan(prompt: "demo race", count: 3, command: "claude")
        var created: [URL] = []
        var failedName: String?
        for (index, name) in plan.workspaceNames.enumerated() {
            if index == 2 {
                materializer.materializeError = GitError.commandFailed(args: ["worktree", "add"], stderr: "boom")
            }
            do {
                let info = try await service.createWorkspace(repoName: "test-repo", repoLocalURL: repoDir, name: name)
                created.append(info.path)
            } catch {
                failedName = name
                break
            }
        }

        #expect(failedName == "race-demo-race-3")
        #expect(created.count == 2)
        for workspaceURL in created {
            #expect(FileManager.default.fileExists(atPath: workspaceURL.path))
        }
        let failedDir =
            wsRoot
            .appendingPathComponent("test-repo", isDirectory: true)
            .appendingPathComponent("race-demo-race-3", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: failedDir.path))
    }

    @Test("createWorkspace fails clearly when materialization fails")
    func createWorkspaceFailsWhenMaterializationFails() async throws {
        let materializer = RecordingWorkspaceMaterializer()
        materializer.createsDestination = true
        materializer.materializeError = GitError.commandFailed(args: ["worktree", "add"], stderr: "already exists")
        let service = WorkspaceService(materializer: materializer)
        let (testRoot, repoDir, wsRoot) = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        await #expect(throws: WorkspaceError.self) {
            _ = try await service.createWorkspace(repoName: "test-repo", repoLocalURL: repoDir, name: "test-ws")
        }

        let workspaceDir =
            wsRoot
            .appendingPathComponent("test-repo", isDirectory: true)
            .appendingPathComponent("test-ws", isDirectory: true)
        #expect(materializer.removeCalls == [workspaceDir])
        #expect(!FileManager.default.fileExists(atPath: workspaceDir.path))
    }

    @Test("createWorkspace reports failed best-effort materializer cleanup")
    func createWorkspaceReportsFailedMaterializerCleanup() async throws {
        let materializer = RecordingWorkspaceMaterializer()
        materializer.createsDestination = true
        materializer.materializeError = GitError.commandFailed(args: ["worktree", "add"], stderr: "already exists")
        materializer.removeError = CleanupError()
        let cleanupFailures = CleanupFailureRecorder()
        let service = WorkspaceService(
            materializer: materializer,
            cleanupFailureReporter: { failure in
                cleanupFailures.record(failure)
            }
        )
        let (testRoot, repoDir, wsRoot) = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        await #expect(throws: WorkspaceError.self) {
            _ = try await service.createWorkspace(repoName: "test-repo", repoLocalURL: repoDir, name: "test-ws")
        }

        let workspaceDir =
            wsRoot
            .appendingPathComponent("test-repo", isDirectory: true)
            .appendingPathComponent("test-ws", isDirectory: true)
        let failure = try #require(cleanupFailures.snapshot().first)
        #expect(materializer.removeCalls == [workspaceDir])
        #expect(failure.context == "materialization failure")
        #expect(failure.targetPath == workspaceDir.path)
        #expect(failure.errorDescription == "cleanup failed")
    }

    @Test("createWorkspace throws when directory already exists")
    func createWorkspaceThrowsWhenExists() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let (testRoot, _, wsRoot) = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        let wsDir =
            wsRoot
            .appendingPathComponent("test-repo")
            .appendingPathComponent("existing-ws")
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)

        await #expect(throws: WorkspaceError.self) {
            _ = try await service.createWorkspace(repoName: "test-repo", repoLocalURL: wsRoot, name: "existing-ws")
        }
    }

    @Test("createWorkspace rejects path traversal names")
    func createWorkspaceRejectsPathTraversalName() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let (testRoot, repoDir, wsRoot) = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        await #expect(throws: WorkspaceError.self) {
            _ = try await service.createWorkspace(repoName: "test-repo", repoLocalURL: repoDir, name: "..")
        }
    }

    @Test("createWorkspace rejects empty names after sanitization")
    func createWorkspaceRejectsEmptySanitizedName() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let (testRoot, repoDir, wsRoot) = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        await #expect(throws: WorkspaceError.self) {
            _ = try await service.createWorkspace(repoName: "test-repo", repoLocalURL: repoDir, name: "   ")
        }
    }

    @Test("createWorkspace emits progress phases in order on success")
    func createWorkspaceEmitsProgressPhasesInOrderOnSuccess() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let (testRoot, repoDir, wsRoot) = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        let recorder = PhaseRecorder()
        _ = try await service.createWorkspace(
            repoName: "test-repo",
            repoLocalURL: repoDir,
            name: "progress-ws",
            progress: { phase in
                await recorder.record(phase)
            }
        )

        let phases = await recorder.snapshot()
        #expect(phases == [.preparing, .creatingWorktree, .runningSetupScript, .finished])
    }

    @Test("createWorkspace stops progress at failing phase")
    func createWorkspaceStopsProgressAtFailingPhase() async throws {
        let mockGit = MockGitService()
        mockGit.createWorktreeError = GitError.commandFailed(args: ["worktree", "add"], stderr: "failed")
        let service = WorkspaceService(gitService: mockGit)
        let tempRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let wsRoot = tempRoot.appendingPathComponent("workspaces")
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        let recorder = PhaseRecorder()
        await #expect(throws: WorkspaceError.self) {
            _ = try await service.createWorkspace(
                repoName: "test-repo",
                repoLocalURL: tempRoot.appendingPathComponent("missing-repo"),
                name: "progress-fail",
                progress: { phase in
                    await recorder.record(phase)
                }
            )
        }

        let phases = await recorder.snapshot()
        #expect(phases == [.preparing, .creatingWorktree])
    }

    @Test("createWorkspace materializes a git worktree")
    func createWorkspaceMaterializesGitWorktree() async throws {
        let service = WorkspaceService()
        let (testRoot, repoDir, wsRoot) = try makeGitWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        let info = try await service.createWorkspace(
            repoName: "test-repo",
            repoLocalURL: repoDir,
            name: "feature-a"
        )

        #expect(info.gitBranch == "workspace/feature-a")
        #expect(FileManager.default.fileExists(atPath: info.path.appendingPathComponent("README.md").path))

        var gitPathIsDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: info.path.appendingPathComponent(".git").path,
                isDirectory: &gitPathIsDirectory
            )
        )
        #expect(!gitPathIsDirectory.boolValue)

        let currentBranch = try runGit(["branch", "--show-current"], at: info.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(currentBranch == "workspace/feature-a")

        let worktreeList = try runGit(["worktree", "list", "--porcelain"], at: repoDir)
        #expect(self.worktreeList(worktreeList, contains: info.path))
    }

    @Test("createWorkspace with fromRef materializes from fetched origin ref")
    func createWorkspaceMaterializesFromFetchedRef() async throws {
        let service = WorkspaceService()
        let testRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let seedDir = testRoot.appendingPathComponent("seed", isDirectory: true)
        let remoteDir = testRoot.appendingPathComponent("origin.git", isDirectory: true)
        let repoDir = testRoot.appendingPathComponent("repos/test-repo", isDirectory: true)
        let wsRoot = testRoot.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)

        _ = try runGit(["init", "-b", "main"], at: seedDir)
        _ = try runGit(["config", "user.email", "test@example.com"], at: seedDir)
        _ = try runGit(["config", "user.name", "Test User"], at: seedDir)
        try "stale\n".write(to: seedDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try runGit(["add", "-A"], at: seedDir)
        _ = try runGit(["commit", "-m", "initial"], at: seedDir)
        _ = try runGit(["init", "--bare", remoteDir.path], at: testRoot)
        _ = try runGit(["remote", "add", "origin", remoteDir.path], at: seedDir)
        _ = try runGit(["push", "-u", "origin", "main"], at: seedDir)
        _ = try runGit(["clone", remoteDir.path, repoDir.path], at: testRoot)
        let staleHead = try runGit(["rev-parse", "HEAD"], at: repoDir)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try "fresh\n".write(to: seedDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try runGit(["add", "-A"], at: seedDir)
        _ = try runGit(["commit", "-m", "fresh"], at: seedDir)
        _ = try runGit(["push", "origin", "main"], at: seedDir)
        let fetchedHead = try runGit(["rev-parse", "HEAD"], at: seedDir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(fetchedHead != staleHead)

        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        let info = try await service.createWorkspace(
            repoName: "test-repo",
            repoLocalURL: repoDir,
            name: "fresh-ref",
            fromRef: "origin/main"
        )

        let workspaceHead = try runGit(["rev-parse", "HEAD"], at: info.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(workspaceHead == fetchedHead)
        #expect(workspaceHead != staleHead)
    }

    @Test("createWorkspace can materialize with repository copy adapter")
    func createWorkspaceCanMaterializeWithRepositoryCopyAdapter() async throws {
        let service = WorkspaceService(materializer: GitCloneWorkspaceMaterializer())
        let (testRoot, repoDir, wsRoot) = try makeGitWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        let info = try await service.createWorkspace(
            repoName: "test-repo",
            repoLocalURL: repoDir,
            name: "copy-mode"
        )

        #expect(info.gitBranch == "workspace/copy-mode")
        #expect(FileManager.default.fileExists(atPath: info.path.appendingPathComponent("README.md").path))

        var gitPathIsDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: info.path.appendingPathComponent(".git").path,
                isDirectory: &gitPathIsDirectory
            )
        )
        #expect(gitPathIsDirectory.boolValue)

        let currentBranch = try runGit(["branch", "--show-current"], at: info.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(currentBranch == "workspace/copy-mode")

        let worktreeList = try runGit(["worktree", "list", "--porcelain"], at: repoDir)
        #expect(!self.worktreeList(worktreeList, contains: info.path))
    }

    @Test("createWorkspace can materialize from a linked worktree source")
    func createWorkspaceMaterializesFromLinkedWorktreeSource() async throws {
        let service = WorkspaceService()
        let (testRoot, repoDir, wsRoot) = try makeGitWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        let sourceWorktree = testRoot.appendingPathComponent("source-worktree", isDirectory: true)
        _ = try runGit(
            ["worktree", "add", "-b", "source-linked", sourceWorktree.path, "HEAD"],
            at: repoDir
        )

        let info = try await service.createWorkspace(
            repoName: "test-repo",
            repoLocalURL: sourceWorktree,
            name: "from-linked"
        )

        let currentBranch = try runGit(["branch", "--show-current"], at: info.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(currentBranch == "workspace/from-linked")

        let worktreeList = try runGit(["worktree", "list", "--porcelain"], at: sourceWorktree)
        #expect(self.worktreeList(worktreeList, contains: info.path))
    }

    @Test("createWorkspace runs project-scripts setup from the new worktree")
    func createWorkspaceRunsProjectScriptsSetupFromNewWorktree() async throws {
        let service = WorkspaceService()
        let (testRoot, repoDir, wsRoot) = try makeGitWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        let scriptsDir = repoDir.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        pwd > setup.cwd
        touch setup.marker
        """.write(to: scriptsDir.appendingPathComponent("setup"), atomically: true, encoding: .utf8)
        _ = try runGit(["add", "-A"], at: repoDir)
        _ = try runGit(["commit", "-m", "add project setup script"], at: repoDir)

        let info = try await service.createWorkspace(
            repoName: "test-repo",
            repoLocalURL: repoDir,
            name: "project-setup"
        )

        #expect(FileManager.default.fileExists(atPath: info.path.appendingPathComponent("setup.marker").path))
        let setupCWD = try String(contentsOf: info.path.appendingPathComponent("setup.cwd"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            URL(fileURLWithPath: setupCWD).standardizedFileURL.resolvingSymlinksInPath()
                == info.path.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    @Test("createWorkspace cleans up when workspace branch already exists")
    func createWorkspaceCleansUpWhenWorkspaceBranchExists() async throws {
        let service = WorkspaceService()
        let (testRoot, repoDir, wsRoot) = try makeGitWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }
        _ = try runGit(["branch", "workspace/conflict"], at: repoDir)

        await #expect(throws: WorkspaceError.self) {
            _ = try await service.createWorkspace(
                repoName: "test-repo",
                repoLocalURL: repoDir,
                name: "conflict"
            )
        }

        let workspaceDir =
            wsRoot
            .appendingPathComponent("test-repo", isDirectory: true)
            .appendingPathComponent("conflict", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: workspaceDir.path))
        #expect(!FileManager.default.fileExists(atPath: workspaceDir.deletingLastPathComponent().path))
        let preexistingBranchStillExists = try branchExists("workspace/conflict", at: repoDir)
        #expect(preexistingBranchStillExists)
    }

    @Test("deleteWorkspace removes linked worktree metadata and branch")
    func deleteWorkspaceRemovesLinkedWorktreeMetadataAndBranch() async throws {
        let service = WorkspaceService()
        let (testRoot, repoDir, wsRoot) = try makeGitWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        let info = try await service.createWorkspace(
            repoName: "test-repo",
            repoLocalURL: repoDir,
            name: "delete-me"
        )

        try await service.deleteWorkspace(at: info.path, deleteFiles: true)

        #expect(!FileManager.default.fileExists(atPath: info.path.path))
        let worktreeList = try runGit(["worktree", "list", "--porcelain"], at: repoDir)
        #expect(!self.worktreeList(worktreeList, contains: info.path))
        let deletedBranchExists = try branchExists("workspace/delete-me", at: repoDir)
        #expect(!deletedBranchExists)
    }

    @Test("createWorkspace keeps setup.sh warning behavior")
    func createWorkspaceKeepsSetupWarningBehavior() async throws {
        let service = WorkspaceService()
        let (testRoot, repoDir, wsRoot) = try makeGitWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }
        let setupPath = repoDir.appendingPathComponent("setup.sh")
        try """
        #!/bin/bash
        echo setup failed >&2
        exit 7
        """.write(to: setupPath, atomically: true, encoding: .utf8)
        _ = try runGit(["add", "setup.sh"], at: repoDir)
        _ = try runGit(["commit", "-m", "add failing setup"], at: repoDir)

        let info = try await service.createWorkspace(
            repoName: "test-repo",
            repoLocalURL: repoDir,
            name: "setup-warning"
        )

        #expect(FileManager.default.fileExists(atPath: info.path.path))
        #expect(info.warnings.contains { $0.contains("setup.sh exited with code 7") })
    }

    // MARK: - deleteWorkspace Tests

    @Test("deleteWorkspace removes files when deleteFiles is true")
    func deleteWorkspaceRemovesFiles() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wsDir = tempDir.appendingPathComponent("test-repo/ws1")
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        try "content".write(to: wsDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        try await service.deleteWorkspace(at: wsDir, deleteFiles: true)

        #expect(!FileManager.default.fileExists(atPath: wsDir.path))
    }

    @Test("deleteWorkspace keeps files when deleteFiles is false")
    func deleteWorkspaceKeepsFiles() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wsDir = tempDir.appendingPathComponent("test-repo/ws1")
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        try "content".write(to: wsDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        try await service.deleteWorkspace(at: wsDir, deleteFiles: false)

        #expect(FileManager.default.fileExists(atPath: wsDir.path))
    }

    @Test("deleteWorkspace cleans up empty parent directory")
    func deleteWorkspaceCleansUpEmptyParent() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let parentDir = tempDir.appendingPathComponent("test-repo")
        let wsDir = parentDir.appendingPathComponent("only-workspace")
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)

        try await service.deleteWorkspace(at: wsDir, deleteFiles: true)

        #expect(!FileManager.default.fileExists(atPath: wsDir.path))
        #expect(!FileManager.default.fileExists(atPath: parentDir.path))
    }

    @Test("deleteWorkspace preserves parent when siblings exist")
    func deleteWorkspacePreservesParentWithSiblings() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let parentDir = tempDir.appendingPathComponent("test-repo")
        let wsDir = parentDir.appendingPathComponent("ws-to-delete")
        let siblingDir = parentDir.appendingPathComponent("ws-sibling")
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)

        try await service.deleteWorkspace(at: wsDir, deleteFiles: true)

        #expect(!FileManager.default.fileExists(atPath: wsDir.path))
        #expect(FileManager.default.fileExists(atPath: parentDir.path))
    }

    // MARK: - archiveWorkspace Tests

    @Test("archiveWorkspace moves the directory into .archived when no script exists")
    func archiveWorkspaceSucceedsWithoutScript() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wsDir = tempDir.appendingPathComponent("repo/ws", isDirectory: true)
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)

        let destination = try await service.archiveWorkspace(at: wsDir)

        #expect(destination.path == tempDir.appendingPathComponent(".archived/repo/ws").path)
        #expect(!FileManager.default.fileExists(atPath: wsDir.path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    // A record whose directory is already gone is the state archiving is most wanted in —
    // the relic tiles of #1441. Archiving reports the live path back unchanged and leaves no
    // `.archived/` tree behind, so the caller marks the record archived without a move.
    @Test("archiveWorkspace no-ops at the live path when the directory is already gone")
    func archiveWorkspaceSkipsMoveWhenDirectoryMissing() async throws {
        let service = WorkspaceService(gitService: MockGitService())
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wsDir = tempDir.appendingPathComponent("repo/ws", isDirectory: true)

        let destination = try await service.archiveWorkspace(at: wsDir)

        #expect(destination.path == wsDir.path)
        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".archived").path))
    }

    @Test("archiveWorkspace runs archive.sh before moving the directory")
    func archiveWorkspaceRunsScript() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wsDir = tempDir.appendingPathComponent("repo/ws", isDirectory: true)
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)

        // Marker is written outside the workspace dir so it survives the archive move.
        try """
        #!/bin/bash
        touch "\(tempDir.path)/archived.marker"
        """.write(to: wsDir.appendingPathComponent("archive.sh"), atomically: true, encoding: .utf8)

        let destination = try await service.archiveWorkspace(at: wsDir)

        #expect(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("archived.marker").path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: wsDir.path))
    }

    @Test("archiveWorkspace runs project-scripts stop then archive")
    func archiveWorkspaceRunsProjectScriptsStopThenArchive() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wsDir = tempDir.appendingPathComponent("repo/ws", isDirectory: true)
        let scriptsDir = wsDir.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        let orderFile = tempDir.appendingPathComponent("teardown-order.log")
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        printf "stop\\n" >> "\(orderFile.path)"
        """.write(to: scriptsDir.appendingPathComponent("stop"), atomically: true, encoding: .utf8)
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        printf "archive\\n" >> "\(orderFile.path)"
        """.write(to: scriptsDir.appendingPathComponent("archive"), atomically: true, encoding: .utf8)

        try await service.archiveWorkspace(at: wsDir)

        let order = try String(contentsOf: orderFile, encoding: .utf8)
        #expect(order == "stop\narchive\n")
    }

    @Test("archived and restored destinations round-trip")
    func archivedRestoredDestinationsRoundTrip() {
        let source = URL(fileURLWithPath: "/tmp/roots/myrepo/feature-x", isDirectory: true)
        let archived = WorkspaceDirectoryArchiver.archivedDestination(for: source)
        #expect(archived.path == "/tmp/roots/.archived/myrepo/feature-x")
        let restored = WorkspaceDirectoryArchiver.restoredDestination(for: archived)
        #expect(restored.path == source.path)
    }

    // restoredDestination assumes its input is an archived path shaped
    // `<root>/.archived/<repo>/<name>` and walks three levels up to recover `<root>`.
    // Handed a pre-#661 legacy path (files never relocated, still at the live
    // `<root>/<repo>/<name>`), that same walk overshoots by one level and lands
    // *outside* the workspaces root — the corruption behind #663. This pins that
    // hazard so the invariant stays visible: callers must not route a live path
    // through restoredDestination (SidebarWorkspaceController.unarchive guards on the
    // positional `.archived` shape for exactly this reason).
    @Test("restoredDestination overshoots the root for a legacy live-path source")
    func restoredDestinationOvershootsForLivePathSource() {
        let livePath = URL(fileURLWithPath: "/tmp/roots/myrepo/feature-x", isDirectory: true)
        let restored = WorkspaceDirectoryArchiver.restoredDestination(for: livePath)
        // Walks past `/tmp/roots` to `/tmp` — one level above the workspaces root.
        #expect(restored.path == "/tmp/myrepo/feature-x")
        #expect(restored.path != livePath.path)
    }

    @Test("archiveWorkspace moves a linked worktree and updates git metadata")
    func archiveWorkspaceMovesLinkedWorktree() async throws {
        let service = WorkspaceService()
        let (testRoot, repoDir, wsRoot) = try makeGitWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        let info = try await service.createWorkspace(
            repoName: "test-repo",
            repoLocalURL: repoDir,
            name: "archive-me"
        )

        let archivedURL = try await service.archiveWorkspace(at: info.path)

        #expect(archivedURL.path == wsRoot.appendingPathComponent(".archived/test-repo/archive-me").path)
        #expect(!FileManager.default.fileExists(atPath: info.path.path))
        #expect(FileManager.default.fileExists(atPath: archivedURL.path))

        let list = try runGit(["worktree", "list", "--porcelain"], at: repoDir)
        #expect(self.worktreeList(list, contains: archivedURL))
        #expect(!self.worktreeList(list, contains: info.path))

        // The moved worktree is still a valid git worktree (status succeeds, doesn't throw).
        _ = try runGit(["status", "--porcelain"], at: archivedURL)
    }

    @Test("unarchiveWorkspace restores a linked worktree to its original path")
    func unarchiveWorkspaceRestoresLinkedWorktree() async throws {
        let service = WorkspaceService()
        let (testRoot, repoDir, wsRoot) = try makeGitWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        let info = try await service.createWorkspace(
            repoName: "test-repo",
            repoLocalURL: repoDir,
            name: "round-trip"
        )
        let archivedURL = try await service.archiveWorkspace(at: info.path)

        let restoredURL = try await service.unarchiveWorkspace(at: archivedURL)

        #expect(restoredURL.path == info.path.path)
        #expect(FileManager.default.fileExists(atPath: restoredURL.path))
        #expect(!FileManager.default.fileExists(atPath: archivedURL.path))

        let list = try runGit(["worktree", "list", "--porcelain"], at: repoDir)
        #expect(self.worktreeList(list, contains: restoredURL))
        #expect(!self.worktreeList(list, contains: archivedURL))
    }

    @Test("deleteWorkspace runs project-scripts teardown before removing workspace")
    func deleteWorkspaceRunsProjectScriptsTeardownBeforeRemovingWorkspace() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wsDir = tempDir.appendingPathComponent("test-repo/ws-project-scripts")
        let scriptsDir = wsDir.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        let orderFile = tempDir.appendingPathComponent("delete-teardown-order.log")
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        printf "stop\\n" >> "\(orderFile.path)"
        """.write(to: scriptsDir.appendingPathComponent("stop"), atomically: true, encoding: .utf8)
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        printf "archive\\n" >> "\(orderFile.path)"
        """.write(to: scriptsDir.appendingPathComponent("archive"), atomically: true, encoding: .utf8)

        try await service.deleteWorkspace(at: wsDir, deleteFiles: true)

        let order = try String(contentsOf: orderFile, encoding: .utf8)
        #expect(order == "stop\narchive\n")
        #expect(!FileManager.default.fileExists(atPath: wsDir.path))
    }

    // MARK: - getWorkspaceSize Tests

    @Test("getWorkspaceSize returns total file size")
    func getWorkspaceSizeReturnsSize() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let content = String(repeating: "x", count: 1000)
        try content.write(to: tempDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try content.write(to: tempDir.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        let size = try await service.getWorkspaceSize(at: tempDir)

        #expect(size >= 2000)
    }

    @Test("getWorkspaceSize returns zero for empty workspace")
    func getWorkspaceSizeReturnsZeroForEmpty() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let size = try await service.getWorkspaceSize(at: tempDir)
        #expect(size == 0)
    }
}

private struct TestGitCommandError: Error, CustomStringConvertible {
    let args: [String]
    let stderr: String

    var description: String {
        "git \(args.joined(separator: " ")) failed: \(stderr)"
    }
}
