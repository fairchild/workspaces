import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("UIFixturePreviewBootstrap")
struct UIFixturePreviewBootstrapTests {
    @Test("Configuration requires fixture and preview flags")
    func configurationRequiresFlags() {
        #expect(UIFixturePreviewBootstrapConfiguration.from(environment: [:]) == nil)
        #expect(
            UIFixturePreviewBootstrapConfiguration.from(
                environment: ["WORKSPACES_UI_FIXTURE": "1"]
            ) == nil
        )
        #expect(
            UIFixturePreviewBootstrapConfiguration.from(
                environment: ["WORKSPACES_UI_FIXTURE_OPEN_PREVIEW": "1"]
            ) == nil
        )
    }

    @Test("Configuration applies defaults and trims overrides")
    func configurationAppliesDefaultsAndTrimsOverrides() {
        let defaults = UIFixturePreviewBootstrapConfiguration.from(
            environment: [
                "WORKSPACES_UI_FIXTURE": "1",
                "WORKSPACES_UI_FIXTURE_OPEN_PREVIEW": "1",
            ]
        )
        #expect(defaults == UIFixturePreviewBootstrapConfiguration(repoName: "skills", relativePath: "README.md"))

        let custom = UIFixturePreviewBootstrapConfiguration.from(
            environment: [
                "WORKSPACES_UI_FIXTURE": "1",
                "WORKSPACES_UI_FIXTURE_OPEN_PREVIEW": "1",
                "WORKSPACES_UI_FIXTURE_PREVIEW_REPO": "  Services  ",
                "WORKSPACES_UI_FIXTURE_PREVIEW_PATH": "  docs/guide.md  ",
            ]
        )
        #expect(custom == UIFixturePreviewBootstrapConfiguration(repoName: "Services", relativePath: "docs/guide.md"))
    }

    @Test("Resolve selection uses requested repo and file")
    func resolveSelectionUsesRequestedRepoAndFile() throws {
        let fileManager = FileManager.default
        let fixtureRoot = try makeFixtureRoot(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let servicesRepo = try makeRepo(name: "services", at: fixtureRoot, fileManager: fileManager)
        let skillsRepo = try makeRepo(name: "skills", at: fixtureRoot, fileManager: fileManager)
        let targetFile = servicesRepo.localURL.appendingPathComponent("docs/guide.md")
        try fileManager.createDirectory(
            at: targetFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# guide\n".utf8).write(to: targetFile)

        let configuration = UIFixturePreviewBootstrapConfiguration(
            repoName: "services",
            relativePath: "docs/guide.md"
        )

        let resolved = UIFixturePreviewBootstrap.resolveSelection(
            configuration: configuration,
            repos: [skillsRepo, servicesRepo],
            fileManager: fileManager
        )

        #expect(resolved?.repo.id == servicesRepo.id)
        #expect(resolved?.selection.relativePath == "docs/guide.md")
        #expect(
            resolved?.selection.rootURL.path == servicesRepo.localURL.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    @Test("Resolve selection falls back to first repo when requested repo missing")
    func resolveSelectionFallsBackToFirstRepo() throws {
        let fileManager = FileManager.default
        let fixtureRoot = try makeFixtureRoot(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let primaryRepo = try makeRepo(name: "alpha", at: fixtureRoot, fileManager: fileManager)
        let fallbackFile = primaryRepo.localURL.appendingPathComponent("README.md")
        try Data("hello\n".utf8).write(to: fallbackFile)

        let configuration = UIFixturePreviewBootstrapConfiguration(
            repoName: "missing-repo",
            relativePath: "README.md"
        )

        let resolved = UIFixturePreviewBootstrap.resolveSelection(
            configuration: configuration,
            repos: [primaryRepo],
            fileManager: fileManager
        )

        #expect(resolved?.repo.id == primaryRepo.id)
        #expect(resolved?.selection.relativePath == "README.md")
    }

    @Test("Resolve selection rejects missing or escaped file paths")
    func resolveSelectionRejectsInvalidPaths() throws {
        let fileManager = FileManager.default
        let fixtureRoot = try makeFixtureRoot(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let repo = try makeRepo(name: "skills", at: fixtureRoot, fileManager: fileManager)

        let missingConfig = UIFixturePreviewBootstrapConfiguration(
            repoName: "skills",
            relativePath: "README.md"
        )
        let missingSelection = UIFixturePreviewBootstrap.resolveSelection(
            configuration: missingConfig,
            repos: [repo],
            fileManager: fileManager
        )
        #expect(missingSelection == nil)

        let outsideFile = fixtureRoot.appendingPathComponent("outside.md")
        try Data("outside\n".utf8).write(to: outsideFile)

        let escapedConfig = UIFixturePreviewBootstrapConfiguration(
            repoName: "skills",
            relativePath: "../outside.md"
        )
        let escapedSelection = UIFixturePreviewBootstrap.resolveSelection(
            configuration: escapedConfig,
            repos: [repo],
            fileManager: fileManager
        )
        #expect(escapedSelection == nil)
    }

    private func makeFixtureRoot(fileManager: FileManager) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("wm-ui-fixture-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRepo(
        name: String,
        at root: URL,
        fileManager: FileManager
    ) throws -> Repo {
        let repoURL = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: repoURL, withIntermediateDirectories: true)
        return Repo(name: name, localPath: repoURL)
    }
}
