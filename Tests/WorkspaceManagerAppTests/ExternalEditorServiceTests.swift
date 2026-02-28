//
//  ExternalEditorServiceTests.swift
//  WorkspaceManagerAppTests
//
//  Verifies Zed-first "open project + active file" launch behavior.
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("ExternalEditorService")
struct ExternalEditorServiceTests {
    @Test("Opening in Zed launches project root and file path")
    func openingInZedLaunchesProjectAndFile() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        var launchedExecutable: String?
        var launchedArguments: [String]?

        let service = ExternalEditorService(
            fileManager: fileManager,
            resolveApplicationURL: { _ in fixture.zedAppURL },
            launchProcess: { executable, arguments in
                launchedExecutable = executable
                launchedArguments = arguments
            }
        )

        try service.open(
            projectRootURL: fixture.projectRootURL,
            fileURL: fixture.fileURL,
            editor: .zed
        )

        #expect(launchedExecutable == fixture.cliURL.path)
        #expect(launchedArguments == [fixture.projectRootURL.path, fixture.fileURL.path])
    }

    @Test("Opening repo without file launches only project root")
    func openingRepoWithoutFileLaunchesOnlyProjectRoot() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        var launchedArguments: [String]?

        let service = ExternalEditorService(
            fileManager: fileManager,
            resolveApplicationURL: { _ in fixture.zedAppURL },
            launchProcess: { _, arguments in
                launchedArguments = arguments
            }
        )

        try service.open(
            projectRootURL: fixture.projectRootURL,
            editor: .zed
        )

        #expect(launchedArguments == [fixture.projectRootURL.path])
    }

    @Test("Omitting editor uses default Zed launch behavior")
    func omittingEditorUsesDefaultZedLaunchBehavior() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        var launchedArguments: [String]?

        let service = ExternalEditorService(
            fileManager: fileManager,
            resolveApplicationURL: { _ in fixture.zedAppURL },
            launchProcess: { _, arguments in
                launchedArguments = arguments
            }
        )

        try service.open(
            projectRootURL: fixture.projectRootURL,
            fileURL: fixture.fileURL,
            editor: nil
        )

        #expect(launchedArguments == [fixture.projectRootURL.path, fixture.fileURL.path])
    }

    @Test("Missing Zed app returns editorNotInstalled")
    func missingZedAppReturnsEditorNotInstalled() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        let service = ExternalEditorService(
            fileManager: fileManager,
            resolveApplicationURL: { _ in nil },
            launchProcess: { _, _ in }
        )

        do {
            try service.open(
                projectRootURL: fixture.projectRootURL,
                fileURL: fixture.fileURL,
                editor: .zed
            )
            Issue.record("Expected editorNotInstalled error")
        } catch let error as ExternalEditorError {
            #expect(error == .editorNotInstalled(.zed))
        }
    }

    @Test("Missing target file returns fileNotFound before launch")
    func missingTargetFileReturnsFileNotFound() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        let missingFileURL = fixture.projectRootURL
            .appendingPathComponent("src/missing.swift")
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let service = ExternalEditorService(
            fileManager: fileManager,
            resolveApplicationURL: { _ in fixture.zedAppURL },
            launchProcess: { _, _ in
                Issue.record("Launch should not run when file is missing")
            }
        )

        do {
            try service.open(
                projectRootURL: fixture.projectRootURL,
                fileURL: missingFileURL,
                editor: .zed
            )
            Issue.record("Expected fileNotFound error")
        } catch let error as ExternalEditorError {
            #expect(error == .fileNotFound(missingFileURL))
        }
    }

    @Test("Target file outside project root is rejected before launch")
    func targetFileOutsideProjectRootIsRejected() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        let outsideFileURL = fixture.root
            .appendingPathComponent("outside.swift")
            .standardizedFileURL
            .resolvingSymlinksInPath()
        try Data("print(\"outside\")\n".utf8).write(to: outsideFileURL)

        let service = ExternalEditorService(
            fileManager: fileManager,
            resolveApplicationURL: { _ in fixture.zedAppURL },
            launchProcess: { _, _ in
                Issue.record("Launch should not run when file is outside project root")
            }
        )

        do {
            try service.open(
                projectRootURL: fixture.projectRootURL,
                fileURL: outsideFileURL,
                editor: .zed
            )
            Issue.record("Expected fileOutsideProject error")
        } catch let error as ExternalEditorError {
            #expect(error == .fileOutsideProject(projectRoot: fixture.projectRootURL, file: outsideFileURL))
        }
    }

    @Test("Missing project root returns projectRootNotFound")
    func missingProjectRootReturnsProjectRootNotFound() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        let missingProjectRoot = fixture.root
            .appendingPathComponent("missing-repo", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let service = ExternalEditorService(
            fileManager: fileManager,
            resolveApplicationURL: { _ in fixture.zedAppURL },
            launchProcess: { _, _ in
                Issue.record("Launch should not run when project root is missing")
            }
        )

        do {
            try service.open(
                projectRootURL: missingProjectRoot,
                editor: .zed
            )
            Issue.record("Expected projectRootNotFound error")
        } catch let error as ExternalEditorError {
            #expect(error == .projectRootNotFound(missingProjectRoot))
        }
    }

    @Test("Launch process failures map to launchFailed")
    func launchProcessFailuresMapToLaunchFailed() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        let service = ExternalEditorService(
            fileManager: fileManager,
            resolveApplicationURL: { _ in fixture.zedAppURL },
            launchProcess: { _, _ in
                throw StubLaunchError(reason: "stub launch failure")
            }
        )

        do {
            try service.open(
                projectRootURL: fixture.projectRootURL,
                fileURL: fixture.fileURL,
                editor: .zed
            )
            Issue.record("Expected launchFailed error")
        } catch let error as ExternalEditorError {
            #expect(error == .launchFailed(.zed, reason: "stub launch failure"))
        }
    }

    private func makeFixture(
        fileManager: FileManager
    ) throws -> (
        root: URL,
        projectRootURL: URL,
        fileURL: URL,
        zedAppURL: URL,
        cliURL: URL
    ) {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("workspace-manager-editor-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let projectRootURL = root.appendingPathComponent("repo", isDirectory: true)
        try fileManager.createDirectory(at: projectRootURL, withIntermediateDirectories: true)

        let sourceDirectory = projectRootURL.appendingPathComponent("src", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let fileURL = sourceDirectory.appendingPathComponent("main.swift")
        try Data("print(\"hello\")\n".utf8).write(to: fileURL)

        let zedAppURL = root.appendingPathComponent("Zed.app", isDirectory: true)
        let cliDirectory =
            zedAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        try fileManager.createDirectory(at: cliDirectory, withIntermediateDirectories: true)
        let cliURL = cliDirectory.appendingPathComponent("cli")
        try Data("#!/bin/sh\n".utf8).write(to: cliURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)

        return (
            root: root,
            projectRootURL: projectRootURL.standardizedFileURL.resolvingSymlinksInPath(),
            fileURL: fileURL.standardizedFileURL.resolvingSymlinksInPath(),
            zedAppURL: zedAppURL.standardizedFileURL.resolvingSymlinksInPath(),
            cliURL: cliURL.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    private struct StubLaunchError: LocalizedError {
        let reason: String

        var errorDescription: String? { reason }
    }
}
