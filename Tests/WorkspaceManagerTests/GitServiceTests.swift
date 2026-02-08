//
//  GitServiceTests.swift
//  WorkspaceManagerTests
//
//  Tests for GitService: status parsing, branch operations, file tree
//

import Testing
import Foundation
@testable import WorkspaceManagerCore

@Suite("GitService")
struct GitServiceTests {

    // MARK: - getStatus Tests

    @Test("Clean repo returns empty status")
    func cleanRepoReturnsEmptyStatus() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        // Create initial commit to make it a valid repo
        try repo.createFile("README.md", content: "# Test")
        try repo.commit(message: "Initial commit")

        let changes = try await GitService.shared.getStatus(at: repo.url)
        #expect(changes.isEmpty)
    }

    @Test("Detects untracked file")
    func detectsUntrackedFile() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("README.md", content: "# Test")
        try repo.commit(message: "Initial commit")

        // Create untracked file
        try repo.createFile("new-file.txt", content: "untracked")

        let changes = try await GitService.shared.getStatus(at: repo.url)
        #expect(changes.count == 1)
        #expect(changes[0].path == "new-file.txt")
        #expect(changes[0].status == .untracked)
    }

    @Test("Detects modified file")
    func detectsModifiedFile() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("file.txt", content: "original")
        try repo.commit(message: "Initial commit")

        // Modify the file
        try repo.modifyFile("file.txt", content: "modified")

        let changes = try await GitService.shared.getStatus(at: repo.url)
        #expect(changes.count == 1)
        #expect(changes[0].path == "file.txt")
        #expect(changes[0].status == .modified)
    }

    @Test("Detects deleted file")
    func detectsDeletedFile() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("file.txt", content: "to delete")
        try repo.commit(message: "Initial commit")

        // Delete the file
        try repo.deleteFile("file.txt")

        let changes = try await GitService.shared.getStatus(at: repo.url)
        #expect(changes.count == 1)
        #expect(changes[0].path == "file.txt")
        #expect(changes[0].status == .deleted)
    }

    @Test("Detects added (staged) file")
    func detectsAddedFile() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("README.md", content: "# Test")
        try repo.commit(message: "Initial commit")

        // Create and stage a new file
        try repo.createFile("staged.txt", content: "staged content")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["add", "staged.txt"]
        process.currentDirectoryURL = repo.url
        try process.run()
        process.waitUntilExit()

        let changes = try await GitService.shared.getStatus(at: repo.url)
        #expect(changes.count == 1)
        #expect(changes[0].path == "staged.txt")
        #expect(changes[0].status == .added)
    }

    // MARK: - getCurrentBranch Tests

    @Test("Returns current branch name")
    func returnsCurrentBranchName() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("README.md", content: "# Test")
        try repo.commit(message: "Initial commit")

        let branch = try await GitService.shared.getCurrentBranch(at: repo.url)
        // Git init creates either "main" or "master" depending on config
        #expect(branch == "main" || branch == "master")
    }

    @Test("Returns nil for detached HEAD")
    func returnsNilForDetachedHead() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("README.md", content: "# Test")
        try repo.commit(message: "Initial commit")

        // Detach HEAD
        try repo.detachHead()

        let branch = try await GitService.shared.getCurrentBranch(at: repo.url)
        #expect(branch == nil || branch == "")
    }

    // MARK: - getFileTree Tests

    @Test("Builds correct file tree structure")
    func buildsCorrectFileTreeStructure() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("README.md", content: "# Test")
        try repo.createFile("src/main.swift", content: "// main")
        try repo.createFile("src/utils/helper.swift", content: "// helper")

        let tree = try await GitService.shared.getFileTree(at: repo.url)

        #expect(tree.isDirectory)
        #expect(tree.children != nil)

        // Should have .git (hidden, excluded), README.md, src
        let childNames = tree.children?.map(\.name) ?? []
        #expect(childNames.contains("src"))
        #expect(childNames.contains("README.md"))
        #expect(!childNames.contains(".git")) // Hidden files excluded
    }

    @Test("Ignores node_modules directory")
    func ignoresNodeModulesDirectory() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("package.json", content: "{}")
        try repo.createDirectory("node_modules")
        try repo.createFile("node_modules/some-package/index.js", content: "")

        let tree = try await GitService.shared.getFileTree(at: repo.url)
        let childNames = tree.children?.map(\.name) ?? []

        #expect(!childNames.contains("node_modules"))
    }

    @Test("Respects maxDepth parameter")
    func respectsMaxDepth() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        // Create deep nesting
        try repo.createFile("a/b/c/d/e/deep.txt", content: "deep")

        // With maxDepth 2, we should only see 2 levels
        let tree = try await GitService.shared.getFileTree(at: repo.url, maxDepth: 2)

        // Find 'a' directory
        guard let aDir = tree.children?.first(where: { $0.name == "a" }) else {
            Issue.record("Expected 'a' directory")
            return
        }

        // Find 'b' directory inside 'a'
        guard let bDir = aDir.children?.first(where: { $0.name == "b" }) else {
            Issue.record("Expected 'b' directory")
            return
        }

        // At depth 2, 'b' should not have expanded children
        #expect(bDir.children == nil)
    }

    @Test("Sorts directories before files")
    func sortsDirsBeforeFiles() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("zebra.txt", content: "")
        try repo.createFile("apple.txt", content: "")
        try repo.createDirectory("beta")
        try repo.createFile("beta/file.txt", content: "")
        try repo.createDirectory("alpha")
        try repo.createFile("alpha/file.txt", content: "")

        let tree = try await GitService.shared.getFileTree(at: repo.url)
        let children = tree.children ?? []

        // Find first file and first directory
        let firstDir = children.first { $0.isDirectory }
        let firstFile = children.first { !$0.isDirectory }

        guard let dirIndex = children.firstIndex(where: { $0.isDirectory }),
              let fileIndex = children.firstIndex(where: { !$0.isDirectory }) else {
            Issue.record("Expected both directories and files")
            return
        }

        // Directories should come before files
        #expect(dirIndex < fileIndex)

        // Directories should be sorted alphabetically
        #expect(firstDir?.name == "alpha")

        // Files should be sorted alphabetically
        #expect(firstFile?.name == "apple.txt")
    }

    // MARK: - getRemoteURL Tests

    @Test("Returns remote URL when origin is set")
    func returnsRemoteURL() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("README.md", content: "# Test")
        try repo.commit(message: "Initial commit")
        try repo.addRemote("origin", url: "https://github.com/test/repo.git")

        let remoteURL = try await GitService.shared.getRemoteURL(at: repo.url)
        #expect(remoteURL == "https://github.com/test/repo.git")
    }

    @Test("Throws when no remote origin exists")
    func throwsWhenNoRemote() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("README.md", content: "# Test")
        try repo.commit(message: "Initial commit")

        await #expect(throws: GitError.self) {
            _ = try await GitService.shared.getRemoteURL(at: repo.url)
        }
    }

    // MARK: - Branch Operations Tests

    @Test("createBranch creates and switches to new branch")
    func createBranchCreatesNewBranch() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("README.md", content: "# Test")
        try repo.commit(message: "Initial commit")

        try await GitService.shared.createBranch("feature/test", at: repo.url)

        let currentBranch = try await GitService.shared.getCurrentBranch(at: repo.url)
        #expect(currentBranch == "feature/test")
    }

    @Test("checkoutBranch switches to existing branch")
    func checkoutBranchSwitches() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("README.md", content: "# Test")
        try repo.commit(message: "Initial commit")

        let originalBranch = try await GitService.shared.getCurrentBranch(at: repo.url)

        try await GitService.shared.createBranch("other-branch", at: repo.url)
        #expect(try await GitService.shared.getCurrentBranch(at: repo.url) == "other-branch")

        try await GitService.shared.checkoutBranch(originalBranch!, at: repo.url)
        #expect(try await GitService.shared.getCurrentBranch(at: repo.url) == originalBranch)
    }

    // MARK: - Error Handling Tests

    @Test("Throws error for non-git directory")
    func throwsErrorForNonGitDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotAGitRepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        await #expect(throws: GitError.self) {
            try await GitService.shared.getStatus(at: tempDir)
        }
    }
}
