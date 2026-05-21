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
}
