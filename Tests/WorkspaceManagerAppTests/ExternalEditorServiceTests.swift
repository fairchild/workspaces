//
//  ExternalEditorServiceTests.swift
//  WorkspaceManagerAppTests
//
//  Verifies Zed-first "open project + active file" launch behavior.
//

import Darwin
import Foundation
import Testing

@testable import WorkspaceManager

@Suite("ExternalEditorService", .serialized)
struct ExternalEditorServiceTests {
    @Test("Environment override for Zed app path is honored")
    func environmentOverrideForZedAppPathIsHonored() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        let environmentKey = "WORKSPACES_EDITOR_ZED_APP_PATH"
        let previousValue = ProcessInfo.processInfo.environment[environmentKey]
        setEnvironmentValue(fixture.appURL.path, key: environmentKey)
        defer { setEnvironmentValue(previousValue, key: environmentKey) }

        var launchedExecutable: String?

        let service = ExternalEditorService(
            fileManager: fileManager,
            launchProcess: { executable, _ in
                launchedExecutable = executable
            }
        )

        try service.open(projectRootURL: fixture.projectRootURL, editor: .zed)

        #expect(launchedExecutable == fixture.cliURL.path)
    }

    @Test("Opening in Zed launches project root and file path")
    func openingInZedLaunchesProjectAndFile() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        var launchedExecutable: String?
        var launchedArguments: [String]?

        let service = ExternalEditorService(
            fileManager: fileManager,
            resolveApplicationURL: { _ in fixture.appURL },
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
            resolveApplicationURL: { _ in fixture.appURL },
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
            resolveApplicationURL: { _ in fixture.appURL },
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
            resolveApplicationURL: { _ in fixture.appURL },
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
            resolveApplicationURL: { _ in fixture.appURL },
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
            resolveApplicationURL: { _ in fixture.appURL },
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
            resolveApplicationURL: { _ in fixture.appURL },
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

    @Test("Opening in VS Code launches correct CLI path")
    func openingInVSCodeLaunchesCorrectCLIPath() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager, editor: .vscode)
        defer { try? fileManager.removeItem(at: fixture.root) }

        var launchedExecutable: String?
        var launchedArguments: [String]?

        let service = ExternalEditorService(
            fileManager: fileManager,
            resolveApplicationURL: { _ in fixture.appURL },
            launchProcess: { executable, arguments in
                launchedExecutable = executable
                launchedArguments = arguments
            }
        )

        try service.open(
            projectRootURL: fixture.projectRootURL,
            fileURL: fixture.fileURL,
            editor: .vscode
        )

        #expect(launchedExecutable == fixture.cliURL.path)
        #expect(launchedArguments == [fixture.projectRootURL.path, fixture.fileURL.path])
    }

    @Test("Opening in Cursor launches correct CLI path")
    func openingInCursorLaunchesCorrectCLIPath() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager, editor: .cursor)
        defer { try? fileManager.removeItem(at: fixture.root) }

        var launchedExecutable: String?

        let service = ExternalEditorService(
            fileManager: fileManager,
            resolveApplicationURL: { _ in fixture.appURL },
            launchProcess: { executable, _ in
                launchedExecutable = executable
            }
        )

        try service.open(projectRootURL: fixture.projectRootURL, editor: .cursor)

        #expect(launchedExecutable == fixture.cliURL.path)
    }

    @Test("Opening in Sublime Text launches correct CLI path")
    func openingInSublimeTextLaunchesCorrectCLIPath() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager, editor: .sublimeText)
        defer { try? fileManager.removeItem(at: fixture.root) }

        var launchedExecutable: String?

        let service = ExternalEditorService(
            fileManager: fileManager,
            resolveApplicationURL: { _ in fixture.appURL },
            launchProcess: { executable, _ in
                launchedExecutable = executable
            }
        )

        try service.open(projectRootURL: fixture.projectRootURL, editor: .sublimeText)

        #expect(launchedExecutable == fixture.cliURL.path)
    }

    @Test("Missing editor returns editorNotInstalled for each editor ID")
    func missingEditorReturnsEditorNotInstalled() throws {
        let fileManager = FileManager.default
        let fixture = try makeFixture(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixture.root) }

        let service = ExternalEditorService(
            fileManager: fileManager,
            resolveApplicationURL: { _ in nil },
            launchProcess: { _, _ in }
        )

        for editor in ExternalEditorID.allCases {
            do {
                try service.open(projectRootURL: fixture.projectRootURL, editor: editor)
                Issue.record("Expected editorNotInstalled for \(editor.displayName)")
            } catch let error as ExternalEditorError {
                #expect(error == .editorNotInstalled(editor))
            }
        }
    }

    @Test("availableEditors includes all editor IDs")
    func availableEditorsIncludesAllEditorIDs() {
        let service = ExternalEditorService(
            resolveApplicationURL: { _ in nil },
            launchProcess: { _, _ in }
        )

        let editorIDs = Set(service.availableEditors.map(\.id))
        let allIDs = Set(ExternalEditorID.allCases)
        #expect(editorIDs == allIDs)
    }

    private struct EditorFixture {
        let root: URL
        let projectRootURL: URL
        let fileURL: URL
        let appURL: URL
        let cliURL: URL
    }

    private static let editorCLIPaths: [ExternalEditorID: (appName: String, cliRelativePath: String)] = [
        .zed: ("Zed.app", "Contents/MacOS/cli"),
        .vscode: ("VSCode.app", "Contents/Resources/app/bin/code"),
        .cursor: ("Cursor.app", "Contents/Resources/app/bin/cursor"),
        .sublimeText: ("SublimeText.app", "Contents/SharedSupport/bin/subl"),
    ]

    private func makeFixture(
        fileManager: FileManager,
        editor: ExternalEditorID = .zed
    ) throws -> EditorFixture {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("workspace-manager-editor-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let projectRootURL = root.appendingPathComponent("repo", isDirectory: true)
        try fileManager.createDirectory(at: projectRootURL, withIntermediateDirectories: true)

        let sourceDirectory = projectRootURL.appendingPathComponent("src", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let fileURL = sourceDirectory.appendingPathComponent("main.swift")
        try Data("print(\"hello\")\n".utf8).write(to: fileURL)

        let spec = Self.editorCLIPaths[editor]!
        let appURL = root.appendingPathComponent(spec.appName, isDirectory: true)
        let cliURL = appURL.appendingPathComponent(spec.cliRelativePath)
        let cliDirectory = cliURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: cliDirectory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: cliURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)

        return EditorFixture(
            root: root,
            projectRootURL: projectRootURL.standardizedFileURL.resolvingSymlinksInPath(),
            fileURL: fileURL.standardizedFileURL.resolvingSymlinksInPath(),
            appURL: appURL.standardizedFileURL.resolvingSymlinksInPath(),
            cliURL: cliURL.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    private struct StubLaunchError: LocalizedError {
        let reason: String

        var errorDescription: String? { reason }
    }

    private func setEnvironmentValue(_ value: String?, key: String) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}
