//
//  MainWindowSelectionControllerTests.swift
//  WorkspaceManagerAppTests
//
//  Covers the main window's selection cluster as behavior rather than as wiring: which
//  collaborators a selection touches and in what order, which branches attach a terminal and
//  which deliberately do not, and how a selection the model no longer contains is repaired.
//

// swift-format-ignore-file: NeverForceUnwrap
// Fixtures force-unwrap known-good literals; a failure here is a loud test crash, not a user risk.
import Foundation
import SwiftData
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

/// Records the focus contract's calls in order, standing in for `TerminalFocusCoordinator` so
/// selection can be exercised without an AppKit window or an app activation.
@MainActor
private final class FocusRequesterSpy: MainWindowTerminalFocusRequesting {
    private(set) var events: [String] = []
    private(set) var focusedSessionIDs: [UUID?] = []
    private(set) var lastOnTargetFocused: (() -> Void)?

    func cancelPendingFocusRequest(reason: String) {
        events.append("cancel_focus(\(reason))")
    }

    func cancelPendingRepoClickMeasurement(reason: String) {
        events.append("cancel_repo_measurement(\(reason))")
    }

    func beginRepoClickMeasurement(sessionID: UUID, repoPath: String) {
        events.append("begin_repo_measurement")
    }

    func completeRepoClickMeasurement(sessionID: UUID, outcome: String) {
        events.append("complete_repo_measurement(\(outcome))")
    }

    func beginWorkspaceClickMeasurement(sessionID: UUID, workspacePath: String) {
        events.append("begin_workspace_measurement")
    }

    func completeWorkspaceClickMeasurement(sessionID: UUID, outcome: String) {
        events.append("complete_workspace_measurement(\(outcome))")
    }

    func requestMainTerminalFocus(
        targetSessionID: UUID?,
        activateApp: Bool,
        surfaceStore: SurfaceStore,
        activeSessionID: UUID?,
        onTargetFocused: (() -> Void)?
    ) {
        events.append("request_focus")
        focusedSessionIDs.append(targetSessionID)
        lastOnTargetFocused = onTargetFocused
    }
}

@MainActor
private final class StateBox {
    var state = MainWindowViewState()
    var lastSurfaceRawValue = ""
}

/// Answers a launch spec (or fails) only after running the test's hook on the main actor.
/// That hook is the seam for "the selection moved on while the provider was working": it runs
/// inside the controller's `await`, so the re-check that follows is ordered by the language
/// rather than by a sleep.
private actor GatedLaunchSpecProvider: WorkspaceProviderProtocol {
    nonisolated let descriptor = WorkspaceProviderDescriptor(
        id: "gated",
        displayName: "Gated",
        description: "Answers a terminal launch spec after running the test's hook."
    )

    private let spec: TerminalLaunchSpec?
    private let whileWorking: @MainActor @Sendable () -> Void

    init(spec: TerminalLaunchSpec?, whileWorking: @escaping @MainActor @Sendable () -> Void) {
        self.spec = spec
        self.whileWorking = whileWorking
    }

    func availability() async -> WorkspaceProviderAvailability { .available }

    nonisolated func sessionKey(for workspace: WorkspaceProviderTarget) -> HostTerminalSessionKey {
        .hostPath(workspace.workspaceURL.path)
    }

    func createWorkspace(
        request: WorkspaceProviderCreationRequest,
        workspaceService: any WorkspaceServiceProtocol,
        progress: WorkspaceProviderProgressHandler?,
        persist: WorkspaceProviderPersistenceHandler?
    ) async throws -> WorkspaceProviderCreationResult {
        throw WorkspaceProviderError.unavailable("Not used in this test.")
    }

    func terminalLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> TerminalLaunchSpec {
        await MainActor.run { whileWorking() }
        guard let spec else {
            throw WorkspaceProviderError.unavailable("Provider failed after the hook ran.")
        }
        return spec
    }
}

