//
//  RepositoryDiscoveryTests.swift
//  WorkspaceManagerTests
//
//  Tests repository discovery for default ~/code preload behavior.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("RepositoryDiscovery")
struct RepositoryDiscoveryTests {
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryDiscoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Returns only git repositories directly under the root")
    func returnsOnlyDirectGitRepositories() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoA = root.appendingPathComponent("repo-a", isDirectory: true)
        let repoB = root.appendingPathComponent("repo-b", isDirectory: true)
        let nonRepo = root.appendingPathComponent("notes", isDirectory: true)

        try FileManager.default.createDirectory(at: repoA.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB, withIntermediateDirectories: true)
        try Data("gitdir: /tmp/fake\n".utf8).write(to: repoB.appendingPathComponent(".git"))
        try FileManager.default.createDirectory(at: nonRepo, withIntermediateDirectories: true)

        let discovered = RepositoryDiscovery.discoverGitRepositories(in: root)
        let discoveredNames = discovered.map(\.lastPathComponent)

        #expect(discoveredNames == ["repo-a", "repo-b"])
    }

    @Test("Skips hidden entries")
    func skipsHiddenEntries() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let hiddenRepo = root.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenRepo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)

        let discovered = RepositoryDiscovery.discoverGitRepositories(in: root)
        #expect(discovered.isEmpty)
    }

    @Test("Returns empty when root does not exist")
    func returnsEmptyWhenRootMissing() {
        let missing = URL(fileURLWithPath: "/tmp/RepositoryDiscoveryTests-missing-\(UUID().uuidString)")
        let discovered = RepositoryDiscovery.discoverGitRepositories(in: missing)
        #expect(discovered.isEmpty)
    }
}
