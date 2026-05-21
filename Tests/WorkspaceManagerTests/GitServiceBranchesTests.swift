//
//  GitServiceBranchesTests.swift
//  WorkspaceManagerTests
//
//  Integration tests for GitService.branches(at:).
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("GitService branches")
struct GitServiceBranchesTests {

    @Test("Single branch is returned and flagged current")
    func singleBranchIsCurrent() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("a.txt", content: "x")
        try repo.commit(message: "init")

        let branches = try await GitService.shared.branches(at: repo.url)
        #expect(branches.count == 1)
        #expect(branches[0].isCurrent)
        #expect(branches[0].isRemote == false)
    }

    @Test("Multiple local branches sorted with current first")
    func multipleLocalBranchesSorted() async throws {
        let repo = try TestGitRepository.create()
        defer { repo.cleanup() }

        try repo.createFile("a.txt", content: "x")
        try repo.commit(message: "init")
        try run(["git", "branch", "alpha"], at: repo.url)
        try run(["git", "branch", "zulu"], at: repo.url)
        try run(["git", "checkout", "alpha"], at: repo.url)

        let branches = try await GitService.shared.branches(at: repo.url)
        let names = branches.filter { !$0.isRemote }.map(\.name)
        #expect(names.first == "alpha")
        #expect(branches.first(where: { $0.isCurrent })?.name == "alpha")
        let onlyOneCurrent = branches.filter(\.isCurrent).count
        #expect(onlyOneCurrent == 1)
        #expect(Set(names).isSuperset(of: ["alpha", "zulu"]))
    }

    @Test("Remote branches are included and flagged")
    func remoteBranchesIncluded() async throws {
        // Origin repo
        let origin = try TestGitRepository.create()
        defer { origin.cleanup() }
        try origin.createFile("a.txt", content: "x")
        try origin.commit(message: "init")
        try run(["git", "branch", "feature/one"], at: origin.url)

        // Clone into a working repo so it gets refs/remotes/origin/*
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceManagerTests-clone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workDir) }
        try run(["git", "clone", origin.url.path, workDir.path], at: FileManager.default.temporaryDirectory)
        try run(["git", "config", "user.email", "t@e.com"], at: workDir)
        try run(["git", "config", "user.name", "T"], at: workDir)

        let branches = try await GitService.shared.branches(at: workDir)
        let remotes = branches.filter(\.isRemote).map(\.name)
        #expect(remotes.contains("feature/one"))
        #expect(!remotes.contains("HEAD"), "origin/HEAD pointer should be filtered out")

        // Locals come before remotes.
        let firstRemoteIndex = branches.firstIndex(where: { $0.isRemote }) ?? branches.endIndex
        let lastLocalIndex = branches.lastIndex(where: { !$0.isRemote }) ?? -1
        #expect(lastLocalIndex < firstRemoteIndex)
    }

    private func run(_ args: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw TestGitRepository.TestError.commandFailed(args.joined(separator: " "))
        }
    }
}