/// Every effect the controller drives through a closure, in call order.
@MainActor
private final class EffectLog {
    private(set) var entries: [String] = []
    private(set) var navigationDestinations: [MainWindowNavigationDestination] = []
    private(set) var activatedKeys: [HostTerminalSessionKey] = []
    private(set) var activatedDirectories: [URL] = []
    private(set) var continuityWrites: [(kind: TerminalContinuityManifest.TargetKind, root: URL, launch: URL)] = []
    private(set) var errors: [String] = []

    func record(_ entry: String) { entries.append(entry) }
    func record(navigation: MainWindowNavigationDestination) {
        entries.append("navigate(\(label(for: navigation)))")
        navigationDestinations.append(navigation)
    }
    func record(key: HostTerminalSessionKey, directory: URL) {
        entries.append("activate_session")
        activatedKeys.append(key)
        activatedDirectories.append(directory)
    }
    func record(kind: TerminalContinuityManifest.TargetKind, root: URL, launch: URL) {
        entries.append("persist_continuity(\(kind.rawValue))")
        continuityWrites.append((kind, root, launch))
    }
    func record(error: String) {
        entries.append("error")
        errors.append(error)
    }

    private func label(for destination: MainWindowNavigationDestination) -> String {
        switch destination {
        case .repoOverview: return "repo_overview"
        case .repoTerminal: return "repo_terminal"
        case .workspaceTerminal: return "workspace_terminal"
        case .webView: return "web_view"
        }
    }
}

@MainActor
@Suite("MainWindowSelectionController")
struct MainWindowSelectionControllerTests {
    // MARK: - Fixtures

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeRepoDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-controller-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private struct Harness {
        let controller: MainWindowSelectionController
        let focus: FocusRequesterSpy
        let effects: EffectLog
        let box: StateBox
    }

    private func makeHarness(
        repos: [Repo] = [],
        webSources: [WebSource] = [],
        selectedWorkspace: Workspace? = nil,
        selectedWebSource: WebSource? = nil,
        selectedRepoForLanding: Repo? = nil,
        restoredRepoDirectory: URL? = nil,
        restoredWorkspaceDirectory: URL? = nil,
        context: ModelContext
    ) -> Harness {
        let focus = FocusRequesterSpy()
        let effects = EffectLog()
        let box = StateBox()
        let controller = MainWindowSelectionController(
            dependencies: MainWindowSelectionController.Dependencies(
                state: Binding(get: { box.state }, set: { box.state = $0 }),
                lastSurfaceRawValue: Binding(
                    get: { box.lastSurfaceRawValue },
                    set: { box.lastSurfaceRawValue = $0 }
                ),
                repos: { repos },
                webSources: { webSources },
                selectedWorkspace: { selectedWorkspace },
                selectedWebSource: { selectedWebSource },
                selectedRepoForLanding: { selectedRepoForLanding },
                tileTreeStore: TileTreeStore(),
                focusCoordinator: focus,
                smokeDriver: SmokeScenarioDriver(environment: [:]),
                webDetailSurfaceStore: SurfaceStore(),
                providerRegistry: WorkspaceProviderRegistry(providers: []),
                providerSetupActionRunner: WorkspaceProviderSetupActionRunner(
                    coordinator: WorkspaceProviderSetupCoordinator()
                ),
                bootstrapController: MainWindowBootstrapController(),
                modelContext: context,
                abandonPendingRemoteConnection: { effects.record("abandon(\($0))") },
                applyNavigationDestination: { effects.record(navigation: $0) },
                markRepoAccessed: { _ in effects.record("mark_repo") },
                markWorkspaceAccessed: { _ in effects.record("mark_workspace") },
                markWebSourceAccessed: { _ in effects.record("mark_web_source") },
                acknowledgeAttention: { _ in effects.record("acknowledge_attention") },
                acknowledgeAgentSession: { _ in effects.record("acknowledge_agent_session") },
                activateHostSession: MainWindowHostSessionActivator { key, directory, _ in
                    effects.record(key: key, directory: directory)
                    return HostTerminalSession(key: key, directory: directory)
                },
                persistTerminalContinuity: { kind, _, root, launch in
                    effects.record(kind: kind, root: root, launch: launch)
                },
                restoredLaunchDirectoryForRepo: { _ in restoredRepoDirectory },
                restoredLaunchDirectoryForWorkspace: { _ in restoredWorkspaceDirectory },
                clearCodePreview: { effects.record("clear_code_preview") },
                presentWorkspaceOperationError: { effects.record(error: $0) }
            )
        )
        return Harness(controller: controller, focus: focus, effects: effects, box: box)
    }

