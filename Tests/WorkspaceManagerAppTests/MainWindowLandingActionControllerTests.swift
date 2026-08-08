//
//  MainWindowLandingActionControllerTests.swift
//  WorkspaceManagerAppTests
//
//  Covers the repo landing view's actions: what an unregistered provider reports instead of
//  creating, what a rejected URL leaves behind, and the sheet-presentation handshake that lets
//  the New Workspace sheet appear before its environment options resolve.
//

// swift-format-ignore-file: NeverForceUnwrap
// Fixtures force-unwrap known-good literals; a failure here is a loud test crash, not a user risk.
import Foundation
import SwiftData
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
private final class LandingBox {
    var repoForNewWorkspace: Repo?
    var isPreparingSheet = false
    var landingErrors: [String] = []
    var editorErrors: [String] = []
    var selectedWorkspaceIDs: [UUID] = []
    var selectedWebSourceIDs: [UUID] = []
    var refreshTriggers: [String] = []
    var didPrepareEnvironmentState = false
    /// `isPreparingSheet` sampled at each transition, so the test can assert the flag was raised
    /// and lowered rather than only that it ended false.
    var preparingTimeline: [Bool] = []
}

private final class StubEditorService: ExternalEditorServiceProtocol, @unchecked Sendable {
    var error: Error?

    var defaultEditor: ExternalEditorID { .vscode }
    var availableEditors: [ExternalEditorDescriptor] { [] }

    func open(projectRootURL: URL, editor: ExternalEditorID?) throws {
        if let error { throw error }
    }

    func open(projectRootURL: URL, fileURL: URL, editor: ExternalEditorID?) throws {
        if let error { throw error }
    }
}

private final class StubWorkspaceService: WorkspaceServiceProtocol, @unchecked Sendable {
    var workspacesRoot: URL { get async { URL(fileURLWithPath: "/tmp/workspaces") } }

    func createWorkspace(
        repoName: String,
        repoLocalURL: URL,
        name: String,
        fromRef: String?,
        progress: WorkspaceCreationProgressHandler?
    ) async throws -> NewWorkspaceInfo {
        throw WorkspaceProviderError.unavailable("stub")
    }

    @discardableResult
    func archiveWorkspace(at workspaceURL: URL) async throws -> URL {
        throw WorkspaceProviderError.unavailable("stub")
    }

    @discardableResult
    func unarchiveWorkspace(at workspaceURL: URL) async throws -> URL {
        throw WorkspaceProviderError.unavailable("stub")
    }

    func deleteWorkspace(at workspaceURL: URL, deleteFiles: Bool) async throws {}

    func runLifecycleScript(_ scriptName: String, in directory: URL) async throws -> WorkspaceService.ScriptResult {
        throw WorkspaceProviderError.unavailable("stub")
    }

    func getWorkspaceSize(at workspaceURL: URL) async throws -> Int64 { 0 }

    func sanitizeFilename(_ name: String) async -> String { name }
}

