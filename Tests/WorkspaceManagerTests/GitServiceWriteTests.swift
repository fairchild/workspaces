//
//  GitServiceWriteTests.swift
//  WorkspaceManagerTests
//
//  Integration tests for GitService.showHead / writeFile (in-app editing support).
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("GitService showHead/writeFile")
struct GitServiceWriteTests {

    @Test("writeFile roundtrips and the change is reflected in diff")
    func writeFileRoundtrips() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("a.txt", content: "one\ntwo\nthree\n")
        try repo.commit(message: "init")

        try await GitService.shared.writeFile("one\nTWO\nthree\n", to: "a.txt", at: repo.url)

        let written = try String(contentsOf: repo.url.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(written == "one\nTWO\nthree\n")

        let diff = try await GitService.shared.diff(file: "a.txt", at: repo.url)
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].lines.contains(.init(kind: .added, content: "TWO")))
    }

    @Test("writeFile creates intermediate directories")
    func writeFileCreatesParentDirectories() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try await GitService.shared.writeFile("hi\n", to: "nested/deep/new.txt", at: repo.url)

        let written = try String(
            contentsOf: repo.url.appendingPathComponent("nested/deep/new.txt"),
            encoding: .utf8
        )
        #expect(written == "hi\n")
    }

    @Test("writeFile rejects paths that escape the repository root")
    func writeFileRejectsTraversal() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        await #expect(throws: GitError.self) {
            try await GitService.shared.writeFile("x", to: "../escape.txt", at: repo.url)
        }

        let escaped = repo.url.deletingLastPathComponent().appendingPathComponent("escape.txt")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }

    @Test("showHead returns committed contents for a tracked file")
    func showHeadReturnsCommittedContents() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("a.txt", content: "committed\n")
        try repo.commit(message: "init")
        try repo.modifyFile("a.txt", content: "working\n")

        let head = try await GitService.shared.showHead(file: "a.txt", at: repo.url)
        #expect(head == "committed\n")
    }

    @Test("showHead returns nil for a file not present at HEAD")
    func showHeadReturnsNilForUntrackedFile() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("a.txt", content: "x\n")
        try repo.commit(message: "init")
        try repo.createFile("new.txt", content: "fresh\n")

        let head = try await GitService.shared.showHead(file: "new.txt", at: repo.url)
        #expect(head == nil)
    }
}