    // MARK: - Repo selection

    @Test("Selecting a repo overview navigates without attaching a terminal")
    func repoOverviewDoesNotAttachTerminal() throws {
        let container = try makeContainer()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let harness = makeHarness(repos: [repo], context: ModelContext(container))

        harness.controller.selectRepoOverview(repo)

        #expect(harness.effects.entries == ["abandon(repo_overview_selected)", "mark_repo", "navigate(repo_overview)"])
        #expect(harness.focus.events == ["cancel_focus(repo_overview_selected)"])
        #expect(harness.effects.activatedKeys.isEmpty)
    }

    @Test("Selecting a repo terminal attaches, records, navigates, persists, then requests focus")
    func repoTerminalSelectionRunsFullSequence() throws {
        let container = try makeContainer()
        let repoRoot = try makeRepoDirectory("alpha")
        let repo = Repo(name: "alpha", localPath: repoRoot)
        let harness = makeHarness(repos: [repo], context: ModelContext(container))

        harness.controller.selectRepoTerminal(repo)

        #expect(
            harness.effects.entries == [
                "abandon(repo_terminal_selected)",
                "activate_session",
                "mark_repo",
                "acknowledge_attention",
                "navigate(repo_terminal)",
                "persist_continuity(repo)",
            ]
        )
        #expect(harness.effects.activatedKeys == [.repoPath(repoRoot.path)])
        #expect(harness.effects.activatedDirectories == [repoRoot])
        #expect(harness.focus.events.last == "request_focus")
        #expect(harness.focus.focusedSessionIDs.count == 1)

