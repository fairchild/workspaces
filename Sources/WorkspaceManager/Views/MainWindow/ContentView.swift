//
//  ContentView.swift
//  WorkspaceManager
//
//  Main three-column layout: Sidebar | Terminal | Right Pane
//

import AppKit
import SwiftData
import SwiftUI
import WorkspaceManagerCore
import os.log

private let workspaceProviderLog = Logger(subsystem: "com.cloudcompute.workspaces", category: "WorkspaceProvider")
private let uiFixtureLog = Logger(subsystem: "com.cloudcompute.workspaces", category: "UIFixtureSeeder")
private let archivedWorkspacePurgeLog = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "ArchivedWorkspacePurge"
)
private let perfLog = Logger(subsystem: "com.cloudcompute.workspaces", category: "PerformanceSignposts")
private let hostSessionLog = Logger(subsystem: "com.cloudcompute.workspaces", category: "HostSession")
private let restoreLog = Logger(subsystem: "com.cloudcompute.workspaces", category: "Restore")

private struct ModelSnapshot: Equatable {
    let repoIDs: [UUID]
    let workspaceIDs: [UUID]
    let webSourceIDs: [UUID]
}

/// One activation of the embedded web-next surface. `redirect` is the relative
/// path to land on after sign-in (`nil` = the app's default `/`); the unique
/// `id` keys the detail view so a fresh activation always re-navigates.
struct EmbeddedWebNextActivation: Equatable, Identifiable {
    let id = UUID()
    let redirect: String?

    static func == (lhs: EmbeddedWebNextActivation, rhs: EmbeddedWebNextActivation) -> Bool {
        lhs.id == rhs.id
    }

    /// Resolve the next activation. `forceFresh` (an explicit New Web Session)
    /// always yields a new activation — even for a repo already open — because
    /// the current pane may have navigated on to `/sessions/<id>` while its
    /// redirect still reads `/new?repo=…`. The plain shortcut is not force-fresh,
    /// so re-opening an already-shown surface with the same redirect is a no-op
    /// (`nil`) rather than a jarring re-mount.
    static func next(
        current: EmbeddedWebNextActivation?,
        redirect: String?,
        forceFresh: Bool
    ) -> EmbeddedWebNextActivation? {
        if !forceFresh, let current, current.redirect == redirect { return nil }
        return EmbeddedWebNextActivation(redirect: redirect)
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localStateStore) private var localStateStore
    @ExperimentalFeatureFlag(.restoreSessionsOnLaunch) private var restoreSessionsOnLaunchEnabled: Bool
    @Binding var deepLinkState: WorkspaceDeepLinkState
    @Binding var lastSurfaceRawValue: String
    @ObservedObject var appCommandState: AppCommandState
    @ObservedObject var tileTreeStore: TileTreeStore
    @ObservedObject var workspaceProviderSetupCoordinator: WorkspaceProviderSetupCoordinator
    /// Seam to the debug-only smoke harness; inert in release builds.
    let smokeDriver: SmokeScenarioDriver
    @Query(sort: \Repo.addedAt, order: .reverse) private var repos: [Repo]
    @Query(sort: \WebSource.addedAt, order: .reverse) private var webSources: [WebSource]
    @AppStorage(TerminalMultiplexingMode.storageKey)
    private var terminalMultiplexingModeRawValue: String = TerminalMultiplexingMode.defaultValue.rawValue
    @AppStorage(TerminalContinuityManifest.storageKey)
    private var terminalContinuityManifestRawValue = ""
    @AppStorage(NotificationConstants.enabledKey)
    private var notificationsEnabled = NotificationConstants.defaultEnabled
    @ExperimentalFeatureFlag(.minimalToolbar)
    private var minimalToolbarEnabled: Bool
    @Environment(\.externalEditorService) private var externalEditorService
    @Environment(\.lumeRuntimeService) private var lumeRuntimeService
    @Environment(\.webNextServerService) private var webNextServerService
    @EnvironmentObject private var modelStoreStatusController: ModelStoreStatusController
    @Environment(\.workspaceService) private var workspaceService
    @Environment(\.workspaceProviderRegistry) private var workspaceProviderRegistry
    @EnvironmentObject private var agentSessionRegistry: AgentSessionRegistry
    @EnvironmentObject private var workspaceStatusAggregator: WorkspaceStatusAggregator
    @ObservedObject private var notificationCoordinator = NotificationCoordinator.shared

    @State private var viewState = MainWindowViewState()
    @State private var errorPresenter = MainWindowErrorPresenter()
    @State private var repoForNewWorkspaceFromLanding: Repo?
    @State private var isPreparingLandingNewWorkspaceSheet = false
    @State private var webSourceCreationTarget: WebSourceCreationTarget?
    /// Non-nil while the embedded web-next surface is shown; takes precedence over
    /// the SwiftData selection in `detailContent`. Cleared whenever a repo /
    /// workspace / web source is selected (see `applyNavigationDestination`).
    @State private var embeddedWebNext: EmbeddedWebNextActivation?
    @State private var workspaceEnvironmentSheetState = WorkspaceEnvironmentSheetState.empty
    @State private var didScheduleInitialWorkspaceStatusSync = false
    @State private var didPrewarmPerfTerminalSurfaces = false
    @State private var workspaceOrphanState = WorkspaceOrphanReconciliationState()
    @State private var restoreState = MainWindowRestoreState()
    @AppStorage(TerminalRestoreBannerStorage.handledRunIDKey)
    private var restoreHandledRunID = ""
    @State private var isShowingFeedbackSheet = false
    @State private var accessRecorder = MainWindowAccessRecorder()
    @State private var presentedSessionSwitcherSnapshot: SessionSwitcherSnapshot?
    /// Code-preview navigation held back because the open editor has unsaved edits, pending the
    /// Save / Discard / Cancel prompt (#704 Phase 4).
    @State private var codePreviewNavigationState = CodePreviewNavigationState()
    @StateObject private var rightPaneStateStore = RightPaneStateStore()
    @StateObject private var automationWorkspaceCreateBridge = AutomationWorkspaceCreateGestureBridge()
    /// Seam store for the web main-content pane: a one-tile `SurfaceStore` domain. Source switches
    /// rebind `webDetailTileID` to a new `WebSurface` (identity-guarded); per-source `WebSurfaceStore`s
    /// inside keep each source's page alive through the deferred-release window.
    @State private var webDetailSurfaceStore = SurfaceStore()
    @State private var webDetailTileID = TileID()
    @StateObject private var terminalFocusCoordinator = TerminalFocusCoordinator()
    private let buildIdentity = AppBuildIdentity.current
    private let resolvedDefaultHostDirectory = HostTerminalDefaults.defaultWorkingDirectory()
        .standardizedFileURL
        .resolvingSymlinksInPath()
    private let bootstrapController = MainWindowBootstrapController()
    private let inspectorStateController = InspectorStateController()
    @State private var mainSelectionCoordinator = MainSelectionCoordinator()
    @State private var statusAggregationCoalescer = WorkspaceStatusAggregationCoalescer()
    private let navigationStateController = MainWindowNavigationStateController()
    private let surfaceResolutionController = MainWindowSurfaceResolutionController()
    private let launchActionHandler = MainWindowLaunchActionHandler()
    private let presentationController = MainWindowPresentationController()
    private let terminalSessionController = MainWindowTerminalSessionController()
    private let splitRoutingController = SplitRoutingController()
    private let tabRoutingController = TabRoutingController()
    private let workspaceEnvironmentOptionsController = WorkspaceEnvironmentOptionsController()
    private let workspaceOrphanController = WorkspaceOrphanReconciliationController()
    private let maintenanceController = MainWindowMaintenanceController()
    private let sessionSwitcherController = SessionSwitcherPresentationController()
    private let lifecycleController = MainWindowLifecycleController()
    private let codePreviewController = CodePreviewNavigationController()
    private let restoreController = MainWindowRestoreController()

    private var launchRepositoryService: LaunchRepositoryService {
        LaunchRepositoryService(modelContext: modelContext)
    }

    private var workspaceProviderSetupActionRunner: WorkspaceProviderSetupActionRunner {
        WorkspaceProviderSetupActionRunner(coordinator: workspaceProviderSetupCoordinator)
    }

    /// The selection cluster's collaborators, bound to this view's live state. Rebuilt per
    /// access — the closures must read the current `@Query` results and write the current
    /// `@State` boxes, not a snapshot taken when the view was first evaluated.
    private var selectionController: MainWindowSelectionController {
        MainWindowSelectionController(
            dependencies: MainWindowSelectionController.Dependencies(
                state: $viewState,
                lastSurfaceRawValue: $lastSurfaceRawValue,
                repos: { repos },
                webSources: { webSources },
                selectedWorkspace: { currentSelectedWorkspace },
                selectedWebSource: { currentSelectedWebSource },
                selectedRepoForLanding: { currentSelectedRepoForLanding },
                tileTreeStore: tileTreeStore,
                focusCoordinator: terminalFocusCoordinator,
                smokeDriver: smokeDriver,
                webDetailSurfaceStore: webDetailSurfaceStore,
                providerRegistry: workspaceProviderRegistry,
                providerSetupActionRunner: workspaceProviderSetupActionRunner,
                bootstrapController: bootstrapController,
                modelContext: modelContext,
                abandonPendingRemoteConnection: { reason in
                    abandonPendingRemoteConnection(reason: reason)
                },
                applyNavigationDestination: { destination in
                    applyNavigationDestination(destination)
                },
                markRepoAccessed: { markAccessed(repo: $0) },
                markWorkspaceAccessed: { markAccessed(workspace: $0) },
                markWebSourceAccessed: { markAccessed(webSource: $0) },
                acknowledgeAttention: { acknowledgeVisitedAttentionTarget($0) },
                acknowledgeAgentSession: { acknowledgeVisitedAgentSession($0) },
                activateHostSession: MainWindowHostSessionActivator { key, directory, customCommand in
                    activateHostSession(key: key, directory: directory, customCommand: customCommand)
                },
                persistTerminalContinuity: { targetKind, targetID, rootURL, launchURL in
                    terminalContinuityController.persist(
                        targetKind: targetKind,
                        targetID: targetID,
                        rootURL: rootURL,
                        launchURL: launchURL
                    )
                },
                restoredLaunchDirectoryForRepo: { terminalContinuityController.restoredLaunchDirectory(for: $0) },
                restoredLaunchDirectoryForWorkspace: {
                    terminalContinuityController.restoredLaunchDirectory(for: $0)
                },
                clearCodePreview: { clearCodePreview() },
                presentWorkspaceOperationError: { presentWorkspaceOperationError($0) }
            )
        )
    }

    private var landingActionController: MainWindowLandingActionController {
        MainWindowLandingActionController(
            dependencies: MainWindowLandingActionController.Dependencies(
                repoForNewWorkspace: $repoForNewWorkspaceFromLanding,
                isPreparingNewWorkspaceSheet: $isPreparingLandingNewWorkspaceSheet,
                modelContext: modelContext,
                workspaceService: workspaceService,
                providerRegistry: workspaceProviderRegistry,
                providerSetupActionRunner: workspaceProviderSetupActionRunner,
                externalEditorService: externalEditorService,
                webSources: { webSources },
                retireTerminalSessions: { key in
                    try await retireTerminalSessions(inScope: key)
                },
                selectWorkspace: { handleWorkspaceSelection($0) },
                selectWebSource: { handleWebSourceSelection($0) },
                abandonPendingRemoteConnection: { reason in
                    abandonPendingRemoteConnection(reason: reason)
                },
                seedEnvironmentStateIfNeeded: { await seedLandingWorkspaceEnvironmentStateIfNeeded() },
                prepareEnvironmentStateForPresentation: {
                    workspaceEnvironmentSheetState =
                        workspaceEnvironmentOptionsController.prepareSheetStateForPresentation(
                            existingState: workspaceEnvironmentSheetState,
                            registry: workspaceProviderRegistry
                        )
                },
                refreshEnvironmentState: { trigger in
                    await refreshLandingWorkspaceEnvironmentState(trigger: trigger)
                },
                environmentOptionCount: { environmentOptions(for: $0).count },
                lumeStateDescription: { lumeRuntimeSnapshot?.state.rawValue ?? "pending" },
                presentLandingError: { presentLandingError($0) },
                presentOpenInEditorError: { presentOpenInEditorError($0) }
            )
        )
    }

    private var automationGestureVerbs: MainWindowAutomationGestureVerbs {
        MainWindowAutomationGestureVerbs(
            dependencies: MainWindowAutomationGestureVerbs.Dependencies(
                repos: { repos },
                selectedWorkspace: selectedWorkspaceBinding,
                selectedWorkspaceID: { currentSelectedWorkspace?.id },
                tileTreeStore: tileTreeStore,
                focusCoordinator: terminalFocusCoordinator,
                smokeDriver: smokeDriver,
                createBridge: automationWorkspaceCreateBridge,
                modelContext: modelContext,
                workspaceService: workspaceService,
                providerRegistry: workspaceProviderRegistry,
                retireTerminalSessions: { key in
                    try await retireTerminalSessions(inScope: key)
                },
                makeTeardownController: { makeWorkspaceTerminalTeardownController() },
                attachWorkspaceSessionWithoutSelection: {
                    selectionController.attachWorkspaceSessionWithoutSelection($0)
                },
                selectRepoTerminal: { handleRepoTerminalSelection($0) }
            )
        )
    }

