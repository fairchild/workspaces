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

    @Test("createWorkspace calls git createBranch with correct name")
    func createWorkspaceCallsCreateBranch() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let (testRoot, repoDir, wsRoot) = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        _ = try await service.createWorkspace(repoName: "test-repo", repoLocalURL: repoDir, name: "my-feature")

        #expect(mockGit.createBranchCalls.count == 1)
        #expect(mockGit.createBranchCalls[0].name == "workspace/my-feature")
    }

    @Test("createWorkspace continues when branch creation fails")
    func createWorkspaceContinuesWhenBranchFails() async throws {
        let mockGit = MockGitService()
        mockGit.createBranchError = GitError.commandFailed(args: ["checkout", "-b"], stderr: "already exists")
        let service = WorkspaceService(gitService: mockGit)
        let (testRoot, repoDir, wsRoot) = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let originalRoot = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(originalRoot) }

        let info = try await service.createWorkspace(repoName: "test-repo", repoLocalURL: repoDir, name: "test-ws")
        #expect(info.name == "test-ws")
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

    @Test("archiveWorkspace succeeds when no archive script exists")
    func archiveWorkspaceSucceedsWithoutScript() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await service.archiveWorkspace(at: tempDir)
    }

    @Test("archiveWorkspace runs archive.sh")
    func archiveWorkspaceRunsScript() async throws {
        let mockGit = MockGitService()
        let service = WorkspaceService(gitService: mockGit)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        #!/bin/bash
        touch "\(tempDir.path)/archived.marker"
        """.write(to: tempDir.appendingPathComponent("archive.sh"), atomically: true, encoding: .utf8)

        try await service.archiveWorkspace(at: tempDir)

        #expect(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("archived.marker").path))
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