        // The focus callback closes the click measurement — the measurement only completes on a
        // surface that actually took focus, never on the request itself.
        #expect(!harness.focus.events.contains("complete_repo_measurement(focused)"))
        harness.focus.lastOnTargetFocused?()
        #expect(harness.focus.events.contains("complete_repo_measurement(focused)"))
    }

    @Test("A preferred directory inside the repo becomes the launch directory; the root stays the root")
    func repoTerminalHonoursPreferredDirectory() throws {
        let container = try makeContainer()
        let repoRoot = try makeRepoDirectory("alpha")
        let nested = repoRoot.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let repo = Repo(name: "alpha", localPath: repoRoot)
        let harness = makeHarness(repos: [repo], context: ModelContext(container))

        harness.controller.selectRepoTerminal(repo, preferredDirectory: nested)

        #expect(harness.effects.activatedDirectories == [nested])
        let write = try #require(harness.effects.continuityWrites.first)
        #expect(write.root == repoRoot)
        #expect(write.launch == nested)
    }

    @Test("A preferred directory outside the repo falls back to the repo root")
    func repoTerminalRejectsEscapedPreferredDirectory() throws {
        let container = try makeContainer()
        let repoRoot = try makeRepoDirectory("alpha")
        let outside = try makeRepoDirectory("elsewhere")
        let repo = Repo(name: "alpha", localPath: repoRoot)
        let harness = makeHarness(repos: [repo], context: ModelContext(container))

        harness.controller.selectRepoTerminal(repo, preferredDirectory: outside)

        #expect(harness.effects.activatedDirectories == [repoRoot])
    }

    // MARK: - Workspace selection

    @Test("Selecting a local workspace attaches its own scope and persists workspace continuity")
    func localWorkspaceSelectionAttachesWorkspaceScope() throws {
        let container = try makeContainer()
        let repoRoot = try makeRepoDirectory("alpha")
        let workspaceRoot = try makeRepoDirectory("feature-a")
        let repo = Repo(name: "alpha", localPath: repoRoot)
        let workspace = Workspace(name: "feature-a", path: workspaceRoot, sourceRepo: repo)
        let harness = makeHarness(repos: [repo], context: ModelContext(container))

        harness.controller.selectWorkspace(workspace)

        #expect(harness.effects.activatedKeys == [.hostPath(workspaceRoot.path)])
        #expect(harness.effects.continuityWrites.first?.kind == .workspace)
        #expect(harness.effects.entries.contains("navigate(workspace_terminal)"))
        #expect(harness.focus.events.first == "cancel_repo_measurement(workspace_selected)")
    }

    @Test("Selecting an archived workspace lands on its repo overview and attaches nothing")
    func archivedWorkspaceFallsBackToRepoOverview() throws {
        let container = try makeContainer()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "old",
            path: URL(fileURLWithPath: "/tmp/alpha/old"),
            sourceRepo: repo,
            status: .archived
        )
        let harness = makeHarness(repos: [repo], context: ModelContext(container))

        harness.controller.selectWorkspace(workspace)

        #expect(harness.effects.entries == ["abandon(archived_workspace_selected)", "navigate(repo_overview)"])
        #expect(harness.effects.activatedKeys.isEmpty)
    }

    @Test("An archived workspace with no source repo clears the selection instead of navigating")
    func archivedOrphanWorkspaceClearsSelection() throws {
        let container = try makeContainer()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "orphan",
            path: URL(fileURLWithPath: "/tmp/orphan"),
            sourceRepo: repo,
            status: .archived
        )
        // The repo relationship is optional on the model, so an archived workspace can outlive its
        // repo; that is the branch under test.
        workspace.sourceRepo = nil
        let harness = makeHarness(context: ModelContext(container))
        harness.box.state.selectedWorkspace = MainWindowWorkspaceSelection(workspace: workspace)

        harness.controller.selectWorkspace(workspace)

        #expect(harness.box.state.selectedWorkspace == nil)
        #expect(harness.effects.navigationDestinations.isEmpty)
    }

    @Test("A provider-backed workspace with no registered provider reports the failure and attaches nothing")
    func unregisteredProviderReportsError() throws {
        let container = try makeContainer()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "remote",
            path: URL(fileURLWithPath: "/tmp/alpha/remote"),
            sourceRepo: repo,
            backendIdentifier: "nowhere"
        )
        let harness = makeHarness(repos: [repo], context: ModelContext(container))

        harness.controller.selectWorkspace(workspace)

        #expect(harness.effects.activatedKeys.isEmpty)
        #expect(harness.effects.errors == ["No workspace provider is registered for 'nowhere'."])
    }

    @Test("A workspace attached without selection warms only active local workspaces")
    func attachWithoutSelectionGuardsStatusAndBackend() throws {
        let container = try makeContainer()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let archived = Workspace(
            name: "old",
            path: URL(fileURLWithPath: "/tmp/old"),
            sourceRepo: repo,
            status: .archived
        )
        let remote = Workspace(
            name: "remote",
            path: URL(fileURLWithPath: "/tmp/remote"),
            sourceRepo: repo,
            backendIdentifier: "daytona"
        )
        let harness = makeHarness(context: ModelContext(container))

        #expect(harness.controller.attachWorkspaceSessionWithoutSelection(archived) == nil)
        #expect(harness.controller.attachWorkspaceSessionWithoutSelection(remote) == nil)
        #expect(harness.effects.navigationDestinations.isEmpty)
    }

    // MARK: - Provider connect

    /// A stopped remote workspace plus the spec a provider would answer for it.
    private func makeRemoteWorkspaceFixture() throws -> (workspace: Workspace, spec: TerminalLaunchSpec) {
        let workspaceRoot = try makeRepoDirectory("remote-a")
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "remote-a",
            path: workspaceRoot,
            sourceRepo: repo,
            status: .stopped,
            backendIdentifier: "daytona"
        )
        let spec = TerminalLaunchSpec(
            sessionKey: .hostPath(workspaceRoot.path),
            workingDirectory: workspaceRoot
        )
        return (workspace, spec)
    }

    @Test("A provider connect whose selection is still current opens the session it was asked for")
    func currentProviderConnectOpensSession() async throws {
        let container = try makeContainer()
        let fixture = try makeRemoteWorkspaceFixture()
        let harness = makeHarness(context: ModelContext(container))
        harness.box.state.columnVisibility = .detailOnly

        await harness.controller.connectToProviderBackedWorkspace(
            fixture.workspace,
            provider: GatedLaunchSpecProvider(spec: fixture.spec, whileWorking: {})
        )

        #expect(harness.effects.entries == ["activate_session", "acknowledge_attention"])
        #expect(harness.effects.activatedKeys == [fixture.spec.sessionKey])
        #expect(harness.focus.events == ["request_focus"])
        #expect(fixture.workspace.status == .active)
        #expect(harness.box.state.connectingWorkspaceID == nil)
        #expect(harness.box.state.columnVisibility == .all)
    }

    @Test("A provider connect that resolves after the selection moved on lands nothing")
    func staleProviderConnectLandsNothing() async throws {
        let container = try makeContainer()
        let fixture = try makeRemoteWorkspaceFixture()
        let harness = makeHarness(context: ModelContext(container))
        harness.box.state.columnVisibility = .detailOnly
        // What a later selection leaves behind: the in-flight token now names something else.
        let movedOnWorkspaceID = UUID()
        let box = harness.box

        await harness.controller.connectToProviderBackedWorkspace(
            fixture.workspace,
            provider: GatedLaunchSpecProvider(
                spec: fixture.spec,
                whileWorking: { box.state.connectingWorkspaceID = movedOnWorkspaceID }
            )
        )

        #expect(harness.effects.entries.isEmpty)
        #expect(harness.focus.events.isEmpty)
        #expect(fixture.workspace.status == .stopped)
        #expect(harness.box.state.columnVisibility == .detailOnly)
        // The abandoned connect leaves the newer selection's token alone.
        #expect(harness.box.state.connectingWorkspaceID == movedOnWorkspaceID)
    }

    @Test("A provider failure that arrives after the selection moved on reports nothing")
    func staleProviderFailureReportsNothing() async throws {
        let container = try makeContainer()
        let fixture = try makeRemoteWorkspaceFixture()
        let harness = makeHarness(context: ModelContext(container))
        let movedOnWorkspaceID = UUID()
        let box = harness.box

        await harness.controller.connectToProviderBackedWorkspace(
            fixture.workspace,
            provider: GatedLaunchSpecProvider(
                spec: nil,
                whileWorking: { box.state.connectingWorkspaceID = movedOnWorkspaceID }
            )
        )

        #expect(harness.effects.errors.isEmpty)
        #expect(harness.box.state.connectingWorkspaceID == movedOnWorkspaceID)
    }

    @Test("A provider failure for the current selection reports the error and clears the token")
    func currentProviderFailureReportsError() async throws {
        let container = try makeContainer()
        let fixture = try makeRemoteWorkspaceFixture()
        let harness = makeHarness(context: ModelContext(container))

        await harness.controller.connectToProviderBackedWorkspace(
            fixture.workspace,
            provider: GatedLaunchSpecProvider(spec: nil, whileWorking: {})
        )

        #expect(harness.effects.errors.count == 1)
        #expect(harness.box.state.connectingWorkspaceID == nil)
        #expect(harness.effects.activatedKeys.isEmpty)
    }

    // MARK: - Web source selection

    @Test("Selecting a web source clears an in-flight remote connection and navigates")
    func webSourceSelectionClearsConnectingWorkspace() throws {
        let container = try makeContainer()
        let source = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com"
        )
        let harness = makeHarness(webSources: [source], context: ModelContext(container))
        harness.box.state.connectingWorkspaceID = UUID()

        harness.controller.selectWebSource(source)

        #expect(harness.box.state.connectingWorkspaceID == nil)
        #expect(harness.effects.entries.contains("navigate(web_view)"))
        #expect(harness.effects.entries.contains("mark_web_source"))
        #expect(harness.effects.activatedKeys.isEmpty)
    }

    // MARK: - Reconciliation

    @Test("A removed workspace clears the selection and falls back to its repo overview")
    func removedWorkspaceFallsBackToRepoOverview() throws {
        let container = try makeContainer()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/feature-a"),
            sourceRepo: repo
        )
        // The lookup answers nil: the workspace is gone from the model but still selected.
        let harness = makeHarness(repos: [repo], selectedWorkspace: nil, context: ModelContext(container))
        harness.box.state.selectedWorkspace = MainWindowWorkspaceSelection(workspace: workspace)

        harness.controller.reconcileSelectionAfterModelChange()

        #expect(harness.box.state.selectedWorkspace == nil)
        #expect(harness.box.state.didResolveInitialSurface)
        #expect(harness.effects.entries.contains("clear_code_preview"))
        #expect(harness.effects.entries.contains("navigate(repo_overview)"))
    }

    @Test("A removed web source clears the last surface that named it and falls back to its owner repo")
    func removedWebSourceClearsLastSurfaceAndFallsBack() throws {
        let container = try makeContainer()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let source = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com",
            sourceRepo: repo
        )
        let harness = makeHarness(repos: [repo], selectedWebSource: nil, context: ModelContext(container))
        harness.box.state.selectedWebSource = MainWindowWebSourceSelection(source: source)
        harness.box.lastSurfaceRawValue = MainWindowLastSurface(kind: .webView, id: source.id).rawValue

        harness.controller.reconcileSelectionAfterModelChange()

        #expect(harness.box.state.selectedWebSource == nil)
        #expect(harness.box.lastSurfaceRawValue == "")
        #expect(harness.box.state.didResolveInitialSurface)
        #expect(harness.effects.entries.contains("navigate(repo_overview)"))
    }

    @Test("Reconciliation repairs only the first invalid selection it finds")
    func reconciliationStopsAfterRepairingWebSource() throws {
        let container = try makeContainer()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/feature-a"),
            sourceRepo: repo
        )
        let source = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com"
        )
        let harness = makeHarness(repos: [repo], context: ModelContext(container))
        harness.box.state.selectedWebSource = MainWindowWebSourceSelection(source: source)
        harness.box.state.selectedWorkspace = MainWindowWorkspaceSelection(workspace: workspace)

        harness.controller.reconcileSelectionAfterModelChange()

        // The web-source arm returned, so the workspace selection is still there for the next pass.
        #expect(harness.box.state.selectedWebSource == nil)
        #expect(harness.box.state.selectedWorkspace != nil)
    }

    // MARK: - Launch surfaces

    @Test("A restored workspace surface launches in the restored directory")
    func launchSurfaceUsesRestoredWorkspaceDirectory() throws {
        let container = try makeContainer()
        let workspaceRoot = try makeRepoDirectory("feature-a")
        let nested = workspaceRoot.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(name: "feature-a", path: workspaceRoot, sourceRepo: repo)
        let harness = makeHarness(
            repos: [repo],
            restoredWorkspaceDirectory: nested,
            context: ModelContext(container)
        )

        harness.controller.applyLaunchSurface(.workspace(workspace))

        #expect(harness.effects.activatedDirectories == [nested])
    }
}