    private var sessionPresentation: HostTerminalSessionPresentation {
        tileTreeStore.sessionPresentation
    }

    private var terminalMultiplexingMode: TerminalMultiplexingMode {
        TerminalMultiplexingMode.resolve(rawValue: terminalMultiplexingModeRawValue)
    }

    private var activeHostSession: HostTerminalSession? {
        presentationController.activeHostSession(
            activeSessionID: tileTreeStore.activeSessionID,
            sessions: tileTreeStore.sessions
        )
    }

    private var terminalContinuityController: MainWindowTerminalContinuityController {
        MainWindowTerminalContinuityController(
            dependencies: MainWindowTerminalContinuityController.Dependencies(
                manifestRawValue: $terminalContinuityManifestRawValue,
                repos: { repos },
                tileTreeStore: tileTreeStore,
                providerRegistry: workspaceProviderRegistry,
                terminalMode: { terminalMultiplexingMode },
                defaultHomeURL: resolvedDefaultHostDirectory
            )
        )
    }

    private var currentSelectedWorkspace: Workspace? {
        mainSelectionCoordinator.cachedWorkspace(with: viewState.selectedWorkspace?.workspaceID)
    }

    private var currentSelectedWebSource: WebSource? {
        mainSelectionCoordinator.cachedWebSource(with: viewState.selectedWebSource?.webSourceID)
    }

    private var currentSelectedRepoForLanding: Repo? {
        mainSelectionCoordinator.cachedRepo(with: viewState.selectedRepoForLandingID)
    }

    private var modelSnapshot: ModelSnapshot {
        ModelSnapshot(
            repoIDs: repos.map(\.id),
            workspaceIDs: repos.flatMap(\.workspaces).map(\.id),
            webSourceIDs: webSources.map(\.id)
        )
    }

    private var normalizedRepoPathSnapshot: Set<String> {
        mainSelectionCoordinator.cachedNormalizedRepoPaths
    }

    private var selectedRepoForInspector: Repo? {
        presentationController.selectedRepoForInspector(
            selectedWorkspace: currentSelectedWorkspace,
            selectedWebSource: currentSelectedWebSource,
            activeRepoPath: sessionPresentation.activeRepoPath,
            activeHostSession: activeHostSession,
            repos: repos,
            normalizePath: normalizePath
        )
    }

    private var selectedRepoForSidebar: Repo? {
        currentSelectedRepoForLanding ?? selectedRepoForInspector
    }

    private var selectedWorkspaceForToolbar: Workspace? {
        currentSelectedWorkspace ?? activeTerminalWorkspaceForToolbar
    }

    private var selectedRepoForToolbar: Repo? {
        selectedWorkspaceForToolbar?.sourceRepo ?? selectedRepoForInspector ?? currentSelectedRepoForLanding
    }

    private var toolbarTitle: MainWindowToolbarTitle? {
        presentationController.toolbarTitle(
            selectedWorkspace: selectedWorkspaceForToolbar,
            selectedRepo: selectedRepoForToolbar,
            activeHostSession: activeHostSession
        )
    }

    private var activeTerminalWorkspaceForToolbar: Workspace? {
        guard currentSelectedWebSource == nil,
            currentSelectedRepoForLanding == nil,
            let activeHostSession
        else { return nil }

        let normalizedDirectory = normalizePath(activeHostSession.directoryPath)
        return
            repos
            .flatMap(\.workspaces)
            .compactMap { workspace -> (workspace: Workspace, pathLength: Int)? in
                let normalizedWorkspacePath = normalizePath(workspace.path)
                guard path(normalizedDirectory, isInside: normalizedWorkspacePath) else {
                    return nil
                }

                return (workspace, normalizedWorkspacePath.count)
            }
            .sorted { lhs, rhs in
                if lhs.pathLength != rhs.pathLength {
                    return lhs.pathLength > rhs.pathLength
                }

                return lhs.workspace.lastAccessedAt > rhs.workspace.lastAccessedAt
            }
            .first?
            .workspace
    }

    private var selectedWorkspaceBinding: Binding<Workspace?> {
        Binding(
            get: { currentSelectedWorkspace },
            set: { workspace in
                guard let workspace else {
                    setSelectedWorkspace(nil)
                    return
                }
                handleWorkspaceSelection(workspace)
            }
        )
    }

    private var selectedWebSourceBinding: Binding<WebSource?> {
        Binding(
            get: { currentSelectedWebSource },
            set: { setSelectedWebSource($0) }
        )
    }

    private var paneCountBySessionKeyForSidebar: [HostTerminalSessionKey: Int] {
        presentationController.paneCountBySessionKey(
            sessions: tileTreeStore.sessions,
            paneCount: { sessionID in
                tileTreeStore.paneCount(forPrimarySessionID: sessionID)
            }
        )
    }

    private var activeSessionKeyForSidebar: HostTerminalSessionKey? {
        presentationController.activeSessionKeyForSidebar(
            selectedWebSource: currentSelectedWebSource,
            activeSessionID: tileTreeStore.activeSessionID,
            sessions: tileTreeStore.sessions
        )
    }

    private var sessionSwitcherProjectionContext: SessionSwitcherProjectionContext {
        SessionSwitcherProjectionContext(
            repos: repos,
            webSources: webSources,
            sessions: tileTreeStore.sessions,
            activeSessionID: tileTreeStore.activeSessionID,
            agentStatusBySessionID: agentSessionRegistry.statuses,
            paneCountBySessionKey: paneCountBySessionKeyForSidebar,
            activeSessionKey: activeSessionKeyForSidebar,
            bubbledRepoStatuses: workspaceStatusAggregator.repoStatuses,
            registry: workspaceProviderRegistry,
            normalizePath: { url in normalizePath(url.path) }
        )
    }

    private func makeSessionSwitcherSnapshot() -> SessionSwitcherSnapshot {
        sessionSwitcherController.snapshot(sessionSwitcherProjectionContext)
    }

    static func sidebarActiveSessionKey(
        selectedWebSourceID: UUID?,
        activeSessionID: UUID?,
        sessions: [HostTerminalSession]
    ) -> HostTerminalSessionKey? {
        guard selectedWebSourceID == nil else { return nil }
        return MainWindowPresentationController().activeSessionKeyForSidebar(
            selectedWebSource: nil,
            activeSessionID: activeSessionID,
            sessions: sessions
        )
    }

    private var hasInspectorTarget: Bool {
        inspectorStateController.hasInspectorTarget(
            selectedWorkspace: currentSelectedWorkspace,
            selectedRepo: selectedRepoForInspector
        )
    }

    private var inspectorTargetIDSet: Set<String> {
        inspectorStateController.inspectorTargetIDSet(repos: repos)
    }

    private var availableEditors: [ExternalEditorDescriptor] {
        externalEditorService.availableEditors
    }

    private var defaultEditorDescriptor: ExternalEditorDescriptor? {
        let defaultEditor = externalEditorService.defaultEditor
        return availableEditors.first(where: { $0.id == defaultEditor }) ?? availableEditors.first
    }

    private var fixturePreviewBootstrapConfiguration: UIFixturePreviewBootstrapConfiguration? {
        UIFixturePreviewBootstrapConfiguration.from(environment: ProcessInfo.processInfo.environment)
    }

    private var fixtureWebBootstrapConfiguration: UIFixtureWebBootstrapConfiguration? {
        UIFixtureWebBootstrapConfiguration.from(environment: ProcessInfo.processInfo.environment)
    }

    private var fixtureDiagnosticsBootstrapConfiguration: UIFixtureDiagnosticsBootstrapConfiguration? {
        UIFixtureDiagnosticsBootstrapConfiguration.from(environment: ProcessInfo.processInfo.environment)
    }

    private var fixtureFileTreeFailureBootstrapConfiguration: UIFixtureFileTreeFailureBootstrapConfiguration? {
        UIFixtureFileTreeFailureBootstrapConfiguration.from(environment: ProcessInfo.processInfo.environment)
    }

    private var fixtureSessionSwitcherBootstrapConfiguration: UIFixtureSessionSwitcherBootstrapConfiguration? {
        UIFixtureSessionSwitcherBootstrapConfiguration.from(environment: ProcessInfo.processInfo.environment)
    }

    private var openInEditorTarget: OpenInEditorTarget? {
        presentationController.openInEditorTarget(
            selectedCodePreview: viewState.selectedCodePreview,
            selectedWorkspace: currentSelectedWorkspace,
            selectedRepo: selectedRepoForInspector
        )
    }

    private var openInEditorContextKey: MainWindowOpenInEditorContextKey {
        presentationController.openInEditorContextKey(
            selectedCodePreview: viewState.selectedCodePreview,
            selectedWorkspace: currentSelectedWorkspace,
            selectedRepo: selectedRepoForInspector
        )
    }

    private var openInEditorFocusedAction: (@MainActor () -> Void)? {
        guard openInEditorTarget != nil else { return nil }
        return openInDefaultEditor
    }

    private var openInBrowserFocusedAction: (@MainActor () -> Void)? {
        guard currentSelectedWebSource?.baseURL != nil else { return nil }
        return openSelectedWebSourceInBrowser
    }

    private var reloadWebSourceFocusedAction: (@MainActor () -> Void)? {
        guard currentSelectedWebSource != nil else { return nil }
        return reloadSelectedWebSource
    }

    private var openDesktopFocusedAction: (@MainActor () -> Void)? {
        guard let workspace = currentSelectedWorkspace,
            selectedWorkspaceSupportsDesktop,
            workspace.status != .provisioning
        else { return nil }
        return openDesktopForCurrentSelection
    }

    private var revealInFinderFocusedAction: (@MainActor () -> Void)? {
        guard openInEditorTarget != nil else { return nil }
        return revealInFinder
    }

    private var copyPathFocusedAction: (@MainActor () -> Void)? {
        guard openInEditorTarget != nil else { return nil }
        return copyWorkspacePath
    }

    private var mainWindowFocusedActions: MainWindowFocusedActions {
        MainWindowFocusedActions(
            toggleSidebar: toggleSidebarVisibility,
            toggleInspector: toggleInspectorVisibility,
            toggleTerminalPanel: toggleTerminalPanelVisibility,
            newTerminalTab: createTerminalTabFromCurrentContext,
            closeTerminalTab: closeActiveTerminalTab,
            selectNextTerminalTab: { selectAdjacentTerminalTab(offset: 1) },
            selectPreviousTerminalTab: { selectAdjacentTerminalTab(offset: -1) },
            openInEditor: openInEditorFocusedAction,
            openInBrowser: openInBrowserFocusedAction,
            reloadWebSource: reloadWebSourceFocusedAction,
            openDesktop: openDesktopFocusedAction,
            revealInFinder: revealInFinderFocusedAction,
            copyPath: copyPathFocusedAction,
            openSessionSwitcher: presentSessionSwitcher,
            openCommandRunner: { viewState.isShowingThemeOverlay = true },
            sendFeedback: { isShowingFeedbackSheet = true },
            openEmbeddedWebNext: { openEmbeddedWebNext(redirect: nil) }
        )
    }

    private var mainWindowCommandAvailabilitySnapshot: MainWindowCommandAvailability {
        MainWindowCommandAvailability(
            canToggleSidebar: true,
            canToggleInspector: true,
            canToggleTerminalPanel: true,
            canCreateTerminalTab: tileTreeStore.hasSessions,
            canCloseTerminalTab: tileTreeStore.hasSessions,
            canSelectNextTerminalTab: tileTreeStore.scopedSessions.count > 1,
            canSelectPreviousTerminalTab: tileTreeStore.scopedSessions.count > 1,
            canOpenInEditor: openInEditorFocusedAction != nil,
            canOpenInBrowser: openInBrowserFocusedAction != nil,
            canReloadWebSource: reloadWebSourceFocusedAction != nil,
            canOpenDesktop: openDesktopFocusedAction != nil,
            canRevealInFinder: revealInFinderFocusedAction != nil,
            canCopyPath: copyPathFocusedAction != nil,
            canOpenSessionSwitcher: true,
            canOpenCommandRunner: true,
            canSendFeedback: true,
            canOpenEmbeddedWebNext: true
        )
    }

    private var selectedWorkspaceProviderDescriptor: WorkspaceProviderDescriptor? {
        guard let workspace = currentSelectedWorkspace else { return nil }
        return workspaceProviderRegistry.provider(for: workspace)?.descriptor
    }

