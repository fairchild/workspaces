import Foundation
import SwiftData
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("LaunchRepositoryService", .serialized)
struct LaunchRepositoryServiceTests {
    @Test("Returns an existing tracked repo without importing a duplicate")
    func returnsExistingTrackedRepo() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let root = try makeTemporaryDirectory(prefix: "wm-launch-repo-existing")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

        let repo = Repo(name: "alpha", localPath: repoURL)
        context.insert(repo)
        try context.save()

        let service = LaunchRepositoryService(modelContext: context)
        let resolved = service.existingOrImportedRepo(at: repoURL.path)
        let repos = try context.fetch(FetchDescriptor<Repo>())

        #expect(resolved?.id == repo.id)
        #expect(repos.count == 1)
    }

    @Test("Imports an untracked git repo")
    func importsUntrackedGitRepo() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let repoURL = try makeGitRepository(prefix: "wm-launch-repo-import")
        defer { try? FileManager.default.removeItem(at: repoURL.deletingLastPathComponent()) }

        let service = LaunchRepositoryService(modelContext: context)
        let resolved = service.existingOrImportedRepo(at: repoURL.path)
        let repos = try context.fetch(FetchDescriptor<Repo>())

        #expect(resolved?.localURL.path == repoURL.path)
        #expect(resolved?.name == repoURL.lastPathComponent)
        #expect(repos.count == 1)
    }

    @Test("Returns nil for a non-git directory")
    func returnsNilForNonGitDirectory() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let root = try makeTemporaryDirectory(prefix: "wm-launch-repo-non-git")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("plain-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

        let service = LaunchRepositoryService(modelContext: context)
        let resolved = service.existingOrImportedRepo(at: repoURL.path)
        let repos = try context.fetch(FetchDescriptor<Repo>())

        #expect(resolved == nil)
        #expect(repos.isEmpty)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeGitRepository(prefix: String) throws -> URL {
        let root = try makeTemporaryDirectory(prefix: prefix)
        let repoURL = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try runGit(["init"], at: repoURL)
        return repoURL
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw NSError(
                domain: "LaunchRepositoryServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"]
            )
        }
    }
}
