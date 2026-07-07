//
//  GitServiceDiffTests.swift
//  WorkspaceManagerTests
//
//  Integration tests for GitService diff / stage / unstage / discard.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("GitService diff/stage/unstage/discard")
struct GitServiceDiffTests {

    @Test("diff returns hunks for modified file")
    func diffReturnsHunksForModifiedFile() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("a.txt", content: "one\ntwo\nthree\n")
        try repo.commit(message: "init")
        try repo.modifyFile("a.txt", content: "one\nTWO\nthree\n")

        let diff = try await GitService.shared.diff(file: "a.txt", at: repo.url)
        #expect(diff.path == "a.txt")
        #expect(diff.hunks.count == 1)
        #expect(diff.addedLines == 1)
        #expect(diff.removedLines == 1)
        #expect(diff.hunks[0].lines.contains(.init(kind: .added, content: "TWO")))
        #expect(diff.hunks[0].lines.contains(.init(kind: .removed, content: "two")))
    }

    @Test("diff on clean file is empty")
    func diffOnCleanFileIsEmpty() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("a.txt", content: "hello\n")
        try repo.commit(message: "init")

        let diff = try await GitService.shared.diff(file: "a.txt", at: repo.url)
        #expect(diff.hunks.isEmpty)
    }

    @Test("stage moves modification into index and clears working-tree diff")
    func stageMovesIntoIndex() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("a.txt", content: "x\n")
        try repo.commit(message: "init")
        try repo.modifyFile("a.txt", content: "y\n")

        try await GitService.shared.stage(file: "a.txt", at: repo.url)

        let diff = try await GitService.shared.diff(file: "a.txt", at: repo.url)
        #expect(diff.hunks.isEmpty, "working-tree diff should be empty after staging")

        let status = try await GitService.shared.getStatus(at: repo.url)
        #expect(status.contains(where: { $0.path == "a.txt" }))
    }

    @Test("unstage moves staged change back to working tree")
    func unstageMovesBackToWorkingTree() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("a.txt", content: "x\n")
        try repo.commit(message: "init")
        try repo.modifyFile("a.txt", content: "y\n")
        try await GitService.shared.stage(file: "a.txt", at: repo.url)
        try await GitService.shared.unstage(file: "a.txt", at: repo.url)

        let diff = try await GitService.shared.diff(file: "a.txt", at: repo.url)
        #expect(!diff.hunks.isEmpty, "working-tree diff should reappear after unstage")
        #expect(diff.addedLines == 1)
        #expect(diff.removedLines == 1)
    }

    @Test("discard restores HEAD contents")
    func discardRestoresHeadContents() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("a.txt", content: "original\n")
        try repo.commit(message: "init")
        try repo.modifyFile("a.txt", content: "garbage\n")

        try await GitService.shared.discard(file: "a.txt", at: repo.url)

        let restored = try String(contentsOf: repo.url.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(restored == "original\n")

        let diff = try await GitService.shared.diff(file: "a.txt", at: repo.url)
        #expect(diff.hunks.isEmpty)
    }

    @Test("discardUntracked deletes exactly the one untracked file")
    func discardUntrackedDeletesTargetOnly() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("keep.txt", content: "keep\n")
        try repo.commit(message: "init")
        try repo.createFile("scratch.txt", content: "temporary\n")
        try repo.createFile("sibling.txt", content: "also new\n")

        try await GitService.shared.discardUntracked(file: "scratch.txt", at: repo.url)

        #expect(!FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("scratch.txt").path))
        #expect(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("sibling.txt").path))
        #expect(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("keep.txt").path))
    }

    @Test("discardUntracked refuses a path escaping the root")
    func discardUntrackedRefusesEscape() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        await #expect(throws: GitError.invalidRelativePath("../outside.txt")) {
            try await GitService.shared.discardUntracked(file: "../outside.txt", at: repo.url)
        }
        await #expect(throws: GitError.invalidRelativePath("/etc/hosts")) {
            try await GitService.shared.discardUntracked(file: "/etc/hosts", at: repo.url)
        }
    }

    @Test("discardUntracked refuses a symlink target")
    func discardUntrackedRefusesSymlink() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("real-secret.txt", content: "secret\n")
        try repo.commit(message: "init")
        let linkURL = repo.url.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: repo.url.appendingPathComponent("real-secret.txt")
        )

        await #expect(throws: GitError.symlinkRefused) {
            try await GitService.shared.discardUntracked(file: "link.txt", at: repo.url)
        }
        // The symlink and its target both survive the refusal.
        #expect(FileManager.default.fileExists(atPath: linkURL.path))
        #expect(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("real-secret.txt").path))
    }

    @Test("discardUntracked refuses to delete a tracked file even if asked")
    func discardUntrackedRefusesTrackedFile() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("tracked.txt", content: "committed\n")
        try repo.commit(message: "init")

        await #expect(throws: GitError.discardUntrackedOnTrackedFile(relativePath: "tracked.txt")) {
            try await GitService.shared.discardUntracked(file: "tracked.txt", at: repo.url)
        }
        // The tracked file is untouched — the delete is refused at the service layer.
        #expect(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("tracked.txt").path))
    }

    @Test("discardUntracked reports a missing target instead of failing silently")
    func discardUntrackedReportsMissingTarget() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("a.txt", content: "x\n")
        try repo.commit(message: "init")

        await #expect(throws: GitError.untrackedTargetMissing(relativePath: "ghost.txt")) {
            try await GitService.shared.discardUntracked(file: "ghost.txt", at: repo.url)
        }
    }
}