@MainActor
@Suite("MainWindowLandingActionController")
struct MainWindowLandingActionControllerTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeController(
        box: LandingBox,
        context: ModelContext,
        webSources: [WebSource] = [],
        editorService: StubEditorService = StubEditorService(),
        providers: [any WorkspaceProviderProtocol] = []
    ) -> MainWindowLandingActionController {
        MainWindowLandingActionController(
            dependencies: MainWindowLandingActionController.Dependencies(
                repoForNewWorkspace: Binding(
                    get: { box.repoForNewWorkspace },
                    set: { box.repoForNewWorkspace = $0 }
                ),
                isPreparingNewWorkspaceSheet: Binding(
                    get: { box.isPreparingSheet },
                    set: {
                        box.isPreparingSheet = $0
                        box.preparingTimeline.append($0)
                    }
                ),
                modelContext: context,
                workspaceService: StubWorkspaceService(),
                providerRegistry: WorkspaceProviderRegistry(providers: providers),
                providerSetupActionRunner: WorkspaceProviderSetupActionRunner(
                    coordinator: WorkspaceProviderSetupCoordinator()
                ),
                externalEditorService: editorService,
                webSources: { webSources },
                retireTerminalSessions: { _ in },
                selectWorkspace: { box.selectedWorkspaceIDs.append($0.id) },
                selectWebSource: { box.selectedWebSourceIDs.append($0.id) },
                abandonPendingRemoteConnection: { _ in },
                seedEnvironmentStateIfNeeded: { false },
                prepareEnvironmentStateForPresentation: { box.didPrepareEnvironmentState = true },
                refreshEnvironmentState: { box.refreshTriggers.append($0) },
                environmentOptionCount: { _ in 0 },
                lumeStateDescription: { "pending" },
                presentLandingError: { box.landingErrors.append($0) },
                presentOpenInEditorError: { box.editorErrors.append($0.localizedDescription) }
            )
        )
    }

    @Test("Creating with an unregistered provider reports the failure and creates nothing")
    func unregisteredProviderReportsLandingError() async throws {
        let container = try makeContainer()
        let box = LandingBox()
        let controller = makeController(box: box, context: ModelContext(container))
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))

        await controller.createWorkspace(
            repo: repo,
            name: "feature-a",
            nameSource: .manual,
            providerID: "nowhere",
            guestOS: nil
        )

        #expect(box.landingErrors == ["Workspace provider 'nowhere' is not registered."])
        #expect(box.selectedWorkspaceIDs.isEmpty)
    }

    @Test("Presenting the sheet binds the repo before options resolve and lowers the preparing flag")
    func presentingSheetBindsRepoThenClearsPreparingFlag() async throws {
        let container = try makeContainer()
        let box = LandingBox()
        let controller = makeController(box: box, context: ModelContext(container))
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))

        await controller.presentNewWorkspaceSheet(for: repo)
        // The refresh runs in a detached task; let it drain before asserting the flag came back down.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        #expect(box.repoForNewWorkspace?.id == repo.id)
        #expect(box.didPrepareEnvironmentState)
        #expect(box.preparingTimeline.first == true)
        #expect(box.preparingTimeline.last == false)
        #expect(box.refreshTriggers == ["landing_sheet_open"])
    }

    @Test("Adding a valid web source inserts it and makes it the selection")
    func addWebSourceInsertsAndSelects() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let box = LandingBox()
        let controller = makeController(box: box, context: context)

        controller.addWebSource(
            rawURL: "https://docs.example.com",
            displayName: "Docs",
            additionalAllowedDomainsRaw: "",
            target: .global
        )

        let stored = try context.fetch(FetchDescriptor<WebSource>())
        #expect(stored.count == 1)
        #expect(box.selectedWebSourceIDs.count == 1)
        #expect(box.landingErrors.isEmpty)
    }

    @Test("A rejected URL reports the validation message and inserts nothing")
    func addWebSourceRejectsInvalidURL() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let box = LandingBox()
        let controller = makeController(box: box, context: context)

        controller.addWebSource(
            rawURL: "not a url",
            displayName: "Broken",
            additionalAllowedDomainsRaw: "",
            target: .global
        )

        let stored = try context.fetch(FetchDescriptor<WebSource>())
        #expect(stored.isEmpty)
        #expect(box.selectedWebSourceIDs.isEmpty)
        #expect(!box.landingErrors.isEmpty)
    }

    @Test("A duplicate web source is refused, leaving the existing one untouched")
    func addWebSourceRefusesDuplicate() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let existing = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com"
        )
        let box = LandingBox()
        let controller = makeController(box: box, context: context, webSources: [existing])

        controller.addWebSource(
            rawURL: "https://docs.example.com",
            displayName: "Docs again",
            additionalAllowedDomainsRaw: "",
            target: .global
        )

        let stored = try context.fetch(FetchDescriptor<WebSource>())
        #expect(stored.isEmpty)
        #expect(box.selectedWebSourceIDs.isEmpty)
        #expect(!box.landingErrors.isEmpty)
    }

    @Test("An editor launch failure surfaces through the editor error presenter, not the landing one")
    func editorFailureUsesEditorPresenter() throws {
        let container = try makeContainer()
        let box = LandingBox()
        let editorService = StubEditorService()
        editorService.error = ExternalEditorError.editorNotInstalled(.vscode)
        let controller = makeController(box: box, context: ModelContext(container), editorService: editorService)
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/feature-a"),
            sourceRepo: repo
        )

        controller.openWorkspaceInDefaultEditor(workspace)

        #expect(box.editorErrors.count == 1)
        #expect(box.landingErrors.isEmpty)
    }
}