    private var selectedWorkspaceSupportsDesktop: Bool {
        selectedWorkspaceProviderDescriptor?.supportsDesktop == true
    }

    private var lumeRuntimeSnapshot: LumeRuntimeSnapshot? {
        workspaceEnvironmentSheetState.lumeRuntimeSnapshot
    }

    @ViewBuilder
    private var terminalDetailContent: some View {
        MainTerminalDetailView(
            appCommandState: appCommandState,
            selectedWorkspace: selectedWorkspaceForToolbar,
            selectedRepo: selectedRepoForToolbar ?? selectedRepoForInspector,
            activeHostSession: activeHostSession,
            hostTerminalSessions: tileTreeStore.sessions,
            visibleHostTerminalSessions: tileTreeStore.scopedSessions,
            activeHostTerminalSessionID: tileTreeStore.activeSessionID,
            activeTabTree: tileTreeStore.tileTree(forPrimarySessionID: tileTreeStore.activeSessionID),
            resolveTileSession: { tileTreeStore.session(forTile: $0) },
            resolveTileID: { tileTreeStore.renderTileID(forSession: $0) },
            hostSurfaceStore: tileTreeStore.surfaceStore,
            tabTitleOverrides: tileTreeStore.tabTitleOverridesBySessionID,
            agentStatuses: Array(agentSessionRegistry.statuses.values),
            terminalContextMenuProvider: terminalContextMenu(for:),
            onSetSplitRatio: { splitID, ratio in
                guard let activeSessionID = tileTreeStore.activeSessionID else { return }
                _ = tileTreeStore.updateSplitRatio(
                    ratio,
                    splitID: splitID,
                    forPrimarySessionID: activeSessionID
                )
            },
            onSelectTerminalTab: selectTerminalTab(sessionID:),
            onCloseTerminalTab: closeTerminalTab(sessionID:),
            onRenameTerminalTab: renameTerminalTab(sessionID:title:),
            onTerminalCloseConfirmationRequired: requestCloseConfirmationForTerminalTab(sessionID:),
            onTerminalProcessExit: handleTerminalProcessExit(sessionID:),
            selectedCodePreview: $viewState.selectedCodePreview,
            isTerminalPanelVisible: $viewState.isTerminalPanelVisible,
            onFileSelected: handleCodePreviewSelection,
            availableEditors: availableEditors,
            defaultEditor: defaultEditorDescriptor,
            onOpenInDefaultEditor: openInDefaultEditor,
            onOpenInEditor: openInSelectedEditor,
            onCodePreviewSaved: requestRightPaneRefreshAfterCodeSave,
            onCloseCodePreview: requestCloseCodePreview,
            rightPaneStateStore: rightPaneStateStore,
            isRightPaneVisible: $viewState.isRightPaneVisible
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        if let activation = embeddedWebNext {
            EmbeddedWebNextDetailView(
                server: webNextServerService,
                redirect: activation.redirect,
                onClose: { embeddedWebNext = nil }
            )
            .id(activation.id)
        } else if let selectedWebSource = currentSelectedWebSource {
            WebSourceDetailView(
                source: selectedWebSource,
                tileID: webDetailTileID,
                surfaceStore: webDetailSurfaceStore,
                onSurfaceMounted: smokeDriver.webSurfaceMountObserver
            )
        } else if let selectedRepo = currentSelectedRepoForLanding {
            RepoLandingView(
                repo: selectedRepo,
                onWorkspaceSelected: { workspace in
                    handleWorkspaceSelection(workspace)
                },
                onWebSourceSelected: handleWebSourceSelection,
                onOpenTerminal: handleRepoTerminalSelection,
                onNewWorkspace: { repo in
                    Task { @MainActor in
                        await landingActionController.presentNewWorkspaceSheet(for: repo)
                    }
                },
                onNewWebSource: { repo in
                    webSourceCreationTarget = .repo(repo)
                },
                onArchiveWorkspace: { workspace in
                    Task { @MainActor in
                        await landingActionController.archiveWorkspace(workspace)
                    }
                },
                onOpenWorkspaceInEditor: { workspace in
                    landingActionController.openWorkspaceInDefaultEditor(workspace)
                }
            )
        } else {
            ZStack {
                terminalDetailContent
                if viewState.connectingWorkspaceID != nil {
                    WorkspaceConnectingOverlay(workspaceName: currentSelectedWorkspace?.name)
                }
            }
        }
    }

    private var baseSplitView: some View {
        NavigationSplitView(columnVisibility: $viewState.columnVisibility) {
            SidebarView(
                appCommandState: appCommandState,
                repos: repos,
                webSources: webSources,
                selectedRepo: selectedRepoForSidebar,
                selectedWorkspace: selectedWorkspaceBinding,
                selectedWebSource: selectedWebSourceBinding,
                paneCountBySessionKey: paneCountBySessionKeyForSidebar,
                activeSessionKey: activeSessionKeyForSidebar,
                hostSessions: tileTreeStore.sessions,
                agentStatusBySessionID: agentSessionRegistry.statuses,
                titleForSession: { session in
                    tileTreeStore.tabTitleOverride(for: session.id)
                        ?? tileTreeStore.surfaceStore.displayTitle(for: session)
                },
                connectingWorkspaceID: viewState.connectingWorkspaceID,
                onRepoSelected: handleRepoSelection,
                onRepoTerminalSelected: handleRepoTerminalSelection,
                onWebSourceSelected: handleWebSourceSelection,
                onRequestWebSourceCreation: { target in
                    webSourceCreationTarget = target
                },
                webNextSessionSlug: { GitHubRepoSlug(remoteURL: $0.remoteURL) },
                onOpenWebNextSession: openWebNextSession,
                onWorkspaceCreated: handleWorkspaceCreated,
                retireTerminalSessions: { key in
                    try await retireTerminalSessions(inScope: key)
                },
                workspaceProviderSetupCoordinator: workspaceProviderSetupCoordinator,
                smokeDriver: smokeDriver,
                automationWorkspaceCreateBridge: automationWorkspaceCreateBridge
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 350)
        } detail: {
            detailContent
                .toolbar {
                    // Owner steer on #1086: repo/branch sits at the detail column's
                    // leading edge (left-aligned by the terminal). Declared on the
                    // detail view so the sidebar column's own controls stay intact.
                    if !minimalToolbarEnabled {
                        ToolbarItem(placement: .navigation) {
                            principalToolbarContent
                        }
                    }
                }
        }
    }

    private var splitViewWithToolbar: some View {
        Group {
            if minimalToolbarEnabled {
                splitViewBody
            } else {
                splitViewBody
                    .toolbar {

                        ToolbarItemGroup(placement: .primaryAction) {
                            // Spacer keeps this group pinned trailing now that no
                            // .principal item occupies the center (#1086 owner steer).
                            Spacer()

                            NeedsYouToolbarPill(
                                repos: repos,
                                onActivateWorkspace: handleWorkspaceSelection,
                                onActivateRepo: handleRepoTerminalSelection
                            )

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    viewState.isRightPaneVisible.toggle()
                                }
                            } label: {
                                Image(systemName: "sidebar.trailing")
                            }
                            .help(viewState.isRightPaneVisible ? "Hide Inspector" : "Show Inspector")
                            .disabled(!hasInspectorTarget)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var principalToolbarContent: some View {
        let presentation = presentationController.principalToolbarPresentation(
            toolbarTitle: toolbarTitle,
            buildIdentity: buildIdentity
        )

        HStack(spacing: 8) {
            if presentation.showsDevelopmentBadge {
                AppBuildIdentityBadge(identity: buildIdentity)
            }

            if let title = presentation.toolbarTitle,
                let repo = selectedRepoForToolbar
            {
                MainToolbarTitleBreadcrumb(
                    title: title,
                    faviconSource: preferredToolbarIconSource(for: repo),
                    onOpenRepoOverview: { handleRepoSelection(repo) },
                    onOpenRepoTerminal: { handleRepoTerminalSelection(repo) }
                )
            }
        }
    }

    private func preferredToolbarIconSource(for repo: Repo) -> WebSource? {
        repo.webSources.sorted { lhs, rhs in
            if lhs.lastAccessedAt != rhs.lastAccessedAt {
                return lhs.lastAccessedAt > rhs.lastAccessedAt
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.first
    }

    @ViewBuilder
    private var splitViewBody: some View {
        VStack(spacing: 0) {
            if modelStoreStatusController.shouldShowDegradedWarning {
                ModelStoreDegradedBanner()
            }
            if !workspaceOrphanState.visibleItems.isEmpty {
                WorkspaceOrphanReconciliationBanner(
                    items: workspaceOrphanState.visibleItems,
                    cleaningItemIDs: workspaceOrphanState.cleaningItemIDs,
                    onClean: { item in
                        workspaceOrphanState.pendingCleanup = item
                    },
                    onDismiss: {
                        workspaceOrphanState.dismissVisibleItems()
                    }
                )
            }
            if let plan = restoreState.bannerPlan {
                RestoreSessionsBanner(
                    sessionCount: plan.surfaces.count,
                    onRestore: {
                        markRestorePlanHandled(plan)
                        Task { @MainActor in await executeRestore(plan) }
                    },
                    onDismiss: {
                        markRestorePlanHandled(plan)
                    }
                )
            }
            baseSplitView
        }
        .background(
            MainWindowHandleReader { window in
                terminalFocusCoordinator.bind(window: window)
            }
        )
    }

    private var launchActions: MainWindowLifecycleController.LaunchActions {
        MainWindowLifecycleController.LaunchActions(
            configureAutomationIntegration: configureAutomationIntegration,
            ensureInitialHostSession: ensureInitialHostSession,
            computeRestorePlanIfEnabled: computeRestorePlanIfEnabled,
            prewarmPerfTerminalSurfacesIfNeeded: prewarmPerfTerminalSurfacesIfNeeded,
            resolveSurfaceLifecycle: resolveSurfaceLifecycle,
            applyDiagnosticsFixtureIfNeeded: applyDiagnosticsFixtureIfNeeded,
            applySessionSwitcherFixtureIfNeeded: applySessionSwitcherFixtureIfNeeded,
            pruneRightPaneState: pruneRightPaneState,
            syncOpenInEditorShortcutRouting: syncOpenInEditorShortcutRouting,
            refreshWorkspaceStatusAggregator: refreshWorkspaceStatusAggregator,
            noteHostLumeSmokeLaunchReady: smokeDriver.noteHostLumeLaunchReady,
            noteDesktopUISmokeLaunchReady: smokeDriver.noteDesktopUILaunchReady
        )
    }

    private func modelChangeActions(
        old: ModelSnapshot,
        new: ModelSnapshot
    ) -> MainWindowLifecycleController.ModelChangeActions {
        MainWindowLifecycleController.ModelChangeActions(
            rebuildSelectionCaches: {
                mainSelectionCoordinator.rebuildCachesIfNeeded(
                    repos: repos, webSources: webSources, normalizePath: normalizePath
                )
            },
            releaseRemovedWebSources: { releaseRemovedWebSources(old: old, new: new) },
            reconcileSelectionAfterModelChange: reconcileSelectionAfterModelChange,
            resolveSurfaceLifecycle: resolveSurfaceLifecycle,
            applyDiagnosticsFixtureIfNeeded: applyDiagnosticsFixtureIfNeeded,
            applySessionSwitcherFixtureIfNeeded: applySessionSwitcherFixtureIfNeeded,
            pruneRepoSessions: {
                tileTreeStore.pruneRepoSessions(validRepoPaths: normalizedRepoPathSnapshot)
            },
            refreshWorkspaceStatusAggregator: refreshWorkspaceStatusAggregator,
            refreshSessionSwitcherSnapshotIfPresented: refreshSessionSwitcherSnapshotIfPresented
        )
    }

    private var teardownActions: MainWindowLifecycleController.TeardownActions {
        MainWindowLifecycleController.TeardownActions(
            clearOpenInEditorShortcutOverride: {
                ShortcutRoutingPolicy.shared.setOverride(nil, for: AppChromeShortcut.openInEditor.chord)
            },
            cancelStatusAggregation: statusAggregationCoalescer.cancel,
            // The window that installed the gesture-verb layer is gone; drop it so an operator
            // mutation verb fails closed (unsupported) instead of driving a stale selection
            // gesture while the app lingers as an accessory. Reappearing reinstalls it via onAppear.
            detachAutomationGestureVerbs: AutomationIntegrationLifecycle.shared.detachGestureVerbs
        )
    }

    private var splitViewWithLifecycleHandlers: some View {
        splitViewWithToolbar
            .onAppear {
                mainSelectionCoordinator.rebuildCachesIfNeeded(
                    repos: repos, webSources: webSources, normalizePath: normalizePath
                )
                lifecycleController.runLaunchPrologue(
                    launchActions,
                    automationGatesTerminalBootstrap: AutomationIntegrationLifecycle.shared.isEnabled
                )
                Task { @MainActor in
                    await lifecycleController.runLaunchSequence(launchActions)
                }
                notificationCoordinator.loadStoredAuth()
                Task { @MainActor in
                    terminalFocusCoordinator.attach(surfaceStore: tileTreeStore.surfaceStore)
                    _ = await seedLandingWorkspaceEnvironmentStateIfNeeded()
                }
            }
            .onChange(of: agentSessionRegistry.statuses) { _, _ in
                scheduleWorkspaceStatusAggregatorRefresh()
                refreshSessionSwitcherSnapshotIfPresented()
            }
            .onChange(of: tileTreeStore.sessions) { _, _ in
                scheduleWorkspaceStatusAggregatorRefresh()
                refreshSessionSwitcherSnapshotIfPresented()
                terminalContinuityController.persistSnapshot()
            }
            .onChange(of: tileTreeStore.activeSessionID) { _, _ in
                refreshSessionSwitcherSnapshotIfPresented()
                terminalContinuityController.persistSnapshot()
            }
            .task {
                prewarmPerfTerminalSurfacesIfNeeded()
                await performDeferredStartupWorkspaceStatusSync()
            }
            .onDisappear {
                lifecycleController.runTeardown(teardownActions)
            }
            .onChange(of: deepLinkState.pendingRequest) { _, _ in
                resolveSurfaceLifecycle()
            }
            .onChange(of: modelSnapshot) { old, new in
                lifecycleController.runModelChangeSequence(modelChangeActions(old: old, new: new))
            }
            .onChange(of: inspectorTargetIDSet) { _, _ in
                pruneRightPaneState()
            }
            .onChange(of: currentSelectedWebSource?.id) { _, newSourceID in
                // Selection is the eviction authority for the web-detail tile domain: deselecting
                // web empties it (deferred release keeps the page for quick flip-back). A source
                // switch needs nothing here — mounting rebinds the tile via the identity guard.
                if newSourceID == nil {
                    webDetailSurfaceStore.sync(activeLeafIDs: [])
                }
            }
            .onChange(of: currentSelectedWorkspace?.id) { _, _ in
                syncNotificationStreamForSelection()
            }
            .onChange(of: notificationCoordinator.authState) { _, _ in
                syncNotificationStreamForSelection()
            }
            .onChange(of: notificationsEnabled) { _, _ in
                syncNotificationStreamForSelection()
            }
            .onChange(of: openInEditorContextKey) { _, _ in
                syncOpenInEditorShortcutRouting()
            }
            .onReceive(NotificationCenter.default.publisher(for: GhosttyAppManager.splitActionNotification)) {
                notification in
                Task { @MainActor in
                    splitRoutingController.handle(
                        notification: notification,
                        terminalMultiplexingMode: terminalMultiplexingMode,
                        tileTreeStore: tileTreeStore,
                        focusTerminal: { sessionID in
                            terminalFocusCoordinator.focusTerminal(
                                sessionID: sessionID,
                                surfaceStore: tileTreeStore.surfaceStore
                            )
                        }
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: GhosttyAppManager.tabActionNotification)) {
                notification in
                Task { @MainActor in
                    tabRoutingController.handle(
                        notification: notification,
                        tileTreeStore: tileTreeStore,
                        focusTerminal: { sessionID in
                            terminalFocusCoordinator.focusTerminal(
                                sessionID: sessionID,
                                surfaceStore: tileTreeStore.surfaceStore
                            )
                        },
                        requestCloseTabs: { sessionIDs in
                            requestCloseTerminalTabs(sessionIDs)
                        }
                    )
                    syncSidebarSelectionToActiveSessionFromActiveHostSession()
                    if let activeSessionID = tileTreeStore.activeSessionID {
                        acknowledgeVisitedAgentSession(activeSessionID)
                    }
                }
            }
    }

    private var splitViewWithFocusAndAlerts: some View {
        splitViewWithLifecycleHandlers
            .mainWindowErrorAlert($errorPresenter)
            .alert(
                workspaceOrphanController.confirmationTitle(for: workspaceOrphanState.pendingCleanup),
                isPresented: MainWindowPresentation.isPresented($workspaceOrphanState.pendingCleanup)
            ) {
                Button("Clean", role: .destructive) {
                    guard
                        let item = MainWindowPresentation.consume($workspaceOrphanState.pendingCleanup)
                    else { return }
                    Task { @MainActor in
                        await cleanWorkspaceOrphan(item)
                    }
                }
                Button("Cancel", role: .cancel) {
                    workspaceOrphanState.pendingCleanup = nil
                }
            } message: {
                Text(
                    workspaceOrphanController.confirmationMessage(
                        for: workspaceOrphanState.pendingCleanup))
            }
            .alert(
                "Could Not Complete Provider Setup",
                isPresented: MainWindowPresentation.isPresented(
                    workspaceProviderSetupCoordinator.errorMessage,
                    onDismiss: { workspaceProviderSetupCoordinator.clearError() }
                )
            ) {
                Button("OK", role: .cancel) { workspaceProviderSetupCoordinator.clearError() }
            } message: {
                Text(workspaceProviderSetupCoordinator.errorMessage ?? "Unknown error.")
            }
            .alert(
                "Close Terminal?",
                isPresented: MainWindowPresentation.isPresented($viewState.terminalCloseConfirmation)
            ) {
                Button("Close", role: .destructive) {
                    guard
                        let confirmation = MainWindowPresentation.consume(
                            $viewState.terminalCloseConfirmation)
                    else { return }
                    forceCloseTerminalTab(sessionID: confirmation.sessionID)
                }
                Button("Cancel", role: .cancel) {
                    viewState.terminalCloseConfirmation = nil
                }
            } message: {
                Text(
                    """
                    The terminal still has a running process. Closing \
                    '\(viewState.terminalCloseConfirmation?.title ?? "Terminal")' will end it.
                    """
                )
            }
            .sheet(
                item: MainWindowPresentation.item(
                    workspaceProviderSetupCoordinator.confirmationRequest,
                    onDismiss: { workspaceProviderSetupCoordinator.cancelPendingAction() }
                )
            ) { request in
                WorkspaceProviderSetupConfirmationSheet(
                    request: request,
                    onConfirm: {
                        workspaceProviderSetupCoordinator.confirmAndContinue()
                    },
                    onCancel: {
                        workspaceProviderSetupCoordinator.cancelPendingAction()
                    }
                )
            }
            .sheet(
                item: MainWindowPresentation.undismissableItem(
                    workspaceProviderSetupCoordinator.progressPresentation
                )
            ) { presentation in
                WorkspaceProviderSetupProgressSheet(presentation: presentation)
                    .interactiveDismissDisabled(true)
            }
            .onChange(of: workspaceProviderSetupCoordinator.confirmationRequest) { _, request in
                guard let request else { return }
                Task { @MainActor in
                    await smokeDriver.handleProviderSetupConfirmation(request) {
                        workspaceProviderSetupCoordinator.confirmAndContinue()
                    }
                }
            }
            .onChange(of: workspaceProviderSetupCoordinator.progressPresentation) { _, presentation in
                guard let presentation else { return }
                Task { @MainActor in
                    await smokeDriver.noteProviderSetupStepChanged(presentation)
                }
            }
            .onChange(of: workspaceProviderSetupCoordinator.errorMessage) { _, message in
                guard let message else { return }
                Task { @MainActor in
                    await smokeDriver.noteHostWorkspaceFailure(message: message)
                }
            }
            .onChange(of: errorPresenter.message(from: .workspaceOperation)) { _, message in
                guard let message else { return }
                Task { @MainActor in
                    await smokeDriver.noteHostWorkspaceFailure(message: message)
                }
            }
    }

    private func syncNotificationStreamForSelection() {
        guard
            notificationsEnabled,
            case .signedIn = notificationCoordinator.authState,
            let remoteURL = currentSelectedWorkspace?.sourceRepo?.remoteURL
        else {
            Task { await notificationCoordinator.disconnectStream() }
            return
        }

        Task { await notificationCoordinator.connectStream(remoteURL: remoteURL) }
    }

    var body: some View {
        splitViewWithFocusAndAlerts
            .task {
                syncAppCommands()
            }
            .onChange(of: mainWindowCommandAvailabilitySnapshot) { _, _ in
                syncAppCommands()
            }
            .onDisappear {
                clearAppCommands()
                accessRecorder.flushPendingSave(modelContext: modelContext)
                // Window close: the app outlives its last window, so tear the web-detail domain
                // down deterministically instead of leaning on ARC scene disposal. This is the
                // root view — a new window gets a fresh @State store, so this can never race a
                // remount the way the pane-level onDisappear could.
                webDetailSurfaceStore.sync(activeLeafIDs: [])
            }
            .onReceive(NotificationCenter.default.publisher(for: .showFeedbackSheet)) { _ in
                isShowingFeedbackSheet = true
            }
            .sheet(item: $repoForNewWorkspaceFromLanding) { repo in
                NewWorkspaceSheet(
                    repo: repo,
                    environmentOptions: environmentOptions(for: repo),
                    isPreparingEnvironmentOptions: isPreparingLandingNewWorkspaceSheet,
                    isCreateDisabled: false
                ) { name, nameSource, providerID, guestOS in
                    Task { @MainActor in
                        await landingActionController.createWorkspace(
                            repo: repo,
                            name: name,
                            nameSource: nameSource,
                            providerID: providerID,
                            guestOS: guestOS
                        )
                    }
                }
            }
            .sheet(item: $webSourceCreationTarget) { target in
                NewWebSourceSheet(target: target) { rawURL, displayName, additionalAllowedDomainsRaw in
                    Task { @MainActor in
                        landingActionController.addWebSource(
                            rawURL: rawURL,
                            displayName: displayName,
                            additionalAllowedDomainsRaw: additionalAllowedDomainsRaw,
                            target: target
                        )
                    }
                }
            }
            .sheet(
                isPresented: $viewState.isShowingSessionSwitcher,
                onDismiss: {
                    presentedSessionSwitcherSnapshot = nil
                }
            ) {
                SessionSwitcherView(
                    snapshot: presentedSessionSwitcherSnapshot ?? makeSessionSwitcherSnapshot(),
                    repos: repos,
                    webSources: webSources,
                    onSelectWorkspace: { workspace in
                        dismissSessionSwitcher()
                        handleWorkspaceSelection(workspace)
                    },
                    onSelectRepo: { repo in
                        dismissSessionSwitcher()
                        handleRepoSelection(repo)
                    },
                    onSelectWebSource: { source in
                        dismissSessionSwitcher()
                        handleWebSourceSelection(source)
                    },
                    onSelectHostSession: { sessionID in
                        dismissSessionSwitcher()
                        activateSessionSwitcherHostSession(sessionID)
                    },
                    onOpenThemeSwitcher: {
                        dismissSessionSwitcher()
                        viewState.isShowingThemeOverlay = true
                    },
                    onDismiss: {
                        dismissSessionSwitcher()
                    }
                )
            }
            .sheet(isPresented: $viewState.isShowingThemeOverlay) {
                TerminalThemeOverlay(
                    store: .shared,
                    onDismiss: { viewState.isShowingThemeOverlay = false }
                )
            }
            .sheet(isPresented: $isShowingFeedbackSheet) {
                FeedbackSheet(
                    notificationCoordinator: notificationCoordinator,
                    onDismiss: { isShowingFeedbackSheet = false }
                )
            }
            .confirmationDialog(
                "Unsaved changes",
                isPresented: pendingCodePreviewNavigationBinding,
                titleVisibility: .visible,
                presenting: codePreviewNavigationState.pending
            ) { _ in
                Button("Save") { resolvePendingCodePreviewNavigation(.save) }
                Button("Discard", role: .destructive) { resolvePendingCodePreviewNavigation(.discard) }
                Button("Cancel", role: .cancel) { resolvePendingCodePreviewNavigation(.cancel) }
            } message: { _ in
                Text("This file has unsaved edits. Save them before leaving, or discard them?")
            }
    }

    private var pendingCodePreviewNavigationBinding: Binding<Bool> {
        MainWindowPresentation.isPresented(
            codePreviewNavigationState.pending,
            onDismiss: { codePreviewNavigationState.clearPending() }
        )
    }

    @MainActor
    private func setSelectedWorkspace(_ workspace: Workspace?) {
        viewState.selectedWorkspace = workspace.map(MainWindowWorkspaceSelection.init(workspace:))
    }

    @MainActor
    private func setSelectedWebSource(_ source: WebSource?) {
        viewState.selectedWebSource = source.map(MainWindowWebSourceSelection.init(source:))
    }

    @MainActor
    private func setSelectedRepoForLanding(_ repo: Repo?) {
        viewState.selectedRepoForLandingID = repo?.id
    }

    /// Show the embedded web-next surface. `redirect` is the post-sign-in path
    /// (`nil` for a plain open). Re-activating with the same redirect is a no-op
    /// so a repeated shortcut press doesn't re-mount and re-navigate the pane.
    @MainActor
    private func openEmbeddedWebNext(redirect: String?, forceFresh: Bool = false) {
        guard
            let next = EmbeddedWebNextActivation.next(
                current: embeddedWebNext,
                redirect: redirect,
                forceFresh: forceFresh
            )
        else { return }
        embeddedWebNext = next
    }

    /// Open a repo-bound New Web Session. Always forces a fresh activation so a
    /// second New Web Session for the same repo still opens (the prior pane may
    /// have moved on to `/sessions/<id>`). No-ops when the repo's remote can't be
    /// resolved to `owner/name` (the sidebar entry is disabled in that case, so
    /// this guard only defends against a stale invocation).
    @MainActor
    private func openWebNextSession(for repo: Repo) {
        guard let slug = GitHubRepoSlug(remoteURL: repo.remoteURL) else { return }
        openEmbeddedWebNext(
            redirect: EmbeddedWebNextDeepLink.newSessionRedirect(repo: slug),
            forceFresh: true
        )
    }

    @MainActor
    private func applyNavigationDestination(
        _ destination: MainWindowNavigationDestination,
        persistSurface: Bool = true
    ) {
        // Selecting any sidebar surface dismisses the embedded web-next pane so
        // the two selection kinds stay mutually exclusive.
        if embeddedWebNext != nil { embeddedWebNext = nil }
        let transition = navigationStateController.transition(to: destination)
        navigationStateController.apply(transition, to: &viewState)
        if persistSurface {
            persistLastSurface(transition.persistedSurface)
        }
    }

    @MainActor
    private func abandonPendingRemoteConnection(reason: String) {
        guard viewState.connectingWorkspaceID != nil || viewState.pendingRemoteWorkspace != nil else {
            return
        }

        workspaceProviderLog.info(
            "[WorkspaceProvider] Discarding pending remote connection (\(reason, privacy: .public))")
        viewState.connectingWorkspaceID = nil
        viewState.pendingRemoteWorkspace = nil
    }

    @MainActor
    private func resolveSurfaceLifecycle() {
        for _ in 0..<8 {
            let action = surfaceResolutionController.nextAction(
                context: MainWindowSurfaceResolutionContext(
                    environment: ProcessInfo.processInfo.environment,
                    didRunPerfAutoSelection: viewState.didRunPerfAutoSelection,
                    didApplyFixturePreviewBootstrap: viewState.didApplyFixturePreviewBootstrap,
                    didApplyFixtureWebBootstrap: viewState.didApplyFixtureWebBootstrap,
                    didResolveInitialSurface: viewState.didResolveInitialSurface,
                    pendingRequest: deepLinkState.pendingRequest,
                    lastSurfaceRawValue: lastSurfaceRawValue,
                    previewConfiguration: fixturePreviewBootstrapConfiguration,
                    webConfiguration: fixtureWebBootstrapConfiguration,
                    repos: repos,
                    webSources: webSources
                ),
                bootstrapController: bootstrapController
            )

            guard applySurfaceResolutionAction(action) else { break }
        }
    }

    @MainActor
    private func applyDiagnosticsFixtureIfNeeded() {
        if applyFileTreeFailureFixtureIfNeeded() {
            return
        }
        guard fixtureDiagnosticsBootstrapConfiguration != nil else { return }
        guard !viewState.didApplyFixtureDiagnosticsBootstrap else { return }
        guard deepLinkState.pendingRequest == nil else { return }

        if let workspace =
            repos
            .flatMap(\.workspaces)
            .sorted(by: { $0.lastAccessedAt > $1.lastAccessedAt })
            .first
        {
            handleWorkspaceSelection(workspace)
            rightPaneStateStore.state(for: workspace).selectedTab = .diagnostics
            viewState.isRightPaneVisible = true
            viewState.didApplyFixtureDiagnosticsBootstrap = true
            uiFixtureLog.info(
                "[UIFixture] Diagnostics bootstrap applied (workspace=\(workspace.name, privacy: .public))")
            return
        }

        if let repo = repos.first {
            handleRepoTerminalSelection(repo)
            rightPaneStateStore.state(for: repo).selectedTab = .diagnostics
            viewState.isRightPaneVisible = true
            viewState.didApplyFixtureDiagnosticsBootstrap = true
            uiFixtureLog.info("[UIFixture] Diagnostics bootstrap applied (repo=\(repo.name, privacy: .public))")
        }
    }

    @MainActor
    @discardableResult
    private func applyFileTreeFailureFixtureIfNeeded() -> Bool {
        guard fixtureFileTreeFailureBootstrapConfiguration != nil else { return false }
        guard !viewState.didApplyFixtureFileTreeFailureBootstrap else { return true }
        guard deepLinkState.pendingRequest == nil else { return false }

        if let workspace =
            repos
            .flatMap(\.workspaces)
            .sorted(by: { $0.lastAccessedAt > $1.lastAccessedAt })
            .first
        {
            handleWorkspaceSelection(workspace)
            rightPaneStateStore.state(for: workspace).selectedTab = .files
            viewState.isRightPaneVisible = true
            viewState.didApplyFixtureFileTreeFailureBootstrap = true
            uiFixtureLog.info(
                "[UIFixture] File-tree failure bootstrap applied (workspace=\(workspace.name, privacy: .public))")
            return true
        }

        return false
    }

    @MainActor
    private func applySessionSwitcherFixtureIfNeeded() {
        guard fixtureSessionSwitcherBootstrapConfiguration != nil else { return }
        guard !viewState.didApplyFixtureSessionSwitcherBootstrap else { return }

        viewState.didApplyFixtureSessionSwitcherBootstrap = true
        Task { @MainActor in
            presentSessionSwitcher()
            uiFixtureLog.info("[UIFixture] Session switcher bootstrap applied")
        }
    }

    @MainActor
    @discardableResult
    private func applySurfaceResolutionAction(_ action: MainWindowSurfaceResolutionAction) -> Bool {
        launchActionHandler.apply(
            action,
            state: &viewState,
            environment: ProcessInfo.processInfo.environment,
            pendingRequest: deepLinkState.pendingRequest,
            bootstrapController: bootstrapController,
            actions: MainWindowLaunchActionHandler.Actions(
                clearDeepLink: {
                    deepLinkState.clearPendingRequest()
                },
                clearLastSurface: {
                    lastSurfaceRawValue = ""
                },
                discardPendingRemoteConnection: { reason in
                    abandonPendingRemoteConnection(reason: reason)
                },
                importRepo: { repoRoot in
                    launchRepositoryService.existingOrImportedRepo(at: repoRoot)
                },
                selectWorkspace: { workspace, preferredDirectory in
                    handleWorkspaceSelection(workspace, preferredDirectory: preferredDirectory)
                },
                selectRepoTerminal: { repo, preferredDirectory in
                    handleRepoTerminalSelection(repo, preferredDirectory: preferredDirectory)
                },
                selectWebSource: { source in
                    handleWebSourceSelection(source)
                },
                applyLaunchSurface: { surface in
                    applyLaunchSurface(surface)
                },
                schedulePerfAutoSelect: { repo, shouldAutoOpenNewWorkspace in
                    schedulePerfAutoSelection(repo, shouldAutoOpenNewWorkspace: shouldAutoOpenNewWorkspace)
                },
                focusWorkspaceWindow: {
                    focusWorkspaceWindow()
                }
            )
        )
    }

    @MainActor
    private func schedulePerfAutoSelection(_ repo: Repo, shouldAutoOpenNewWorkspace: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Task { @MainActor in
                viewState.didResolveInitialSurface = true
                handleRepoTerminalSelection(repo)
                guard shouldAutoOpenNewWorkspace else { return }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    Task { @MainActor in
                        await landingActionController.presentNewWorkspaceSheet(for: repo)
                    }
                }
            }
        }
    }

    /// Web sources removed from the model lose their per-source web store immediately — deletion
    /// is a hard release whether or not the source was selected, so a deleted page never rides out
    /// the deferred-release grace window (codex review finding on the P6 seam PR).
    @MainActor
    private func releaseRemovedWebSources(old: ModelSnapshot, new: ModelSnapshot) {
        let removedSourceIDs = Set(old.webSourceIDs).subtracting(new.webSourceIDs)
        for sourceID in removedSourceIDs {
            webDetailSurfaceStore.releaseWebResources(forSourceID: sourceID)
        }
    }

    @MainActor
    private func reconcileSelectionAfterModelChange() {
        selectionController.reconcileSelectionAfterModelChange()
    }

    @MainActor
    private func applyLaunchSurface(_ surface: MainWindowLaunchSurface) {
        selectionController.applyLaunchSurface(surface)
    }

    @MainActor
    private func handleRepoSelection(_ repo: Repo) {
        selectionController.selectRepoOverview(repo)
    }

    @MainActor
    private func handleRepoTerminalSelection(_ repo: Repo) {
        selectionController.selectRepoTerminal(repo)
    }

    @MainActor
    private func handleRepoTerminalSelection(_ repo: Repo, preferredDirectory: URL?) {
        selectionController.selectRepoTerminal(repo, preferredDirectory: preferredDirectory)
    }

    @MainActor
    private func handleWorkspaceSelection(_ workspace: Workspace) {
        selectionController.selectWorkspace(workspace)
    }

    @MainActor
    private func handleWorkspaceSelection(_ workspace: Workspace, preferredDirectory: URL?) {
        selectionController.selectWorkspace(workspace, preferredDirectory: preferredDirectory)
    }

    @MainActor
    private func handleWebSourceSelection(_ source: WebSource) {
        selectionController.selectWebSource(source)
    }

    @MainActor
    private func handleWorkspaceCreated() {
        guard currentSelectedWorkspace == nil else { return }
        viewState.isRightPaneVisible = false
    }

    @MainActor
    private func markAccessed(repo: Repo) {
        accessRecorder.record(repo: repo, modelContext: modelContext)
    }

    @MainActor
    private func markAccessed(workspace: Workspace) {
        accessRecorder.record(workspace: workspace, modelContext: modelContext)
    }

    @MainActor
    private func markAccessed(webSource: WebSource) {
        accessRecorder.record(webSource: webSource, modelContext: modelContext)
    }

    private func handleTerminalProcessExit(sessionID: UUID) {
        guard
            let result = terminalSessionController.handleProcessExit(
                sessionID: sessionID,
                tileTreeStore: tileTreeStore,
                defaultHomeDirectory: resolvedDefaultHostDirectory,
                repos: repos,
                normalizePath: normalizePath
            )
        else { return }
        applyTerminalSessionResult(result)
    }

    @MainActor
    private func retireTerminalSessions(inScope scopeKey: HostTerminalSessionKey) async throws {
        let sessionIDs = tileTreeStore.terminalSessionIDs(inScope: scopeKey)
        for sessionID in sessionIDs {
            try await tileTreeStore.surfaceStore.closeForSessionRetirement(sessionID: sessionID)
        }

        let retiredSessionIDs = tileTreeStore.retireSessions(inScope: scopeKey)
        guard !retiredSessionIDs.isEmpty else { return }

        terminalFocusCoordinator.cancelPendingFocusRequest(reason: "workspace_lifecycle_retired_sessions")
    }

    /// The forced-teardown state machine for operator archive-with-teardown, wired to the live
    /// stores: scope enumeration and retirement from the tile tree, tmux resolution/kill through
    /// the store's seams, and the graceful retirement close from the surface store.
    @MainActor
    private func makeWorkspaceTerminalTeardownController() -> WorkspaceTerminalTeardownController {
        WorkspaceTerminalTeardownController(
            sessionsInScope: { key in
                tileTreeStore.sessions(inScope: key).flatMap { primary in
                    tileTreeStore.splitSessions(forPrimarySessionID: primary.id) + [primary]
                }
            },
            tmuxSessionName: { session in
                WorkspaceTerminalTeardownController.tmuxSessionNameForTeardown(
                    of: session,
                    mode: tileTreeStore.resolveTerminalMultiplexingMode()
                )
            },
            killTmuxSession: tileTreeStore.killTmuxSession,
            closeForRetirement: { sessionID in
                _ = try await tileTreeStore.surfaceStore.closeForSessionRetirement(sessionID: sessionID)
            },
            retireSessions: { key in
                tileTreeStore.retireSessions(inScope: key)
            }
        )
    }

    @MainActor
    private func applyTerminalSessionResult(
        _ result: MainWindowTerminalSessionController.SessionFocusResult
    ) {
        setSelectedWorkspace(result.syncedWorkspace)
        acknowledgeVisitedAgentSession(result.focusSessionID)
        focusTerminalTab(result.focusSessionID)
    }

    @MainActor
    private func acknowledgeVisitedAttentionTarget(
        _ target: WorkspaceStatusAggregator.AttentionTarget
    ) {
        workspaceStatusAggregator.acknowledgeAttention(for: target)
        refreshWorkspaceStatusAggregator()
    }

    @MainActor
    private func acknowledgeVisitedAgentSession(_ sessionID: UUID) {
        guard let status = agentSessionRegistry.statuses[sessionID] else { return }
        workspaceStatusAggregator.acknowledgeAttention(for: status)
        refreshWorkspaceStatusAggregator()
    }

    @MainActor
    private func syncSidebarSelectionToActiveSessionFromActiveHostSession() {
        let syncedWorkspace = terminalSessionController.syncedWorkspaceSelection(
            activeHostSession: activeHostSession,
            repos: repos,
            normalizePath: normalizePath
        )
        setSelectedWorkspace(syncedWorkspace)
    }

    @MainActor
    private func createTerminalTabFromCurrentContext() {
        guard
            let result = terminalSessionController.createTabFromCurrentContext(
                tileTreeStore: tileTreeStore,
                defaultHomeDirectory: resolvedDefaultHostDirectory,
                repos: repos,
                normalizePath: normalizePath,
                activateHostSession: { key, directory, customCommand in
                    activateHostSession(key: key, directory: directory, customCommand: customCommand)
                }
            )
        else { return }
        applyTerminalSessionResult(result)
    }

    @MainActor
    private func selectTerminalTab(sessionID: UUID) {
        guard
            let result = terminalSessionController.selectTab(
                sessionID: sessionID,
                tileTreeStore: tileTreeStore,
                repos: repos,
                normalizePath: normalizePath
            )
        else { return }
        applyTerminalSessionResult(result)
    }

    @MainActor
    private func selectAdjacentTerminalTab(offset: Int) {
        guard
            let result = terminalSessionController.selectAdjacentTab(
                offset: offset,
                tileTreeStore: tileTreeStore,
                repos: repos,
                normalizePath: normalizePath
            )
        else { return }
        applyTerminalSessionResult(result)
    }

    @MainActor
    private func closeActiveTerminalTab() {
        guard
            let result = terminalSessionController.closeActiveTab(
                tileTreeStore: tileTreeStore,
                defaultHomeDirectory: resolvedDefaultHostDirectory,
                repos: repos,
                normalizePath: normalizePath,
                requestClose: requestTerminalClose(sessionID:)
            )
        else { return }
        applyTerminalSessionResult(result)
    }

    @MainActor
    private func closeTerminalTab(sessionID: UUID) {
        requestCloseTerminalTabs([sessionID])
    }

    @MainActor
    private func renameTerminalTab(sessionID: UUID, title: String?) {
        _ = tileTreeStore.setTabTitle(title, for: sessionID)
    }

    @MainActor
    private func requestCloseTerminalTabs(_ sessionIDs: [UUID]) {
        let results = terminalSessionController.closeTabs(
            sessionIDs,
            tileTreeStore: tileTreeStore,
            defaultHomeDirectory: resolvedDefaultHostDirectory,
            repos: repos,
            normalizePath: normalizePath,
            requestClose: requestTerminalClose(sessionID:)
        )
        for result in results {
            applyTerminalSessionResult(result)
        }
    }

    @MainActor
    private func requestCloseConfirmationForTerminalTab(sessionID: UUID) {
        viewState.terminalCloseConfirmation = terminalSessionController.closeConfirmation(
            sessionID: sessionID,
            tileTreeStore: tileTreeStore
        )
    }

    @MainActor
    private func forceCloseTerminalTab(sessionID: UUID) {
        guard
            let result = terminalSessionController.forceCloseTab(
                sessionID: sessionID,
                tileTreeStore: tileTreeStore,
                defaultHomeDirectory: resolvedDefaultHostDirectory,
                repos: repos,
                normalizePath: normalizePath
            )
        else { return }
        applyTerminalSessionResult(result)
    }

    @MainActor
    private func requestTerminalClose(sessionID: UUID) -> Bool {
        guard let terminal = tileTreeStore.surfaceStore.terminal(for: sessionID) else {
            return false
        }
        terminal.requestClose()
        return true
    }

    @MainActor
    private func configureAutomationIntegration() async {
        await AutomationIntegrationLifecycle.shared.configure(
            tileTreeStore: tileTreeStore,
            focusTerminal: { sessionID in
                focusTerminalTab(sessionID)
            },
            requestCloseTerminal: { sessionID in
                requestCloseTerminalTabs([sessionID])
            },
            webSurfaceRecords: { webSources.map(WebSurfaceRecord.init(from:)) },
            workspaceInventory: {
                AutomationWorkspaceEnumerator.inventory(
                    repos: repos,
                    selectedWorkspaceID: viewState.selectedWorkspace?.workspaceID,
                    selectedRepoID: viewState.selectedRepoForLandingID
                )
            },
            gestureVerbs: automationGestureVerbs.makeVerbs(),
            uiState: {
                AutomationUIStateEnumerator.capture(
                    repos: repos,
                    selectedWorkspaceID: viewState.selectedWorkspace?.workspaceID,
                    selectedRepoID: viewState.selectedRepoForLandingID,
                    workspaceStatuses: workspaceStatusAggregator.workspaceStatuses,
                    // The pill's own resolver, so the reported count can never diverge
                    // from the rendered "N need you" text.
                    attentionCount: AttentionSummaryResolver.resolve(
                        attentionItems: workspaceStatusAggregator.attentionItems,
                        repos: repos
                    ).count,
                    // The other half of the pill's visibility rule: the minimalToolbar
                    // experiment removes the toolbar group it lives in. Read at call time
                    // from the same defaults + forced-on env the @ExperimentalFeatureFlag
                    // wrapper reads, so toggling the experiment shows in the next read.
                    minimalToolbar: ExperimentalFeatures.isEnabled(.minimalToolbar),
                    banners: visibleAutomationBanners,
                    tileTreeStore: tileTreeStore
                )
            }
        )
    }

    /// The banners `splitViewBody` currently stacks above the split view, as stable ids
    /// for the ui-state projection; the conditions mirror `splitViewBody`'s `if` chain.
    @MainActor
    private var visibleAutomationBanners: [AutomationUIBanner] {
        var banners: [AutomationUIBanner] = []
        if modelStoreStatusController.shouldShowDegradedWarning {
            banners.append(.modelStoreDegraded)
        }
        if !workspaceOrphanState.visibleItems.isEmpty {
            banners.append(.workspaceOrphanCleanup)
        }
        if restoreState.bannerPlan != nil {
            banners.append(.restoreSessions)
        }
        return banners
    }

    @MainActor
    private func focusTerminalTab(_ sessionID: UUID) {
        terminalFocusCoordinator.requestMainTerminalFocus(
            targetSessionID: sessionID,
            activateApp: false,
            surfaceStore: tileTreeStore.surfaceStore,
            activeSessionID: tileTreeStore.activeSessionID
        )
    }

    @MainActor
    private func performDeferredStartupWorkspaceStatusSync() async {
        guard !didScheduleInitialWorkspaceStatusSync else { return }
        didScheduleInitialWorkspaceStatusSync = true

        // Give the first window render a head start before remote status sync begins.
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }

        await syncWorkspaceStatuses(trigger: "launch_deferred")
        await refreshWorkspaceOrphans(trigger: "launch_deferred")
        await purgeExpiredArchivedWorkspaces(trigger: "launch_deferred")
    }

    @MainActor
    private func purgeExpiredArchivedWorkspaces(trigger: String) async {
        let delayDays = ArchivedWorkspaceSettings.purgeDays()
        let candidates = maintenanceController.expiredArchivedWorkspaces(
            repos.flatMap(\.workspaces),
            now: Date(),
            delayDays: delayDays
        )
        guard !candidates.isEmpty else { return }

        let startedAt = Date()
        let controller = SidebarWorkspaceController(
            modelContext: modelContext,
            workspaceService: workspaceService,
            workspaceProviderRegistry: workspaceProviderRegistry,
            retireTerminalSessions: { key in
                try await retireTerminalSessions(inScope: key)
            }
        )

        var purgedCount = 0
        for workspace in candidates {
            let wasSelected = currentSelectedWorkspace?.id == workspace.id
            do {
                try await controller.deleteWorkspace(workspace, deleteFiles: true)
                if wasSelected {
                    setSelectedWorkspace(nil)
                }
                purgedCount += 1
            } catch {
                archivedWorkspacePurgeLog.error(
                    "[ArchivedWorkspacePurge] Failed to purge '\(workspace.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        perfLog.info(
            "[Perf] metric=archived_workspace_purge duration_ms=\(String(format: "%.2f", Date().timeIntervalSince(startedAt) * 1000), privacy: .public) trigger=\(trigger, privacy: .public) delay_days=\(delayDays, privacy: .public) candidate_count=\(candidates.count, privacy: .public) purged_count=\(purgedCount, privacy: .public)"
        )
    }

    @MainActor
    private func syncWorkspaceStatuses(trigger: String) async {
        await maintenanceController.syncWorkspaceStatuses(
            repos: repos,
            registry: workspaceProviderRegistry,
            modelContext: modelContext,
            trigger: trigger
        )
    }

    @MainActor
    private func refreshWorkspaceOrphans(trigger: String) async {
        // Fixture mode replaces the filesystem scan wholesale: real leftovers on a dev
        // machine would make captures (and ui-state goldens) machine-dependent.
        if let fixtureItems = UIFixtureOrphanBannerBootstrap.fixtureScanResult() {
            workspaceOrphanState.applyScanResult(fixtureItems)
            return
        }
        let scanStartedAt = Date()
        let snapshots = workspaceOrphanController.repositorySnapshots(repos: repos)
        let reconciler = await makeWorkspaceOrphanReconciler()

        let result = await reconciler.scan(repositories: snapshots)
        workspaceOrphanState.applyScanResult(result.items)

        perfLog.info(
            "[Perf] metric=workspace_orphan_scan duration_ms=\(String(format: "%.2f", Date().timeIntervalSince(scanStartedAt) * 1000), privacy: .public) trigger=\(trigger, privacy: .public) repo_count=\(snapshots.count, privacy: .public) item_count=\(result.items.count, privacy: .public)"
        )
    }

    @MainActor
    private func makeWorkspaceOrphanReconciler() async -> WorkspaceOrphanReconciler {
        WorkspaceOrphanReconciler(
            workspacesRoot: await workspaceService.workspacesRoot,
            lumeWorkspaceStorageURL: await LumeValidatedBaseService.shared
                .workspaceVMStorageDirectoryURL
        )
    }

    @MainActor
    private func cleanWorkspaceOrphan(_ item: WorkspaceOrphanItem) async {
        guard !workspaceOrphanState.isCleaning(item) else { return }
        workspaceOrphanState.beginCleaning(item)
        defer {
            workspaceOrphanState.endCleaning(item)
        }

        let reconciler = await makeWorkspaceOrphanReconciler()

        do {
            for step in workspaceOrphanController.cleanupSteps(for: item) {
                switch step {
                case .pruneGitWorktree:
                    try await reconciler.cleanupGitWorktree(item)
                case .deleteWorkspaceRecord:
                    try workspaceOrphanController.deleteWorkspaceRecord(
                        for: item,
                        in: repos,
                        modelContext: modelContext
                    )
                case .deleteLumeVM:
                    try await workspaceOrphanController.deleteLumeVM(
                        for: item,
                        registry: workspaceProviderRegistry
                    )
                }
            }

            workspaceOrphanState.removeCleanedItem(item)
            await refreshWorkspaceOrphans(trigger: "cleanup")
        } catch {
            presentWorkspaceOperationError(
                workspaceOrphanController.cleanupFailureMessage(for: item, error: error)
            )
        }
    }

    @MainActor
    private func openDesktop(for workspace: Workspace) {
        guard let provider = workspaceProviderRegistry.provider(for: workspace) else {
            presentWorkspaceOperationError(
                "No workspace provider is registered for '\(workspace.backendIdentifier)'."
            )
            return
        }

        Task { @MainActor in
            do {
                try await workspaceProviderSetupActionRunner.run(
                    provider: provider,
                    action: .openDesktop(workspaceName: workspace.name)
                ) {
                    await openDesktopAfterSetup(workspace, provider: provider)
                }
            } catch {
                presentWorkspaceOperationError(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func openDesktopForCurrentSelection() {
        guard let workspace = currentSelectedWorkspace,
            selectedWorkspaceSupportsDesktop,
            workspace.status != .provisioning
        else {
            return
        }

        openDesktop(for: workspace)
    }

    @MainActor
    private func openDesktopAfterSetup(
        _ workspace: Workspace,
        provider: any WorkspaceProviderProtocol
    ) async {
        viewState.connectingWorkspaceID = workspace.id

        do {
            let launchSpec = try await provider.desktopLaunchSpec(for: WorkspaceProviderTarget(workspace))
            guard viewState.connectingWorkspaceID == workspace.id else { return }
            viewState.connectingWorkspaceID = nil
            workspace.status = launchSpec.statusAfterLaunch
            try? modelContext.save()
            NSWorkspace.shared.open(launchSpec.vncURL)
        } catch {
            guard viewState.connectingWorkspaceID == workspace.id else { return }
            viewState.connectingWorkspaceID = nil
            presentWorkspaceOperationError(error.localizedDescription)
        }
    }

    @MainActor
    private func ensureInitialHostSession(caller: MainWindowLifecycleController.BootstrapCaller) {
        // When durable restore is enabled, let the RestorePlan own repo/workspace
        // (re)creation so a resume surface is never shadowed by a manifest-seeded
        // session on the same key (issue #783 #3). The default-home fallback below
        // still seeds one shell so the window isn't empty pre-restore, and
        // executeRestore retires that shell if the plan claims its key.
        if !restoreSessionsOnLaunchEnabled,
            !tileTreeStore.hasSessions,
            let snapshot = TerminalContinuityManifest.decode(from: terminalContinuityManifestRawValue)?
                .hostSessionSnapshot(excludingScopeKeys: terminalContinuityController.archivedWorkspaceScopeKeys)
        {
            tileTreeStore.restoreSessions(
                snapshot.sessions,
                activeSessionID: snapshot.activeSessionID,
                activeSessionIDByScopeKey: snapshot.activeSessionIDByScopeKey
            )
            PerformanceSignposts.noteInitialHostSessionBootstrap(
                caller: caller.rawValue,
                branch: "manifest_restore",
                sessionCount: tileTreeStore.sessions.count
            )
            return
        }

        let seeded = terminalSessionController.ensureInitialHostSession(
            tileTreeStore: tileTreeStore,
            defaultHomeDirectory: resolvedDefaultHostDirectory,
            activateHostSession: { key, directory, customCommand in
                activateHostSession(key: key, directory: directory, customCommand: customCommand)
            }
        )
        PerformanceSignposts.noteInitialHostSessionBootstrap(
            caller: caller.rawValue,
            branch: seeded == nil ? "noop" : "fresh_seed",
            sessionCount: tileTreeStore.sessions.count
        )
    }

    @MainActor
    private func toggleSidebarVisibility() {
        withAnimation(.easeInOut(duration: 0.16)) {
            switch viewState.columnVisibility {
            case .detailOnly:
                viewState.columnVisibility = .all
            case .all:
                viewState.columnVisibility = .detailOnly
            default:
                viewState.columnVisibility = .detailOnly
            }
        }
    }

    @MainActor
    private func toggleInspectorVisibility() {
        withAnimation(.easeInOut(duration: 0.2)) {
            inspectorStateController.toggleInspectorVisibility(
                hasTarget: hasInspectorTarget,
                isVisible: &viewState.isRightPaneVisible
            )
        }
    }

    @MainActor
    private func toggleTerminalPanelVisibility() {
        guard viewState.selectedCodePreview != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            viewState.isTerminalPanelVisible.toggle()
        }
    }

    @MainActor
    private func openInDefaultEditor() {
        performOpenInEditor(
            editorID: nil,
            trigger: inferOpenInEditorTriggerFromCurrentEvent()
        )
    }

    @MainActor
    private func openInSelectedEditor(_ editorID: ExternalEditorID) {
        performOpenInEditor(
            editorID: editorID,
            trigger: .uiMenuSelection
        )
    }

    @MainActor
    private func performOpenInEditor(
        editorID: ExternalEditorID?,
        trigger: OpenInEditorLaunchTrigger
    ) {
        do {
            try OpenInEditorShortcutFlow.perform(
                target: openInEditorTarget,
                editorID: editorID,
                externalEditorService: externalEditorService,
                trigger: trigger
            )
        } catch {
            presentOpenInEditorError(error)
        }
    }

    @MainActor
    private func revealInFinder() {
        guard let target = openInEditorTarget else { return }
        switch target {
        case .project(let rootURL):
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: rootURL.path)
        case .projectAndFile(let rootURL, let fileURL):
            NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: rootURL.path)
        }
    }

    @MainActor
    private func copyWorkspacePath() {
        guard let target = openInEditorTarget else { return }
        let path: String
        switch target {
        case .project(let rootURL):
            path = rootURL.path
        case .projectAndFile(_, let fileURL):
            path = fileURL.path
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @MainActor
    private func inferOpenInEditorTriggerFromCurrentEvent() -> OpenInEditorLaunchTrigger {
        guard let event = NSApp.currentEvent else {
            return .unknown
        }

        if let chord = ShortcutChord(event: event),
            chord == AppChromeShortcut.openInEditor.chord
        {
            return .shortcut
        }

        return .uiPrimaryAction
    }

    private func handleCodePreviewSelection(_ selection: CodePreviewSelection) {
        applyCodePreviewNavigation(
            codePreviewController.openAction(
                for: selection,
                current: viewState.selectedCodePreview,
                hasUnsavedEdits: appCommandState.hasUnsavedDocumentEdits
            )
        )
    }

    private func applyCodePreviewNavigation(
        _ action: CodePreviewNavigationController.NavigationAction
    ) {
        switch action {
        case .commit(let navigation):
            commitCodePreviewNavigation(navigation)
        case .prompt(let navigation):
            codePreviewNavigationState.raise(navigation)
        }
    }

    private func commitCodePreviewNavigation(_ navigation: PendingCodePreviewNavigation) {
        switch navigation {
        case .open(let selection):
            viewState.selectedCodePreview = selection
        case .close:
            viewState.selectedCodePreview = nil
        }
        viewState.isTerminalPanelVisible = true
    }

    @MainActor
    private func openSelectedWebSourceInBrowser() {
        guard let selectedWebSource = currentSelectedWebSource else { return }
        let webView =
            webDetailSurfaceStore
            .webSurface(for: webDetailTileID, source: selectedWebSource)
            .webView
        if let currentURL = webView.url {
            NSWorkspace.shared.open(currentURL)
        } else if let baseURL = selectedWebSource.baseURL {
            NSWorkspace.shared.open(baseURL)
        }
    }

    @MainActor
    private func reloadSelectedWebSource() {
        guard let selectedWebSource = currentSelectedWebSource else { return }
        let webView =
            webDetailSurfaceStore
            .webSurface(for: webDetailTileID, source: selectedWebSource)
            .webView
        if let currentURL = webView.url {
            webView.load(URLRequest(url: currentURL))
        } else if let baseURL = selectedWebSource.baseURL {
            webView.load(URLRequest(url: baseURL))
        }
    }

    /// Unguarded preview teardown used by repo/workspace removal and surface switches, where the
    /// surrounding selection has already changed. The dirty-edit veto deliberately does not fire
    /// here — a full repo/workspace-switch prompt is deferred (#704 Phase 4 follow-up); this path
    /// only tears the preview down alongside its context.
    /// Commits `.close` directly and must keep doing so: routing this through
    /// `codePreviewController.closeAction` would make repo/workspace removal prompt for unsaved
    /// edits instead of tearing the preview down, and every controller test would stay green.
    private func clearCodePreview() {
        commitCodePreviewNavigation(.close)
    }

    /// Guarded close for the editor's own Close button / terminal toggle: when the open file is
    /// dirty this pauses for Save / Discard / Cancel instead of dropping edits.
    private func requestCloseCodePreview() {
        applyCodePreviewNavigation(
            codePreviewController.closeAction(
                current: viewState.selectedCodePreview,
                hasUnsavedEdits: appCommandState.hasUnsavedDocumentEdits
            )
        )
    }

    /// Resolve a deferred code-preview navigation once the user answers the unsaved-changes prompt.
    private func resolvePendingCodePreviewNavigation(_ choice: DirtyNavigationChoice) {
        guard let pending = codePreviewNavigationState.pending else { return }
        switch codePreviewController.resolution(for: choice, pending: pending) {
        case .dismiss:
            codePreviewNavigationState.clearPending()
        case .commit(let navigation):
            codePreviewNavigationState.clearPending()
            commitCodePreviewNavigation(navigation)
        case .saveThenCommit(let navigation):
            // Capture the generation now; a newer navigation raised during the await bumps it and
            // must win. After the save, only commit this (captured) target if nothing superseded it
            // and the document is genuinely clean — the user may have typed more while the write was
            // in flight, which would leave it dirty again.
            let capturedGeneration = codePreviewNavigationState.generation
            Task { @MainActor in
                await appCommandState.saveDirtyDocument()
                if codePreviewNavigationState.canCommitDeferred(
                    capturedGeneration: capturedGeneration,
                    hasUnsavedEdits: appCommandState.hasUnsavedDocumentEdits
                ) {
                    commitCodePreviewNavigation(navigation)
                }
            }
        }
    }

    @MainActor
    private func activateSessionSwitcherHostSession(_ sessionID: UUID) {
        guard tileTreeStore.activateExistingSession(sessionID: sessionID) else { return }
        acknowledgeVisitedAgentSession(sessionID)
        if let activeHostSession,
            let destination = terminalSessionController.terminalNavigationDestination(
                for: activeHostSession,
                repos: repos,
                normalizePath: normalizePath
            )
        {
            applyNavigationDestination(destination)
        } else {
            clearSelectionForHostTerminalSurface()
        }
        focusTerminalTab(sessionID)
    }

    @MainActor
    private func clearSelectionForHostTerminalSurface() {
        setSelectedWorkspace(nil)
        setSelectedWebSource(nil)
        setSelectedRepoForLanding(nil)
        clearCodePreview()
        viewState.columnVisibility = .all
    }

    @MainActor
    private func presentSessionSwitcher() {
        presentedSessionSwitcherSnapshot = makeSessionSwitcherSnapshot()
        viewState.isShowingSessionSwitcher = true
    }

    @MainActor
    private func dismissSessionSwitcher() {
        viewState.isShowingSessionSwitcher = false
        presentedSessionSwitcherSnapshot = nil
    }

    @MainActor
    private func requestRightPaneRefreshAfterCodeSave() {
        if let workspace = currentSelectedWorkspace {
            rightPaneStateStore.state(for: workspace).requestRefresh()
        } else if let repo = currentSelectedRepoForLanding ?? selectedRepoForInspector {
            rightPaneStateStore.state(for: repo).requestRefresh()
        }
    }

    @MainActor
    private func refreshSessionSwitcherSnapshotIfPresented() {
        guard viewState.isShowingSessionSwitcher else { return }
        presentedSessionSwitcherSnapshot = makeSessionSwitcherSnapshot()
    }

    @MainActor
    private func syncAppCommands() {
        appCommandState.setMainWindowActions(
            mainWindowFocusedActions,
            availability: mainWindowCommandAvailabilitySnapshot
        )
    }

    @MainActor
    private func clearAppCommands() {
        appCommandState.clearMainWindowActions()
    }

    private func persistLastSurface(_ surface: MainWindowLastSurface) {
        lastSurfaceRawValue = surface.rawValue
    }

    private func terminalContextMenu(for session: HostTerminalSession) -> NSMenu? {
        guard let target = webSourceCreationTarget(for: session) else { return nil }

        let menu = NSMenu(title: "Terminal")
        menu.addItem(
            ContextMenuActionItem.make(
                title: target.buttonTitle,
                systemImage: target.iconName
            ) {
                webSourceCreationTarget = target
            }
        )
        return menu
    }

    private func webSourceCreationTarget(for session: HostTerminalSession) -> WebSourceCreationTarget? {
        switch session.key {
        case .repoPath(let repoPath):
            let normalizedRepoPath = normalizePath(repoPath)
            guard let repo = repos.first(where: { normalizePath($0.localPath) == normalizedRepoPath }) else {
                return nil
            }
            return .repo(repo)

        case .hostPath(let workspacePath):
            let normalizedWorkspacePath = normalizePath(workspacePath)
            guard
                let workspace =
                    repos
                    .flatMap(\.workspaces)
                    .first(where: { normalizePath($0.path) == normalizedWorkspacePath })
            else {
                return nil
            }
            return .workspace(workspace)

        case .backendSession(_, let instanceID):
            guard
                let workspace =
                    repos
                    .flatMap(\.workspaces)
                    .first(where: { $0.terminalSessionIdentifier == instanceID })
            else {
                return nil
            }
            return .workspace(workspace)

        case .defaultHome:
            return nil
        }
    }

    @MainActor
    private func syncOpenInEditorShortcutRouting() {
        OpenInEditorShortcutFlow.syncRouting(for: openInEditorTarget)
    }

    @MainActor
    private func presentOpenInEditorError(_ error: Error) {
        let message: String
        if let externalEditorError = error as? ExternalEditorError {
            message = externalEditorError.errorDescription ?? "Could not open the selected file."
        } else {
            message = error.localizedDescription
        }
        errorPresenter.present(source: .openInEditor, title: "Could Not Open Editor", message: message)
    }

    /// Surfaces a workspace-operation failure through the shared error presenter. Only this
    /// source notifies the host-Lume smoke automation (see the `.workspaceOperation` onChange).
    @MainActor
    private func presentWorkspaceOperationError(_ message: String) {
        errorPresenter.present(source: .workspaceOperation, title: "Could Not Open Workspace", message: message)
    }

    /// Surfaces a landing-flow failure (repo import, workspace creation from the landing view)
    /// through the shared error presenter.
    @MainActor
    private func presentLandingError(_ message: String) {
        errorPresenter.present(source: .landing, title: "Error", message: message)
    }

    @MainActor
    private func pruneRightPaneState() {
        inspectorStateController.pruneRightPaneState(store: rightPaneStateStore, repos: repos)
    }

    @discardableResult
    @MainActor
    private func activateHostSession(
        key: HostTerminalSessionKey, directory: URL, customCommand: String? = nil, initialCommand: String? = nil
    ) -> HostTerminalSession {
        let result = tileTreeStore.activateSession(
            key: key,
            directory: directory,
            customCommand: customCommand,
            initialCommand: initialCommand
        )
        if result.created {
            hostSessionLog.info(
                "[HostSession] Created session \(result.session.id.uuidString, privacy: .public) key=\(key.debugDescription, privacy: .public) path=\(result.session.directoryPath, privacy: .public) (total sessions=\(tileTreeStore.sessions.count, privacy: .public))"
            )
        } else {
            hostSessionLog.info(
                "[HostSession] Reusing session \(result.session.id.uuidString, privacy: .public) key=\(key.debugDescription, privacy: .public) path=\(result.session.directoryPath, privacy: .public)"
            )
        }

        return result.session
    }

    private func focusWorkspaceWindow() {
        // Window activation only — the coordinator drives terminal focus
        // via requestMainTerminalFocus called from the selection handlers.
        // Gated by AppActivationPolicy so shared-desktop mode never steals focus.
        AppActivationPolicy.shared.activateAndFocusFrontWindowIfAllowed()
    }

    private func path(_ path: String, isInside root: String) -> Bool {
        MainWindowPathResolution.path(path, isInside: root)
    }

    private func normalizePath(_ rawPath: String) -> String {
        MainWindowPathResolution.normalize(rawPath)
    }

    /// Cold-start restore (experimental, opt-in): compute what could be restored
    /// from the previous run and, when non-empty, surface the restore banner.
    /// A no-op unless the `restoreSessionsOnLaunch` flag is enabled.
    @MainActor
    private func computeRestorePlanIfEnabled() async {
        guard restoreSessionsOnLaunchEnabled, let localStateStore else { return }
        await smokeDriver.waitForFixtureContinuitySeed()
        let index = RestoreTargetIndexBuilder(
            homeDirectoryPath: resolvedDefaultHostDirectory.path,
            normalizePath: RestorePathNormalization.normalize
        ).build(repos: repos)
        let plan = await TerminalRestoreCoordinator(
            localStateStore: localStateStore,
            normalizePath: RestorePathNormalization.normalize
        ).makePlan(index: index)
        switch restoreController.disposition(
            for: plan,
            handledRunID: restoreHandledRunID,
            seedKey: .defaultHome,
            seedDirectory: resolvedDefaultHostDirectory
        ) {
        case .noRestorableSurfaces:
            restoreLog.info("[Restore] no restorable surfaces from previous run")
        case .alreadyHandled(let previousRunID):
            restoreLog.info(
                "[Restore] suppressed banner: previous run \(previousRunID ?? "?", privacy: .public) already handled"
            )
        case .onlyDuplicatesLaunchSeed:
            restoreLog.info("[Restore] suppressed banner: plan only duplicates the launch seed")
        case .offer:
            restoreLog.info("[Restore] planned \(plan.surfaces.count, privacy: .public) restorable surface(s)")
            restoreState.offer(plan)
            autorunRestoreIfRequested(plan)
        }
    }

    /// Dev-only drive hook for headless restore verification: with
    /// `WORKSPACES_RESTORE_AUTORUN=1`, a planned restore executes immediately as
    /// if the user clicked Restore, so smoke scripts can exercise the real
    /// resume path without desktop input. No effect outside that environment.
    private func autorunRestoreIfRequested(_ plan: RestorePlan) {
        guard restoreController.isAutorunRequested(environment: ProcessInfo.processInfo.environment)
        else { return }
        restoreLog.info("[Restore] autorun: executing planned restore after settle delay")
        Task { @MainActor in
            // Approximate a real banner click: let launch layout settle first.
            try? await Task.sleep(for: .seconds(3))
            await executeRestore(plan)
            markRestorePlanHandled(plan)
        }
    }

    /// Record that the user acted on this plan's prior run (restored or
    /// dismissed), then hide the banner for the rest of this launch. Later
    /// launches that select the same prior run won't re-offer it.
    /// The dismissal is deliberately outside the `if`: a plan with no run identity persists
    /// nothing but must still hide the banner. Pairing them would leave such a plan on screen.
    private func markRestorePlanHandled(_ plan: RestorePlan) {
        if let previousRunID = restoreController.handledRunID(for: plan) {
            restoreHandledRunID = previousRunID
        }
        restoreState.dismissBanner()
    }

    /// Launch each surface in a restore plan, one created session per continuity
    /// row. Reattach surfaces launch on their row's recorded tmux name (a split
    /// pane's differs from the directory derivation); resume surfaces get
    /// `claude --resume` typed into their login shell as initial input (correct
    /// PATH + hook env — see `GhosttyTerminalConfig.initialInput`) unless their
    /// `-A` target is already a live session another surface owns.
    /// Then honor the plan's advisory focus by re-activating the selected surface.
    @MainActor
    private func executeRestore(_ plan: RestorePlan) async {
        // #3: the restore plan owns every key it restores. Retire any session a
        // pre-restore seed (the default-home fallback) left on those keys, so a
        // resume/reattach surface is created fresh and the coordinator's key-reuse
        // path can't drop its initial command.
        // Read before retiring: these are the tmux names this launch is holding, and they are
        // what makes a kill below attributable. After the retire loop the sessions are gone and
        // the app can no longer tell its own seed from a stranger's session on the shared
        // socket (#1267).
        let ownedTmuxSessionNames = Set(tileTreeStore.sessions.map(\.effectiveTmuxSessionName))

        for key in restoreController.ownedSessionKeys(in: plan) {
            _ = tileTreeStore.retireSessions(inScope: key)
        }

        // Same ownership, tmux layer: the planner only chose resume because the
        // prior tmux session is gone, so a live session on the resume surface's
        // deterministic name can only be this launch's seed artifact. Kill it so
        // the resume surface starts a fresh session instead of `-A`-attaching to
        // the retired seed's leftover shell. Names another surface reattaches to
        // are excluded by the controller (#1233).
        let tmuxProbe = TmuxSessionProbe()
        let teardownScope = restoreController.tmuxSessionNamesToKill(
            in: plan,
            ownedTmuxSessionNames: ownedTmuxSessionNames
        )
        for sessionName in teardownScope.skippedUnowned {
            restoreLog.info(
                "[Restore] leaving tmux session \(sessionName, privacy: .public) alone: this launch did not create it"
            )
        }
        for sessionName in teardownScope.kill {
            await tmuxProbe.killSession(sessionName)
        }

        // Probe before launch: any resume launch name still alive after the kill
        // pass belongs to a session another surface reattaches to, so its `-A`
        // launch would join that shared session — suppress the resume command
        // instead of typing it into a shell another surface owns (#1233).
        var liveResumeLaunchNames: Set<String> = []
        for sessionName in restoreController.resumeLaunchSessionNames(in: plan)
        where await tmuxProbe.isSessionAlive(sessionName) {
            liveResumeLaunchNames.insert(sessionName)
        }

        var activatedByHostSessionID: [UUID: HostTerminalSession] = [:]
        for surface in plan.surfaces {
            if surface.launchDirectoryFellBack {
                restoreLog.notice(
                    "[Restore] surface \(surface.hostSessionID.uuidString, privacy: .public) recorded directory is gone; launching in fallback \(surface.directory.path, privacy: .public)"
                )
            }
            let initialCommand = restoreController.initialCommand(
                for: surface, liveSessionNames: liveResumeLaunchNames)
            if initialCommand == nil, case .resumeClaude = surface.action {
                restoreLog.notice(
                    "[Restore] surface \(surface.hostSessionID.uuidString, privacy: .public) resume target is a live session; attaching without the resume command"
                )
            }
            // One session per continuity row (never key-reuse): sibling rows sharing
            // a key — a primary and its recorded split panes — each launch on their
            // own recorded tmux target (#1232).
            let session = tileTreeStore.createRestoredSession(
                key: surface.key,
                directory: surface.directory,
                initialCommand: initialCommand,
                tmuxSessionNameOverride: restoreController.tmuxSessionNameOverride(for: surface.action)
            )
            hostSessionLog.info(
                "[HostSession] Created restored session \(session.id.uuidString, privacy: .public) key=\(surface.key.debugDescription, privacy: .public) path=\(session.directoryPath, privacy: .public) (total sessions=\(tileTreeStore.sessions.count, privacy: .public))"
            )
            activatedByHostSessionID[surface.hostSessionID] = session
        }

        if let selected = plan.selectedHostSessionID, let target = activatedByHostSessionID[selected] {
            _ = tileTreeStore.activateExistingSession(sessionID: target.id)
        }
        restoreLog.info("[Restore] executed \(plan.surfaces.count, privacy: .public) surface(s)")
    }

    /// Coalesces the high-frequency agent-event refresh path: bursts of status or
    /// session changes collapse to one trailing-edge aggregation pass. Immediate
    /// call sites (launch, model changes, user acknowledgement) stay direct so the
    /// sidebar updates without the window's delay.
    private func scheduleWorkspaceStatusAggregatorRefresh() {
        statusAggregationCoalescer.schedule { refreshWorkspaceStatusAggregator() }
    }

    private func refreshWorkspaceStatusAggregator() {
        let inputs = maintenanceController.aggregatorInputs(
            repos: repos,
            sessions: tileTreeStore.sessions,
            agentStatusBySessionID: agentSessionRegistry.statuses,
            registry: workspaceProviderRegistry,
            normalizePath: { url in normalizePath(url.path) }
        )
        workspaceStatusAggregator.update(workspaces: inputs.workspaces, repos: inputs.repos)
    }

    @MainActor
    private func seedLandingWorkspaceEnvironmentStateIfNeeded() async -> Bool {
        guard
            let state = await workspaceEnvironmentOptionsController.seedFixtureStateIfNeeded(
                registry: workspaceProviderRegistry,
                runtimeService: lumeRuntimeService
            )
        else {
            return false
        }

        workspaceEnvironmentSheetState = state
        return true
    }

    @MainActor
    private func prewarmPerfTerminalSurfacesIfNeeded() {
        guard !didPrewarmPerfTerminalSurfaces else { return }
        guard
            let rawCount = ProcessInfo.processInfo.environment["WORKSPACES_PERF_PREWARM_TERMINAL_SURFACES"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let requestedCount = Int(rawCount),
            requestedCount > 0
        else {
            return
        }

        didPrewarmPerfTerminalSurfaces = true
        let surfaceCount = min(requestedCount, 40)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspaces-main-window-surface-perf", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var initializedSurfaceCount = 0
        for index in 0..<surfaceCount {
            let directory = root.appendingPathComponent("workspace-\(index)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let session = activateHostSession(
                key: .hostPath(directory.path),
                directory: directory
            )
            let terminal = tileTreeStore.terminalSurfaceView(for: session)
            if terminal.surface != nil {
                initializedSurfaceCount += 1
            }
        }

        perfLog.info(
            "[Perf] metric=main_window_terminal_surface_prewarm requested=\(surfaceCount, privacy: .public) initialized=\(initializedSurfaceCount, privacy: .public)"
        )
    }

    @MainActor
    private func refreshLandingWorkspaceEnvironmentState(trigger: String) async {
        workspaceEnvironmentSheetState = workspaceEnvironmentOptionsController.prepareSheetStateForPresentation(
            existingState: workspaceEnvironmentSheetState,
            registry: workspaceProviderRegistry,
        )
        workspaceEnvironmentSheetState = await workspaceEnvironmentOptionsController.refreshSheetState(
            registry: workspaceProviderRegistry,
            runtimeService: lumeRuntimeService,
            existingState: workspaceEnvironmentSheetState,
            trigger: trigger
        )
    }

    private func environmentOptions(for repo: Repo) -> [WorkspaceEnvironmentSheetOption] {
        workspaceEnvironmentOptionsController.environmentOptions(
            for: repo,
            registry: workspaceProviderRegistry,
            sheetState: workspaceEnvironmentSheetState
        )
    }
}

@MainActor
private final class ContextMenuActionItem: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc
    private func performAction(_ sender: Any?) {
        _ = sender
        action()
    }

    static func make(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let handler = ContextMenuActionItem(action: action)
        let item = NSMenuItem(
            title: title,
            action: #selector(ContextMenuActionItem.performAction(_:)),
            keyEquivalent: ""
        )
        item.target = handler
        item.representedObject = handler
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        return item
    }
}
