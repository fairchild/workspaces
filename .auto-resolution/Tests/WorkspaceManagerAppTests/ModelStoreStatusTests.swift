import Foundation
import SwiftData
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("ModelStoreBootstrapper")
struct ModelStoreBootstrapperTests {
    @Test("app-support store is selected when writable")
    func appSupportStoreSelectedWhenWritable() throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let result = ModelStoreBootstrapper.bootstrap(
            schema: appSchema,
            launchEnvironment: [:],
            currentDirectoryPath: tempDirectory.path,
            appSupportDirectoryProvider: { _ in
                tempDirectory.appendingPathComponent("app-support", isDirectory: true)
            }
        )

        let expectedPath =
            tempDirectory
            .appendingPathComponent("app-support", isDirectory: true)
            .path

        #expect(
            result.mode == .persistentAppSupport(path: expectedPath)
        )
        #expect(result.bootstrapErrors.isEmpty)
    }

    @Test("workspace-local fallback is selected when app-support resolution fails")
    func workspaceLocalFallbackSelectedWhenAppSupportFails() throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let result = ModelStoreBootstrapper.bootstrap(
            schema: appSchema,
            launchEnvironment: [:],
            currentDirectoryPath: tempDirectory.path,
            appSupportDirectoryProvider: { _ in
                struct ExpectedFailure: Error {}
                throw ExpectedFailure()
            }
        )

        let expectedPath =
            tempDirectory
            .appendingPathComponent(".workspacemanager-data", isDirectory: true)
            .path

        #expect(
            result.mode == .persistentWorkspaceLocal(path: expectedPath)
        )
        #expect(result.bootstrapErrors.count == 1)
    }

    @Test("in-memory mode is selected only after both persistent options fail")
    func inMemoryModeSelectedAfterPersistentFailures() throws {
        let tempDirectory = makeTemporaryDirectory()
        let blockingFile = tempDirectory.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blockingFile)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let result = ModelStoreBootstrapper.bootstrap(
            schema: appSchema,
            launchEnvironment: [:],
            currentDirectoryPath: blockingFile.path,
            appSupportDirectoryProvider: { _ in
                struct ExpectedFailure: Error {}
                throw ExpectedFailure()
            }
        )

        #expect(result.mode == .inMemoryDegraded)
        #expect(result.bootstrapErrors.count == 2)
    }
}

@Suite("ModelStoreStatusController")
@MainActor
struct ModelStoreStatusControllerTests {
    @Test("degraded warning appears only for in-memory degraded mode with failures")
    func degradedWarningVisibility() {
        let controller = ModelStoreStatusController()

        controller.apply(
            ModelStoreBootstrapResult(
                container: makeInMemoryContainer(),
                mode: .persistentAppSupport(path: "/tmp/store"),
                bootstrapErrors: []
            )
        )
        #expect(!controller.shouldShowDegradedWarning)

        controller.apply(
            ModelStoreBootstrapResult(
                container: makeInMemoryContainer(),
                mode: .inMemoryDegraded,
                bootstrapErrors: []
            )
        )
        #expect(!controller.shouldShowDegradedWarning)

        controller.apply(
            ModelStoreBootstrapResult(
                container: makeInMemoryContainer(),
                mode: .inMemoryDegraded,
                bootstrapErrors: ["primary failed"]
            )
        )
        #expect(controller.shouldShowDegradedWarning)
    }
}

private let appSchema = Schema([Repo.self, Workspace.self, WebSource.self])

private func makeInMemoryContainer() -> ModelContainer {
    try! ModelContainer(
        for: appSchema,
        configurations: [ModelConfiguration(schema: appSchema, isStoredInMemoryOnly: true)]
    )
}

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
