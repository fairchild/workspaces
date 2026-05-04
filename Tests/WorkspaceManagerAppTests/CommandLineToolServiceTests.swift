import Foundation
import Testing

@testable import WorkspaceManager

@Suite("CommandLineToolService", .serialized)
struct CommandLineToolServiceTests {
    @Test("Status is installed when PATH resolves to the bundled launcher")
    func installedWhenPathResolvesToBundledLauncher() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        try fileManager.createDirectory(at: fixture.primaryBin, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: fixture.primaryBin.appendingPathComponent("workspaces", isDirectory: false),
            withDestinationURL: fixture.sourceCommandURL
        )

        let service = makeService(
            fileManager: fileManager,
            sourceCommandURL: fixture.sourceCommandURL,
            preferredInstallDirectories: [fixture.primaryBin],
            pathDirectories: [fixture.primaryBin]
        )

        let status = service.status()

        #expect(status.availability == .installed)
        #expect(status.reason == .active)
        #expect(status.commandPath == fixture.primaryBin.appendingPathComponent("workspaces").path)
        #expect(status.primaryAction == nil)
    }

    @Test("Missing command offers install at the preferred location")
    func missingCommandOffersInstall() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        try fileManager.createDirectory(at: fixture.primaryBin, withIntermediateDirectories: true)

        let service = makeService(
            fileManager: fileManager,
            sourceCommandURL: fixture.sourceCommandURL,
            preferredInstallDirectories: [fixture.primaryBin],
            pathDirectories: [fixture.primaryBin]
        )

        let status = service.status()

        #expect(status.availability == .notInstalled)
        #expect(status.reason == .missing)
        #expect(status.primaryAction == .install)
        #expect(status.commandPath == fixture.primaryBin.appendingPathComponent("workspaces").path)
        #expect(status.setupCommand?.contains("export PATH=") == false)
    }

    @Test("Different target offers repair")
    func differentTargetOffersRepair() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        try fileManager.createDirectory(at: fixture.primaryBin, withIntermediateDirectories: true)
        let otherCommandURL = try makeExecutable(
            at: fixture.root
                .appendingPathComponent("Other.app", isDirectory: true)
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent("workspaces", isDirectory: false),
            fileManager: fileManager
        )
        try fileManager.createSymbolicLink(
            at: fixture.primaryBin.appendingPathComponent("workspaces", isDirectory: false),
            withDestinationURL: otherCommandURL
        )

        let service = makeService(
            fileManager: fileManager,
            sourceCommandURL: fixture.sourceCommandURL,
            preferredInstallDirectories: [fixture.primaryBin],
            pathDirectories: [fixture.primaryBin]
        )

        let status = service.status()

        #expect(status.availability == .notInstalled)
        #expect(
            status.reason
                == .differentTarget(
                    existingTargetPath: otherCommandURL.standardizedFileURL.resolvingSymlinksInPath().path)
        )
        #expect(status.primaryAction == .repair)
    }

    @Test("Managed launcher outside PATH asks for PATH update")
    func managedLauncherOutsidePathAsksForPathUpdate() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        try fileManager.createDirectory(at: fixture.primaryBin, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: fixture.primaryBin.appendingPathComponent("workspaces", isDirectory: false),
            withDestinationURL: fixture.sourceCommandURL
        )

        let service = makeService(
            fileManager: fileManager,
            sourceCommandURL: fixture.sourceCommandURL,
            preferredInstallDirectories: [fixture.primaryBin],
            pathDirectories: [fixture.secondaryBin]
        )

        let status = service.status()

        #expect(status.availability == .notInstalled)
        #expect(status.reason == .missingFromPath)
        #expect(status.primaryAction == nil)
        #expect(status.setupCommand?.contains("export PATH=") == true)
    }

    @Test("Shadowed launcher keeps the linked path and suggests prepending PATH")
    func shadowedLauncherSuggestsPrependingPath() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        try fileManager.createDirectory(at: fixture.primaryBin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fixture.secondaryBin, withIntermediateDirectories: true)
        _ = try makeExecutable(
            at: fixture.primaryBin.appendingPathComponent("workspaces", isDirectory: false),
            fileManager: fileManager
        )
        try fileManager.createSymbolicLink(
            at: fixture.secondaryBin.appendingPathComponent("workspaces", isDirectory: false),
            withDestinationURL: fixture.sourceCommandURL
        )

        let service = makeService(
            fileManager: fileManager,
            sourceCommandURL: fixture.sourceCommandURL,
            preferredInstallDirectories: [fixture.secondaryBin],
            pathDirectories: [fixture.primaryBin, fixture.secondaryBin]
        )

        let status = service.status()

        #expect(status.availability == .notInstalled)
        #expect(
            status.reason == .shadowedByOtherCommand(path: fixture.primaryBin.appendingPathComponent("workspaces").path)
        )
        #expect(status.commandPath == fixture.secondaryBin.appendingPathComponent("workspaces").path)
        #expect(status.primaryAction == nil)
        #expect(status.setupCommand?.contains("export PATH=") == true)
    }

    @Test("Install creates the symlink and returns installed state")
    func installCreatesSymlink() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        try fileManager.createDirectory(at: fixture.primaryBin, withIntermediateDirectories: true)

        let service = makeService(
            fileManager: fileManager,
            sourceCommandURL: fixture.sourceCommandURL,
            preferredInstallDirectories: [fixture.primaryBin],
            pathDirectories: [fixture.primaryBin]
        )

        let status = try service.installOrRepair()

        #expect(status.availability == .installed)
        #expect(status.commandPath == fixture.primaryBin.appendingPathComponent("workspaces").path)
        #expect(
            fixture.primaryBin
                .appendingPathComponent("workspaces", isDirectory: false)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
                == fixture.sourceCommandURL.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    private func makeService(
        fileManager: FileManager,
        sourceCommandURL: URL,
        preferredInstallDirectories: [URL],
        pathDirectories: [URL]
    ) -> CommandLineToolService {
        CommandLineToolService(
            fileManager: fileManager,
            environment: [
                "PATH": pathDirectories.map(\.path).joined(separator: ":"),
                "HOME": pathDirectories.first?.deletingLastPathComponent().path
                    ?? fileManager.homeDirectoryForCurrentUser.path,
            ],
            sourceCommandURL: sourceCommandURL,
            preferredInstallDirectories: preferredInstallDirectories,
            homeDirectoryURL: fileManager.homeDirectoryForCurrentUser
        )
    }

    private func makeFixture(fileManager: FileManager) throws -> Fixture {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("wm-cli-service-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceCommandURL = try makeExecutable(
            at:
                root
                .appendingPathComponent("WorkSpaces.app", isDirectory: true)
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent("workspaces", isDirectory: false),
            fileManager: fileManager
        )

        return Fixture(
            root: root,
            sourceCommandURL: sourceCommandURL,
            primaryBin: root.appendingPathComponent("primary-bin", isDirectory: true),
            secondaryBin: root.appendingPathComponent("secondary-bin", isDirectory: true)
        )
    }

    private func makeExecutable(at url: URL, fileManager: FileManager) throws -> URL {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private struct Fixture {
        let root: URL
        let sourceCommandURL: URL
        let primaryBin: URL
        let secondaryBin: URL
    }
}
