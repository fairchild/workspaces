import Foundation
import Testing

@testable import WorkspaceManager

@Suite("GhosttyResourcesLocator")
struct GhosttyResourcesLocatorTests {
    @Test("bundled resources directory resolves when Ghostty resources are embedded")
    func bundledResourcesDirectoryResolvesEmbeddedLayout() throws {
        let fixture = try GhosttyResourcesFixture()
        defer { fixture.cleanup() }

        let resolved = GhosttyResourcesLocator.bundledResourcesDirectory(
            resourcesURL: fixture.resourcesURL
        )

        #expect(resolved?.path == fixture.ghosttyURL.path)
    }

    @Test("resolved resources directory prefers a valid existing environment path")
    func resolvedResourcesDirectoryPrefersEnvironment() throws {
        let fixture = try GhosttyResourcesFixture()
        defer { fixture.cleanup() }

        let customRoot = try fixture.makeAlternateResourcesRoot(named: "custom")
        let resolved = GhosttyResourcesLocator.resolvedResourcesDirectory(
            existingEnvironmentValue: customRoot.appendingPathComponent("ghostty", isDirectory: true).path,
            resourcesURL: fixture.resourcesURL
        )

        #expect(resolved?.path == customRoot.appendingPathComponent("ghostty", isDirectory: true).path)
    }

    @Test("resolved resources directory falls back to bundled resources when environment path is unusable")
    func resolvedResourcesDirectoryFallsBackToBundle() throws {
        let fixture = try GhosttyResourcesFixture()
        defer { fixture.cleanup() }

        let invalidPath = fixture.rootURL.appendingPathComponent("missing/ghostty", isDirectory: true).path
        let resolved = GhosttyResourcesLocator.resolvedResourcesDirectory(
            existingEnvironmentValue: invalidPath,
            resourcesURL: fixture.resourcesURL
        )

        #expect(resolved?.path == fixture.ghosttyURL.path)
    }
}

private struct GhosttyResourcesFixture {
    let rootURL: URL
    let resourcesURL: URL
    let ghosttyURL: URL

    init() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resourcesURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
        let ghosttyURL = resourcesURL.appendingPathComponent("ghostty", isDirectory: true)
        let terminfoURL = resourcesURL.appendingPathComponent("terminfo/78", isDirectory: true)

        try FileManager.default.createDirectory(at: ghosttyURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: terminfoURL, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: terminfoURL.appendingPathComponent("xterm-ghostty", isDirectory: false).path,
            contents: Data("terminfo".utf8)
        )

        self.rootURL = rootURL
        self.resourcesURL = resourcesURL
        self.ghosttyURL = ghosttyURL
    }

    func makeAlternateResourcesRoot(named name: String) throws -> URL {
        let otherResourcesURL = rootURL.appendingPathComponent(name, isDirectory: true)
        let ghosttyURL = otherResourcesURL.appendingPathComponent("ghostty", isDirectory: true)
        let terminfoURL = otherResourcesURL.appendingPathComponent("terminfo/78", isDirectory: true)
        try FileManager.default.createDirectory(at: ghosttyURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: terminfoURL, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: terminfoURL.appendingPathComponent("xterm-ghostty", isDirectory: false).path,
            contents: Data("terminfo".utf8)
        )
        return otherResourcesURL
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
