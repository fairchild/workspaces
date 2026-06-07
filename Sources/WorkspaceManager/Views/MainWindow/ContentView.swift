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

private let creationLog = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "WorkspaceCreation"
)

private struct ModelSnapshot: Equatable {
    let repoIDs: [UUID]
    let workspaceIDs: [UUID]
    let webSourceIDs: [UUID]
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var deepLinkState: WorkspaceDeepLinkState
    @Binding var lastSurfaceRawValue: String
    @ObservedObject var appCommandState: AppCommandState
    @ObservedObject var hostTerminalState: HostTerminalStateStore
    @ObservedObject var workspaceProviderSetupCoordinator: WorkspaceProviderSetupCoordinator
    @ObservedObject var hostLumeSmokeAutomation: HostLumeSmokeAutomationController
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
    @EnvironmentObject private var modelStoreStatusController: ModelStoreStatusController
    @Environment(\.workspaceService) private var workspaceService
    @Environment(\.workspaceProviderRegistry) private var workspaceProviderRegistry
    @EnvironmentObject private var agentSessionRegistry: AgentSessionRegistry
    @EnvironmentObject private var workspaceStatusAggregator: WorkspaceStatusAggregator
    @ObservedObject private var notificationCoordinator = NotificationCoordinator.shared

    @State private var viewState = MainWindowViewState()
    @State private var repoForNewWorkspaceFromLanding: Repo?
    @State private var isPreparingLandingNewWorkspaceSheet = false
    @State private var webSourceCreationTarget: WebSourceCreationTarget?
    @State private var landingErrorMessage: String?
    @State private var workspaceEnvironmentSheetState = WorkspaceEnvironmentSheetState.empty
    @State private var didScheduleInitialWorkspaceStatusSync = false
    @State private var accessRecorder = MainWindowAccessRecorder()
    @StateObject private var rightPaneStateStore = RightPaneStateStore()
    @StateObject private var webSurfaceStore = WebSurfaceStore()
    @StateObject private var terminalFocusCoordinator = TerminalFocusCoordinator()
    private let buildIdentity = AppBuildIdentity.current
    private let resolvedDefaultHostDirectory = HostTerminalDefaults.defaultWorkingDirectory()
        .standardizedFileURL
        .resolvingSymlinksInPath()
    private let bootstrapController = MainWindowBootstrapController()
    private let inspectorStateController = InspectorStateController()
    @State private var mainSelectionCoordinator = MainSelectionCoordinator()
    private let navigationStateController = MainWindowNavigationStateController()
    private let surfaceResolutionController = MainWindowSurfaceResolutionController()
    private let launchActionHandler = MainWindowLaunchActionHandler()
    private let presentationController = MainWindowPresentationController()
    private let terminalSessionController = MainWindowTerminalSessionController()
    private let splitRoutingController = SplitRoutingController()
    private let tabRoutingController = TabRoutingController()
    private let workspaceEnvironmentOptionsController = WorkspaceEnvironmentOptionsController()

    private var launchRepositoryService: LaunchRepositoryService {
        LaunchRepositoryService(modelContext: modelContext)
    }

    private var workspaceProviderSetupActionRunner: WorkspaceProviderSetupActionRunner {
        WorkspaceProviderSetupActionRunner(coordinator: workspaceProviderSetupCoordinator)
    }

    private var sessionPresentation: HostTerminalSessionPresentation {
        hostTerminalState.sessionPresentation
    }

    private var terminalMultiplexingMode: TerminalMultiplexingMode {
        TerminalMultiplexingMode.resolve(rawValue: terminalMultiplexingModeRawValue)
    }

    private var activeHostSession: HostTerminalSession? {
        presentationController.activeHostSession(
            activeSessionID: hostTerminalState.activeSessionID,
            sessions: hostTerminalState.sessions
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
            sessions: hostTerminalState.sessions,
            splitSession: { sessionID in
                hostTerminalState.splitSession(for: sessionID)
            }
        )
    }

    private var activeSessionKeyForSidebar: HostTerminalSessionKey? {
        presentationController.activeSessionKeyForSidebar(
            selectedWebSource: currentSelectedWebSource,
            activeSessionID: hostTerminalState.activeSessionID,
            sessions: hostTerminalState.sessions
        )
    }

    private var commandPaletteWorkspaceActivities: [UUID: SidebarSessionActivity] {
        let presentation = SidebarWorkspacePresentationController()
        let normalize: (URL) -> String = { url in normalizePath(url.path) }
        return Dictionary(
            uniqueKeysWithValues: repos.flatMap(\.workspaces).map { workspace in
                let key = presentation.sessionKey(
                    for: workspace,
                    registry: workspaceProviderRegistry,
                    normalizePath: normalize
                )
                let activity = presentation.sessionActivity(
                    for: key,
                    paneCountBySessionKey: paneCountBySessionKeyForSidebar,
                    activeSessionKey: activeSessionKeyForSidebar,
                    sessions: hostTerminalState.sessions,
                    agentStatusBySessionID: agentSessionRegistry.statuses
                )
                return (workspace.id, activity)
            }
        )
    }

    private var commandPaletteRepoActivities: [UUID: SidebarSessionActivity] {
        let presentation = SidebarWorkspacePresentationController()
        return Dictionary(
            uniqueKeysWithValues: repos.map { repo in
                let key = HostTerminalSessionKey.repoPath(normalizePath(repo.localURL.path))
                let baseline = presentation.sessionActivity(
                    for: key,
                    paneCountBySessionKey: paneCountBySessionKeyForSidebar,
                    activeSessionKey: activeSessionKeyForSidebar,
                    sessions: hostTerminalState.sessions,
                    agentStatusBySessionID: agentSessionRegistry.statuses
                )
                let bubbled =
                    workspaceStatusAggregator.repoStatuses[repo.id]
                    .map { SidebarSessionActivity.from($0) } ?? .inactive
                return (repo.id, baseline.mergedWithBubbled(bubbled))
            }
        )
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
            openCommandPalette: { viewState.isShowingCommandPalette = true }
        )
    }

    private var mainWindowCommandAvailabilitySnapshot: MainWindowCommandAvailability {
        MainWindowCommandAvailability(
            canToggleSidebar: true,
            canToggleInspector: true,
            canToggleTerminalPanel: true,
            canCreateTerminalTab: hostTerminalState.hasSessions,
            canCloseTerminalTab: hostTerminalState.hasSessions,
            canSelectNextTerminalTab: hostTerminalState.scopedSessions.count > 1,
            canSelectPreviousTerminalTab: hostTerminalState.scopedSessions.count > 1,
            canOpenInEditor: openInEditorFocusedAction != nil,
            canOpenInBrowser: openInBrowserFocusedAction != nil,
            canReloadWebSource: reloadWebSourceFocusedAction != nil,
            canOpenDesktop: openDesktopFocusedAction != nil,
            canRevealInFinder: revealInFinderFocusedAction != nil,
            canCopyPath: copyPathFocusedAction != nil,
            canOpenCommandPalette: true
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

    private var isShowingOpenInEditorError: Binding<Bool> {
        Binding(
            get: { viewState.openInEditorErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewState.openInEditorErrorMessage = nil
                }
            }
        )
    }

    @ViewBuilder
    private var terminalDetailContent: some View {
        MainTerminalDetailView(
            selectedWorkspace: currentSelectedWorkspace,
            selectedRepo: selectedRepoForInspector,
            activeHostSession: activeHostSession,
            hostTerminalSessions: hostTerminalState.sessions,
            visibleHostTerminalSessions: hostTerminalState.scopedSessions,
            activeHostTerminalSessionID: hostTerminalState.activeSessionID,
            activeSplitHostSession: hostTerminalState.splitSession(for: hostTerminalState.activeSessionID),
            activeSplitLayout: hostTerminalState.splitLayout(for: hostTerminalState.activeSessionID),
            activeSplitFraction: hostTerminalState.splitFraction(for: hostTerminalState.activeSessionID),
            hostSurfaceStore: hostTerminalState.surfaceStore,
            tabTitleOverrides: hostTerminalState.tabTitleOverridesBySessionID,
            agentStatuses: Array(agentSessionRegistry.statuses.values),
            terminalContextMenuProvider: terminalContextMenu(for:),
            onSplitFractionChanged: { nextFraction in
                guard let activeSessionID = hostTerminalState.activeSessionID else { return }
                _ = hostTerminalState.updateSplitFraction(
                    nextFraction,
                    forPrimarySessionID: activeSessionID
                )
            },
            onOpenRepoOverview: handleRepoSelection,
            onSelectTerminalTab: selectTerminalTab(sessionID:),
            onCloseTerminalTab: closeTerminalTab(sessionID:),
            onTerminalCloseConfirmationRequired: requestCloseConfirmationForTerminalTab(sessionID:),
            onTerminalProcessExit: handleTerminalProcessExit(sessionID:),
            selectedCodePreview: $viewState.selectedCodePreview,
            isTerminalPanelVisible: $viewState.isTerminalPanelVisible,
            onFileSelected: handleCodePreviewSelection,
            availableEditors: availableEditors,
            defaultEditor: defaultEditorDescriptor,
            onOpenInDefaultEditor: openInDefaultEditor,
            onOpenInEditor: openInSelectedEditor,
            rightPaneStateStore: rightPaneStateStore,
            isRightPaneVisible: $viewState.isRightPaneVisible
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selectedWebSource = currentSelectedWebSource {
            WebSourceDetailView(
                source: selectedWebSource,
                surfaceStore: webSurfaceStore
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
                        await presentNewWorkspaceFromLanding(repo)
                    }
                },
                onNewWebSource: { repo in
                    webSourceCreationTarget = .repo(repo)
                },
                onArchiveWorkspace: { workspace in
                    Task { @MainActor in
                        await archiveWorkspaceFromLanding(workspace)
                    }
                },
                onOpenWorkspaceInEditor: { workspace in
                    openWorkspaceInDefaultEditorFromLanding(workspace)
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
                hostSessions: hostTerminalState.sessions,
                agentStatusBySessionID: agentSessionRegistry.statuses,
                connectingWorkspaceID: viewState.connectingWorkspaceID,
                onRepoSelected: handleRepoSelection,
                onRepoTerminalSelected: handleRepoTerminalSelection,
                onWebSourceSelected: handleWebSourceSelection,
                onRequestWebSourceCreation: { target in
                    webSourceCreationTarget = target
                },
                onWorkspaceCreated: handleWorkspaceCreated,
                workspaceProviderSetupCoordinator: workspaceProviderSetupCoordinator,
                hostLumeSmokeAutomation: hostLumeSmokeAutomation
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 350)
        } detail: {
            detailContent
        }
    }

    private var splitViewWithToolbar: some View {
        Group {
            if minimalToolbarEnabled {
                splitViewBody
            } else {
                splitViewBody
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            AppBuildIdentityBadge(identity: buildIdentity)
                        }

                        ToolbarItemGroup(placement: .primaryAction) {
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
    private var splitViewBody: some View {
        VStack(spacing: 0) {
            if modelStoreStatusController.shouldShowDegradedWarning {
                ModelStoreDegradedBanner()
            }
            baseSplitView
        }
        .background(
            MainWindowHandleReader { window in
                terminalFocusCoordinator.bind(window: window)
            }
        )
    }

    private var splitViewWithLifecycleHandlers: some View {
        splitViewWithToolbar
            .onAppear {
                mainSelectionCoordinator.rebuildCachesIfNeeded(
                    repos: repos, webSources: webSources, normalizePath: normalizePath
                )
                ensureInitialHostSession()
                resolveSurfaceLifecycle()
                applyDiagnosticsFixtureIfNeeded()
                pruneRightPaneState()
                syncOpenInEditorShortcutRouting()
                refreshWorkspaceStatusAggregator()
                Task { @MainActor in
                    await hostLumeSmokeAutomation.noteLaunchReady()
                }
                notificationCoordinator.loadStoredAuth()
                Task { @MainActor in
                    terminalFocusCoordinator.attach(surfaceStore: hostTerminalState.surfaceStore)
                    _ = await seedLandingWorkspaceEnvironmentStateIfNeeded()
                }
            }
            .onChange(of: agentSessionRegistry.statuses) { _, _ in
                refreshWorkspaceStatusAggregator()
            }
            .onChange(of: hostTerminalState.sessions) { _, _ in
                refreshWorkspaceStatusAggregator()
                persistTerminalContinuitySnapshot()
            }
            .onChange(of: hostTerminalState.activeSessionID) { _, _ in
                persistTerminalContinuitySnapshot()
            }
            .task {
                await performDeferredStartupWorkspaceStatusSync()
            }
            .onDisappear {
                ShortcutRoutingPolicy.shared.setOverride(nil, for: AppChromeShortcut.openInEditor.chord)
            }
            .onChange(of: deepLinkState.pendingRequest) { _, _ in
                resolveSurfaceLifecycle()
            }
            .onChange(of: modelSnapshot) { _, _ in
                mainSelectionCoordinator.rebuildCachesIfNeeded(
                    repos: repos, webSources: webSources, normalizePath: normalizePath
                )
                reconcileSelectionAfterModelChange()
                resolveSurfaceLifecycle()
                applyDiagnosticsFixtureIfNeeded()
                hostTerminalState.pruneRepoSessions(validRepoPaths: normalizedRepoPathSnapshot)
                refreshWorkspaceStatusAggregator()
            }
            .onChange(of: inspectorTargetIDSet) { _, _ in
                pruneRightPaneState()
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
                        hostTerminalState: hostTerminalState,
                        focusTerminal: { sessionID in
                            terminalFocusCoordinator.focusTerminal(
                                sessionID: sessionID,
                                surfaceStore: hostTerminalState.surfaceStore
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
                        hostTerminalState: hostTerminalState,
                        focusTerminal: { sessionID in
                            terminalFocusCoordinator.focusTerminal(
                                sessionID: sessionID,
                                surfaceStore: hostTerminalState.surfaceStore
                            )
                        },
                        requestCloseTabs: { sessionIDs in
                            requestCloseTerminalTabs(sessionIDs)
                        }
                    )
                    syncSidebarSelectionToActiveSessionFromActiveHostSession()
                }
            }
    }

    private var splitViewWithFocusAndAlerts: some View {
        splitViewWithLifecycleHandlers
            .alert(
                "Could Not Open Editor",
                isPresented: isShowingOpenInEditorError
            ) {
                Button("OK", role: .cancel) {
                    viewState.openInEditorErrorMessage = nil
                }
            } message: {
                Text(viewState.openInEditorErrorMessage ?? "Unknown error.")
            }
            .alert(
                "Could Not Open Workspace",
                isPresented: Binding(
                    get: { viewState.workspaceOperationErrorMessage != nil },
                    set: { if !$0 { viewState.workspaceOperationErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { viewState.workspaceOperationErrorMessage = nil }
            } message: {
                Text(viewState.workspaceOperationErrorMessage ?? "Unknown error.")
            }
            .alert(
                "Could Not Complete Provider Setup",
                isPresented: Binding(
                    get: { workspaceProviderSetupCoordinator.errorMessage != nil },
                    set: { if !$0 { workspaceProviderSetupCoordinator.clearError() } }
                )
            ) {
                Button("OK", role: .cancel) { workspaceProviderSetupCoordinator.clearError() }
            } message: {
                Text(workspaceProviderSetupCoordinator.errorMessage ?? "Unknown error.")
            }
            .alert(
                "Close Terminal?",
                isPresented: Binding(
                    get: { viewState.terminalCloseConfirmation != nil },
                    set: { if !$0 { viewState.terminalCloseConfirmation = nil } }
                )
            ) {
                Button("Close", role: .destructive) {
                    guard let confirmation = viewState.terminalCloseConfirmation else { return }
                    viewState.terminalCloseConfirmation = nil
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
                item: Binding(
                    get: { workspaceProviderSetupCoordinator.confirmationRequest },
                    set: { request in
                        if request == nil {
                            workspaceProviderSetupCoordinator.cancelPendingAction()
                        }
                    }
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
                item: Binding(
                    get: { workspaceProviderSetupCoordinator.progressPresentation },
                    set: { _ in }
                )
            ) { presentation in
                WorkspaceProviderSetupProgressSheet(presentation: presentation)
                    .interactiveDismissDisabled(true)
            }
            .onChange(of: workspaceProviderSetupCoordinator.confirmationRequest) { _, request in
                guard let request else { return }
                Task { @MainActor in
                    await hostLumeSmokeAutomation.noteSetupConfirmationPresented(request)
                    if hostLumeSmokeAutomation.isEnabled {
                        DispatchQueue.main.async {
                            workspaceProviderSetupCoordinator.confirmAndContinue()
                        }
                    }
                }
            }
            .onChange(of: workspaceProviderSetupCoordinator.progressPresentation) { _, presentation in
                guard let presentation else { return }
                Task { @MainActor in
                    await hostLumeSmokeAutomation.noteSetupStepChanged(presentation)
                }
            }
            .onChange(of: workspaceProviderSetupCoordinator.errorMessage) { _, message in
                guard let message else { return }
                Task { @MainActor in
                    await hostLumeSmokeAutomation.noteFailure(
                        message: message,
                        recoveryHints: hostLumeSmokeRecoveryHints(for: message)
                    )
                }
            }
            .onChange(of: viewState.workspaceOperationErrorMessage) { _, message in
                guard let message else { return }
                Task { @MainActor in
                    await hostLumeSmokeAutomation.noteFailure(
                        message: message,
                        recoveryHints: hostLumeSmokeRecoveryHints(for: message)
                    )
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
            }
            .sheet(item: $repoForNewWorkspaceFromLanding) { repo in
                NewWorkspaceSheet(
                    repo: repo,
                    environmentOptions: environmentOptions(for: repo),
                    isPreparingEnvironmentOptions: isPreparingLandingNewWorkspaceSheet,
                    isCreateDisabled: false
                ) { name, nameSource, providerID, guestOS in
                    Task { @MainActor in
                        await createWorkspaceFromLanding(
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
                        addWebSource(
                            rawURL: rawURL,
                            displayName: displayName,
                            additionalAllowedDomainsRaw: additionalAllowedDomainsRaw,
                            target: target
                        )
                    }
                }
            }
            .sheet(isPresented: $viewState.isShowingCommandPalette) {
                CommandPaletteView(
                    repos: repos,
                    webSources: webSources,
                    workspaceActivities: commandPaletteWorkspaceActivities,
                    repoActivities: commandPaletteRepoActivities,
                    onSelectWorkspace: { workspace in
                        viewState.isShowingCommandPalette = false
                        handleWorkspaceSelection(workspace)
                    },
                    onSelectRepo: { repo in
                        viewState.isShowingCommandPalette = false
                        handleRepoSelection(repo)
                    },
                    onSelectWebSource: { source in
                        viewState.isShowingCommandPalette = false
                        handleWebSourceSelection(source)
                    },
                    onDismiss: {
                        viewState.isShowingCommandPalette = false
                    }
                )
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { landingErrorMessage != nil },
                    set: { if !$0 { landingErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { landingErrorMessage = nil }
            } message: {
                Text(landingErrorMessage ?? "Unknown error.")
            }
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

    @MainActor
    private func presentNewWorkspaceFromLanding(_ repo: Repo) async {
        InvestigationDiagnostics.emitSheet(
            phase: "landing_sheet_flow_started",
            fields: ["repo_id": repo.id.uuidString]
        )
        let attemptID = PerformanceSignposts.beginNewWorkspaceSheetReady(trigger: "landing")

        if await seedLandingWorkspaceEnvironmentStateIfNeeded() {
            InvestigationDiagnostics.emitSheet(
                phase: "landing_fixture_seeded",
                fields: ["repo_id": repo.id.uuidString]
            )
            repoForNewWorkspaceFromLanding = repo
            InvestigationDiagnostics.emitSheet(
                phase: "landing_sheet_context_set",
                fields: [
                    "repo_id": repo.id.uuidString,
                    "option_count": "\(environmentOptions(for: repo).count)",
                ]
            )
            PerformanceSignposts.endNewWorkspaceSheetReadyIfNeeded(
                attemptID: attemptID,
                outcome: "success"
            )
        }

        workspaceEnvironmentSheetState = workspaceEnvironmentOptionsController.prepareSheetStateForPresentation(
            existingState: workspaceEnvironmentSheetState,
            registry: workspaceProviderRegistry
        )
        repoForNewWorkspaceFromLanding = repo
        isPreparingLandingNewWorkspaceSheet = true
        InvestigationDiagnostics.emitSheet(
            phase: "landing_sheet_context_set",
            fields: [
                "repo_id": repo.id.uuidString,
                "option_count": "\(environmentOptions(for: repo).count)",
            ]
        )
        PerformanceSignposts.endNewWorkspaceSheetReadyIfNeeded(
            attemptID: attemptID,
            outcome: "success"
        )

        Task { @MainActor in
            defer {
                isPreparingLandingNewWorkspaceSheet = false
            }
            await refreshLandingWorkspaceEnvironmentState(trigger: "landing_sheet_open")
            InvestigationDiagnostics.emitSheet(
                phase: "landing_environment_refresh_completed",
                fields: [
                    "repo_id": repo.id.uuidString,
                    "lume_state": lumeRuntimeSnapshot?.state.rawValue ?? "pending",
                    "option_count": "\(environmentOptions(for: repo).count)",
                ]
            )
        }
    }

    @MainActor
    private func applyNavigationDestination(
        _ destination: MainWindowNavigationDestination,
        persistSurface: Bool = true
    ) {
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

        NSLog("[WorkspaceProvider] Discarding pending remote connection (%@)", reason)
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
                )
            )

            guard applySurfaceResolutionAction(action) else { break }
        }
    }

    @MainActor
    private func applyDiagnosticsFixtureIfNeeded() {
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
            NSLog("[UIFixture] Diagnostics bootstrap applied (workspace=%@)", workspace.name)
            return
        }

        if let repo = repos.first {
            handleRepoTerminalSelection(repo)
            rightPaneStateStore.state(for: repo).selectedTab = .diagnostics
            viewState.isRightPaneVisible = true
            viewState.didApplyFixtureDiagnosticsBootstrap = true
            NSLog("[UIFixture] Diagnostics bootstrap applied (repo=%@)", repo.name)
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
                        await presentNewWorkspaceFromLanding(repo)
                    }
                }
            }
        }
    }

    @MainActor
    private func clearInvalidLastSurfaceIfNeeded() {
        lastSurfaceRawValue = bootstrapController.sanitizedLastSurfaceRawValue(
            rawValue: lastSurfaceRawValue,
            repos: repos,
            webSources: webSources
        )
    }

    @MainActor
    private func reconcileSelectionAfterModelChange() {
        clearInvalidLastSurfaceIfNeeded()

        if let selectedWebSource = viewState.selectedWebSource,
            currentSelectedWebSource == nil
        {
            setSelectedWebSource(nil)
            webSurfaceStore.releaseInactiveSurface()
            handleSelectedWebSourceRemoval(selectedWebSource)
            return
        }

        if let selectedWorkspace = viewState.selectedWorkspace,
            currentSelectedWorkspace == nil
        {
            handleSelectedWorkspaceRemoval(selectedWorkspace)
            return
        }

        if viewState.selectedRepoForLandingID != nil,
            currentSelectedRepoForLanding == nil
        {
            handleSelectedRepoRemoval()
        }
    }

    @MainActor
    private func handleSelectedWorkspaceRemoval(_ removedWorkspace: MainWindowWorkspaceSelection) {
        setSelectedWorkspace(nil)
        clearCodePreview()

        if let surface = bootstrapController.fallbackSurfaceAfterRemovingWorkspace(
            repoID: removedWorkspace.repoID,
            repos: repos,
            webSources: webSources
        ) {
            viewState.didResolveInitialSurface = true
            applyLaunchSurface(surface)
            return
        }

        viewState.didResolveInitialSurface = false
    }

    @MainActor
    private func handleSelectedRepoRemoval() {
        setSelectedRepoForLanding(nil)
        clearCodePreview()

        applyFallbackAfterInvalidSelection()
    }

    @MainActor
    private func applyFallbackAfterInvalidSelection() {
        viewState.didResolveInitialSurface = false
        if let surface = bootstrapController.fallbackSurface(repos: repos, webSources: webSources) {
            viewState.didResolveInitialSurface = true
            applyLaunchSurface(surface)
        }
    }

    @MainActor
    private func applyLaunchSurface(_ surface: MainWindowLaunchSurface) {
        switch surface {
        case .repoOverview(let repo):
            handleRepoSelection(repo)
        case .repoTerminal(let repo):
            handleRepoTerminalSelection(
                repo,
                preferredDirectory: restoredLaunchDirectory(for: repo)
            )
        case .workspace(let workspace):
            handleWorkspaceSelection(
                workspace,
                preferredDirectory: restoredLaunchDirectory(for: workspace)
            )
        case .webView(let source):
            handleWebSourceSelection(source)
        }
    }

    @MainActor
    private func handleRepoSelection(_ repo: Repo) {
        terminalFocusCoordinator.cancelPendingFocusRequest(reason: "repo_overview_selected")
        abandonPendingRemoteConnection(reason: "repo_overview_selected")
        markAccessed(repo: repo)
        applyNavigationDestination(.repoOverview(repo))
    }

    @MainActor
    private func handleRepoTerminalSelection(_ repo: Repo) {
        handleRepoTerminalSelection(repo, preferredDirectory: nil)
    }

    @MainActor
    private func handleRepoTerminalSelection(_ repo: Repo, preferredDirectory: URL?) {
        let repoDirectory = repo.localURL.standardizedFileURL.resolvingSymlinksInPath()
        let launchDirectory = preferredSessionDirectory(
            preferredDirectory,
            inside: repoDirectory
        )

        terminalFocusCoordinator.cancelPendingFocusRequest(reason: "repo_terminal_selected")
        abandonPendingRemoteConnection(reason: "repo_terminal_selected")
        markAccessed(repo: repo)
        applyNavigationDestination(.repoTerminal(repo))
        let session = activateHostSession(
            key: .repoPath(repoDirectory.path),
            directory: launchDirectory
        )
        persistTerminalContinuity(
            targetKind: .repo,
            targetID: repo.id,
            rootURL: repoDirectory,
            launchURL: launchDirectory
        )
        terminalFocusCoordinator.beginRepoClickMeasurement(
            sessionID: session.id,
            repoPath: repoDirectory.path
        )
        terminalFocusCoordinator.requestMainTerminalFocus(
            targetSessionID: session.id,
            surfaceStore: hostTerminalState.surfaceStore,
            activeSessionID: hostTerminalState.activeSessionID,
            onTargetFocused: {
                terminalFocusCoordinator.completeRepoClickMeasurement(
                    sessionID: session.id,
                    outcome: "focused"
                )
            }
        )
    }

    @MainActor
    private func handleWorkspaceSelection(_ workspace: Workspace) {
        handleWorkspaceSelection(workspace, preferredDirectory: nil)
    }

    @MainActor
    private func handleWorkspaceSelection(_ workspace: Workspace, preferredDirectory: URL?) {
        terminalFocusCoordinator.cancelPendingRepoClickMeasurement(reason: "workspace_selected")
        terminalFocusCoordinator.cancelPendingFocusRequest(reason: "workspace_selected")

        if workspace.backend != .local {
            handleProviderBackedWorkspaceSelection(workspace)
        } else {
            abandonPendingRemoteConnection(reason: "local_workspace_selected")
            markAccessed(workspace: workspace)
            applyNavigationDestination(.workspaceTerminal(workspace))
            let workspaceDirectory = workspace.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
            let launchDirectory = preferredSessionDirectory(
                preferredDirectory,
                inside: workspaceDirectory
            )
            let session = activateHostSession(
                key: .hostPath(workspaceDirectory.path),
                directory: launchDirectory
            )
            persistTerminalContinuity(
                targetKind: .workspace,
                targetID: workspace.id,
                rootURL: workspaceDirectory,
                launchURL: launchDirectory
            )
            terminalFocusCoordinator.beginWorkspaceClickMeasurement(
                sessionID: session.id,
                workspacePath: workspaceDirectory.path
            )
            terminalFocusCoordinator.requestMainTerminalFocus(
                targetSessionID: session.id,
                surfaceStore: hostTerminalState.surfaceStore,
                activeSessionID: hostTerminalState.activeSessionID,
                onTargetFocused: {
                    terminalFocusCoordinator.completeWorkspaceClickMeasurement(
                        sessionID: session.id,
                        outcome: "focused"
                    )
                }
            )
        }

    }

    @MainActor
    private func handleProviderBackedWorkspaceSelection(_ workspace: Workspace) {
        guard let provider = workspaceProviderRegistry.provider(for: workspace) else {
            viewState.workspaceOperationErrorMessage =
                "No workspace provider is registered for '\(workspace.backendIdentifier)'."
            return
        }

        let providerTarget = WorkspaceProviderTarget(workspace)
        let sessionKey = provider.sessionKey(for: providerTarget)
        if workspace.status == .active,
            let existing = hostTerminalState.sessions.first(where: { $0.key == sessionKey })
        {
            abandonPendingRemoteConnection(reason: "remote_workspace_reused_existing_session")
            markAccessed(workspace: workspace)
            applyNavigationDestination(.workspaceTerminal(workspace))
            hostTerminalState.activateExistingSession(sessionID: existing.id)
            terminalFocusCoordinator.requestMainTerminalFocus(
                targetSessionID: existing.id,
                surfaceStore: hostTerminalState.surfaceStore,
                activeSessionID: hostTerminalState.activeSessionID
            )
            return
        }

        Task { @MainActor in
            do {
                try await workspaceProviderSetupActionRunner.run(
                    provider: provider,
                    action: .openTerminal(workspaceName: workspace.name)
                ) {
                    await connectToProviderBackedWorkspace(workspace, provider: provider)
                }
            } catch {
                viewState.workspaceOperationErrorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func connectToProviderBackedWorkspace(
        _ workspace: Workspace,
        provider: any WorkspaceProviderProtocol
    ) async {
        viewState.connectingWorkspaceID = workspace.id

        do {
            let launchSpec = try await provider.terminalLaunchSpec(for: WorkspaceProviderTarget(workspace))

            guard viewState.connectingWorkspaceID == workspace.id else { return }
            viewState.connectingWorkspaceID = nil
            workspace.status = launchSpec.statusAfterLaunch
            try? modelContext.save()
            let session = activateHostSession(
                key: launchSpec.sessionKey,
                directory: launchSpec.workingDirectory,
                customCommand: launchSpec.customCommand
            )
            viewState.columnVisibility = .all
            terminalFocusCoordinator.requestMainTerminalFocus(
                targetSessionID: session.id,
                surfaceStore: hostTerminalState.surfaceStore,
                activeSessionID: hostTerminalState.activeSessionID
            )
            NSLog(
                "[WorkspaceProvider] Session created for %@ workspace %@",
                workspace.backendIdentifier,
                workspace.name
            )
        } catch {
            NSLog(
                "[WorkspaceProvider] Failed to connect to %@ workspace %@: %@",
                workspace.backendIdentifier,
                workspace.name,
                error.localizedDescription
            )
            guard viewState.connectingWorkspaceID == workspace.id else { return }
            viewState.connectingWorkspaceID = nil
            viewState.workspaceOperationErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func handleWebSourceSelection(_ source: WebSource) {
        viewState.connectingWorkspaceID = nil
        terminalFocusCoordinator.cancelPendingRepoClickMeasurement(reason: "web_source_selected")
        terminalFocusCoordinator.cancelPendingFocusRequest(reason: "web_source_selected")
        abandonPendingRemoteConnection(reason: "web_source_selected")
        applyNavigationDestination(.webView(source))
        webSurfaceStore.cancelPendingRelease()
        markAccessed(webSource: source)
    }

    @MainActor
    private func handleWorkspaceCreated() {
        guard currentSelectedWorkspace == nil else { return }
        viewState.isRightPaneVisible = false
    }

    @MainActor
    private func createWorkspaceFromLanding(
        repo: Repo,
        name: String,
        nameSource: WorkspaceNameSource,
        providerID: String,
        guestOS: WorkspaceGuestOS?
    ) async {
        do {
            guard let provider = workspaceProviderRegistry.provider(for: providerID) else {
                landingErrorMessage = "Workspace provider '\(providerID)' is not registered."
                return
            }

            try await workspaceProviderSetupActionRunner.run(
                provider: provider,
                action: .createWorkspace(name: name, guestOS: guestOS)
            ) {
                do {
                    try await createWorkspaceFromLanding(
                        repo: repo,
                        name: name,
                        nameSource: nameSource,
                        providerID: providerID,
                        guestOS: guestOS,
                        skipSetup: true
                    )
                } catch {
                    landingErrorMessage = "Failed to create workspace: \(error.localizedDescription)"
                }
            } perform: {
                do {
                    try await createWorkspaceFromLanding(
                        repo: repo,
                        name: name,
                        nameSource: nameSource,
                        providerID: providerID,
                        guestOS: guestOS,
                        skipSetup: true
                    )
                } catch {
                    landingErrorMessage = "Failed to create workspace: \(error.localizedDescription)"
                }
            }
        } catch {
            landingErrorMessage = "Failed to create workspace: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func createWorkspaceFromLanding(
        repo: Repo,
        name: String,
        nameSource: WorkspaceNameSource,
        providerID: String,
        guestOS: WorkspaceGuestOS?,
        skipSetup: Bool
    ) async throws {
        creationLog.info(
            "createWorkspaceFromLanding: repo=\(repo.name) provider=\(providerID) skipSetup=\(skipSetup)"
        )
        let controller = SidebarWorkspaceController(
            modelContext: modelContext,
            workspaceService: workspaceService,
            workspaceProviderRegistry: workspaceProviderRegistry
        )
        let workspace = try await controller.createWorkspace(
            from: repo,
            name: name,
            nameSource: nameSource,
            providerID: providerID,
            guestOS: guestOS,
            progress: { _ in },
            onPersisted: nil
        )
        creationLog.info("createWorkspaceFromLanding: workspace created successfully")

        if skipSetup {
            abandonPendingRemoteConnection(reason: "workspace_created")
            handleWorkspaceSelection(workspace)
        }
    }

    @MainActor
    private func archiveWorkspaceFromLanding(_ workspace: Workspace) async {
        let controller = SidebarWorkspaceController(
            modelContext: modelContext,
            workspaceService: workspaceService,
            workspaceProviderRegistry: workspaceProviderRegistry
        )
        do {
            try await controller.archive(workspace)
        } catch {
            landingErrorMessage = "Failed to archive workspace: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func openWorkspaceInDefaultEditorFromLanding(_ workspace: Workspace) {
        do {
            try OpenInEditorShortcutFlow.perform(
                target: .project(rootURL: workspace.workspaceURL),
                editorID: nil,
                externalEditorService: externalEditorService,
                trigger: .uiPrimaryAction
            )
        } catch {
            presentOpenInEditorError(error)
        }
    }

    @MainActor
    private func addWebSource(
        rawURL: String,
        displayName: String,
        additionalAllowedDomainsRaw: String,
        target: WebSourceCreationTarget
    ) {
        do {
            let source = try WebSourceCreationSupport.makeSource(
                rawURL: rawURL,
                displayName: displayName,
                additionalAllowedDomainsRaw: additionalAllowedDomainsRaw,
                target: target,
                existingSources: webSources
            )

            modelContext.insert(source)
            try modelContext.save()
            handleWebSourceSelection(source)
        } catch {
            if let validationError = error as? WebSourceValidationError {
                landingErrorMessage = validationError.errorDescription
            } else {
                landingErrorMessage = error.localizedDescription
            }
            modelContext.rollback()
        }
    }

    @MainActor
    private func handleSelectedWebSourceRemoval(_ source: MainWindowWebSourceSelection) {
        if let lastSurface = MainWindowLastSurface.decode(from: lastSurfaceRawValue),
            lastSurface.kind == .webView,
            lastSurface.id == source.webSourceID
        {
            lastSurfaceRawValue = ""
        }

        viewState.didResolveInitialSurface = false
        if let surface = bootstrapController.fallbackSurfaceAfterRemovingWebSource(
            ownerWorkspaceID: source.ownerWorkspaceID,
            ownerRepoID: source.ownerRepoID,
            repos: repos
        ) {
            viewState.didResolveInitialSurface = true
            applyLaunchSurface(surface)
        }
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
                hostTerminalState: hostTerminalState,
                defaultHomeDirectory: resolvedDefaultHostDirectory,
                repos: repos,
                normalizePath: normalizePath
            )
        else { return }
        applyTerminalSessionResult(result)
    }

    @MainActor
    private func applyTerminalSessionResult(
        _ result: MainWindowTerminalSessionController.SessionFocusResult
    ) {
        setSelectedWorkspace(result.syncedWorkspace)
        focusTerminalTab(result.focusSessionID)
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
                hostTerminalState: hostTerminalState,
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
                hostTerminalState: hostTerminalState,
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
                hostTerminalState: hostTerminalState,
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
                hostTerminalState: hostTerminalState,
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
    private func requestCloseTerminalTabs(_ sessionIDs: [UUID]) {
        let results = terminalSessionController.closeTabs(
            sessionIDs,
            hostTerminalState: hostTerminalState,
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
            hostTerminalState: hostTerminalState
        )
    }

    @MainActor
    private func forceCloseTerminalTab(sessionID: UUID) {
        guard
            let result = terminalSessionController.forceCloseTab(
                sessionID: sessionID,
                hostTerminalState: hostTerminalState,
                defaultHomeDirectory: resolvedDefaultHostDirectory,
                repos: repos,
                normalizePath: normalizePath
            )
        else { return }
        applyTerminalSessionResult(result)
    }

    @MainActor
    private func requestTerminalClose(sessionID: UUID) -> Bool {
        guard let terminal = hostTerminalState.surfaceStore.terminal(for: sessionID) else {
            return false
        }
        terminal.requestClose()
        return true
    }

    @MainActor
    private func focusTerminalTab(_ sessionID: UUID) {
        terminalFocusCoordinator.requestMainTerminalFocus(
            targetSessionID: sessionID,
            activateApp: false,
            surfaceStore: hostTerminalState.surfaceStore,
            activeSessionID: hostTerminalState.activeSessionID
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
    }

    @MainActor
    private func syncWorkspaceStatuses(trigger: String) async {
        let syncStartedAt = Date()
        let nonLocalWorkspaces = repos.flatMap(\.workspaces).filter {
            $0.backend != .local && $0.remoteId != nil
        }
        guard !nonLocalWorkspaces.isEmpty else { return }

        var changed = false
        var changedCount = 0
        var hadFailure = false
        let groupedWorkspaces = Dictionary(grouping: nonLocalWorkspaces, by: \.backendIdentifier)

        for (providerID, providerWorkspaces) in groupedWorkspaces {
            guard let provider = workspaceProviderRegistry.provider(for: providerID) else { continue }

            let providerSyncStartedAt = Date()
            var providerChangedCount = 0
            var outcome = "success"

            do {
                let snapshots = try await provider.syncStatuses(
                    for: providerWorkspaces.map(WorkspaceProviderTarget.init)
                )
                let statusesByRemoteID = Dictionary(
                    uniqueKeysWithValues: snapshots.map { ($0.remoteId, $0.status) }
                )

                for workspace in providerWorkspaces {
                    guard let remoteID = workspace.remoteId else { continue }
                    let newStatus = statusesByRemoteID[remoteID] ?? .archived
                    if workspace.status != newStatus {
                        NSLog(
                            "[WorkspaceProvider] Syncing workspace '%@' (%@): %@ -> %@",
                            workspace.name,
                            providerID,
                            workspace.status.rawValue,
                            newStatus.rawValue
                        )
                        workspace.status = newStatus
                        changed = true
                        changedCount += 1
                        providerChangedCount += 1
                    }
                }
            } catch {
                outcome = "failure"
                hadFailure = true
                NSLog(
                    "[WorkspaceProvider] Failed to sync %@ workspace statuses: %@",
                    providerID,
                    error.localizedDescription
                )
            }

            NSLog(
                "[Perf] metric=workspace_status_sync_provider duration_ms=%.2f trigger=%@ provider=%@ workspace_count=%ld changed_count=%ld outcome=%@",
                Date().timeIntervalSince(providerSyncStartedAt) * 1000,
                trigger,
                providerID,
                providerWorkspaces.count,
                providerChangedCount,
                outcome
            )
        }

        if changed {
            try? modelContext.save()
        }

        NSLog(
            "[Perf] metric=workspace_status_sync duration_ms=%.2f trigger=%@ providers=%ld workspace_count=%ld changed_count=%ld outcome=%@",
            Date().timeIntervalSince(syncStartedAt) * 1000,
            trigger,
            groupedWorkspaces.count,
            nonLocalWorkspaces.count,
            changedCount,
            hadFailure ? "partial_failure" : "success"
        )
    }

    @MainActor
    private func openDesktop(for workspace: Workspace) {
        guard let provider = workspaceProviderRegistry.provider(for: workspace) else {
            viewState.workspaceOperationErrorMessage =
                "No workspace provider is registered for '\(workspace.backendIdentifier)'."
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
                viewState.workspaceOperationErrorMessage = error.localizedDescription
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
            viewState.workspaceOperationErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func ensureInitialHostSession() {
        if !hostTerminalState.hasSessions,
            let snapshot = TerminalContinuityManifest.decode(from: terminalContinuityManifestRawValue)?
                .hostSessionSnapshot()
        {
            hostTerminalState.restoreSessions(
                snapshot.sessions,
                activeSessionID: snapshot.activeSessionID,
                activeSessionIDByScopeKey: snapshot.activeSessionIDByScopeKey
            )
            return
        }

        terminalSessionController.ensureInitialHostSession(
            hostTerminalState: hostTerminalState,
            defaultHomeDirectory: resolvedDefaultHostDirectory,
            activateHostSession: { key, directory, customCommand in
                activateHostSession(key: key, directory: directory, customCommand: customCommand)
            }
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
        viewState.selectedCodePreview = selection
        viewState.isTerminalPanelVisible = true
    }

    @MainActor
    private func openSelectedWebSourceInBrowser() {
        guard let selectedWebSource = currentSelectedWebSource else { return }
        let webView = webSurfaceStore.ensureSurface(for: selectedWebSource)
        if let currentURL = webView.url {
            NSWorkspace.shared.open(currentURL)
        } else if let baseURL = selectedWebSource.baseURL {
            NSWorkspace.shared.open(baseURL)
        }
    }

    @MainActor
    private func reloadSelectedWebSource() {
        guard let selectedWebSource = currentSelectedWebSource else { return }
        let webView = webSurfaceStore.ensureSurface(for: selectedWebSource)
        if let currentURL = webView.url {
            webView.load(URLRequest(url: currentURL))
        } else if let baseURL = selectedWebSource.baseURL {
            webView.load(URLRequest(url: baseURL))
        }
    }

    private func clearCodePreview() {
        viewState.selectedCodePreview = nil
        viewState.isTerminalPanelVisible = true
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

    private func persistTerminalContinuity(
        targetKind: TerminalContinuityManifest.TargetKind,
        targetID: UUID,
        rootURL: URL,
        launchURL: URL
    ) {
        let manifest = TerminalContinuityManifest(
            targetKind: targetKind,
            targetID: targetID,
            rootURL: rootURL,
            launchURL: launchURL,
            terminalMode: terminalMultiplexingMode,
            sessions: hostTerminalState.sessions,
            activeSessionID: hostTerminalState.activeSessionID,
            activeSessionIDByScopeKey: hostTerminalState.activeSessionIDByScopeKey
        )
        terminalContinuityManifestRawValue = manifest.rawValue
        NSLog(
            "[TerminalContinuity] persisted kind=%@ id=%@ root=%@ launch=%@ tmux_session=%@ mode=%@",
            targetKind.rawValue,
            targetID.uuidString,
            manifest.rootPath,
            manifest.launchPath,
            manifest.tmuxSessionName,
            manifest.terminalMode.rawValue
        )
    }

    private func persistTerminalContinuitySnapshot() {
        let manifest = TerminalContinuityManifest.snapshot(
            previous: TerminalContinuityManifest.decode(from: terminalContinuityManifestRawValue),
            defaultHomeURL: resolvedDefaultHostDirectory,
            terminalMode: terminalMultiplexingMode,
            sessions: hostTerminalState.sessions,
            activeSessionID: hostTerminalState.activeSessionID,
            activeSessionIDByScopeKey: hostTerminalState.activeSessionIDByScopeKey
        )
        terminalContinuityManifestRawValue = manifest.rawValue
    }

    private func restoredLaunchDirectory(for repo: Repo) -> URL? {
        let repoDirectory = repo.localURL.standardizedFileURL.resolvingSymlinksInPath()
        return TerminalContinuityManifest.decode(from: terminalContinuityManifestRawValue)?
            .launchDirectory(
                for: .repo,
                targetID: repo.id,
                rootURL: repoDirectory
            )
    }

    private func restoredLaunchDirectory(for workspace: Workspace) -> URL? {
        guard workspace.backend == .local else { return nil }
        let workspaceDirectory = workspace.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        return TerminalContinuityManifest.decode(from: terminalContinuityManifestRawValue)?
            .launchDirectory(
                for: .workspace,
                targetID: workspace.id,
                rootURL: workspaceDirectory
            )
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
        if let externalEditorError = error as? ExternalEditorError {
            viewState.openInEditorErrorMessage =
                externalEditorError.errorDescription ?? "Could not open the selected file."
        } else {
            viewState.openInEditorErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func pruneRightPaneState() {
        inspectorStateController.pruneRightPaneState(store: rightPaneStateStore, repos: repos)
    }

    @discardableResult
    @MainActor
    private func activateHostSession(
        key: HostTerminalSessionKey, directory: URL, customCommand: String? = nil
    ) -> HostTerminalSession {
        let result = hostTerminalState.activateSession(
            key: key,
            directory: directory,
            customCommand: customCommand
        )
        if result.created {
            NSLog(
                "[HostSession] Created session %@ key=%@ path=%@ (total sessions=%ld)",
                result.session.id.uuidString,
                key.debugDescription,
                result.session.directoryPath,
                hostTerminalState.sessions.count
            )
        } else {
            NSLog(
                "[HostSession] Reusing session %@ key=%@ path=%@",
                result.session.id.uuidString,
                key.debugDescription,
                result.session.directoryPath
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

    private func preferredSessionDirectory(_ preferredDirectory: URL?, inside root: URL) -> URL {
        guard let preferredDirectory else { return root }

        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedPreferred = preferredDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard path(normalizedPreferred.path, isInside: normalizedRoot.path) else {
            return normalizedRoot
        }

        var isDirectory = ObjCBool(false)
        guard
            FileManager.default.fileExists(atPath: normalizedPreferred.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return normalizedRoot
        }

        return normalizedPreferred
    }

    private func path(_ path: String, isInside root: String) -> Bool {
        if path == root { return true }
        guard root != "/" else { return true }
        return path.hasPrefix(root + "/")
    }

    private func normalizePath(_ rawPath: String) -> String {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func refreshWorkspaceStatusAggregator() {
        let presentation = SidebarWorkspacePresentationController()
        let statuses = agentSessionRegistry.statuses
        let sessions = hostTerminalState.sessions
        let normalize: (URL) -> String = { url in normalizePath(url.path) }

        let workspaceInputs: [WorkspaceStatusAggregator.WorkspaceInput] =
            repos
            .flatMap(\.workspaces)
            .map { workspace in
                let key = presentation.sessionKey(
                    for: workspace,
                    registry: workspaceProviderRegistry,
                    normalizePath: normalize
                )
                let status = presentation.freshestAgentStatus(
                    for: key,
                    sessions: sessions,
                    agentStatusBySessionID: statuses
                )
                return WorkspaceStatusAggregator.WorkspaceInput(
                    workspaceID: workspace.id,
                    repoID: workspace.sourceRepo?.id,
                    lastAccessedAt: workspace.lastAccessedAt,
                    status: status
                )
            }

        let repoInputs: [WorkspaceStatusAggregator.RepoInput] = repos.map { repo in
            let key = HostTerminalSessionKey.repoPath(normalize(repo.localURL))
            let status = presentation.freshestAgentStatus(
                for: key,
                sessions: sessions,
                agentStatusBySessionID: statuses
            )
            return WorkspaceStatusAggregator.RepoInput(
                repoID: repo.id,
                lastAccessedAt: repo.lastAccessedAt,
                status: status
            )
        }

        workspaceStatusAggregator.update(workspaces: workspaceInputs, repos: repoInputs)
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

// MARK: - Main Terminal (Host-pinned)

struct MainTerminalDetailView: View {
    let selectedWorkspace: Workspace?
    let selectedRepo: Repo?
    let activeHostSession: HostTerminalSession?
    let hostTerminalSessions: [HostTerminalSession]
    let visibleHostTerminalSessions: [HostTerminalSession]
    let activeHostTerminalSessionID: UUID?
    let activeSplitHostSession: HostTerminalSession?
    let activeSplitLayout: HostTerminalStateStore.SplitPaneLayout?
    let activeSplitFraction: CGFloat?
    let hostSurfaceStore: HostTerminalSurfaceStore
    let tabTitleOverrides: [UUID: String]
    let agentStatuses: [AgentSessionStatus]
    let terminalContextMenuProvider: (HostTerminalSession) -> NSMenu?
    let onSplitFractionChanged: (CGFloat) -> Void
    let onOpenRepoOverview: (Repo) -> Void
    var onSelectTerminalTab: ((UUID) -> Void)?
    var onCloseTerminalTab: ((UUID) -> Void)?
    var onTerminalCloseConfirmationRequired: ((UUID) -> Void)?
    var onTerminalProcessExit: ((UUID) -> Void)?
    @Binding var selectedCodePreview: CodePreviewSelection?
    @Binding var isTerminalPanelVisible: Bool
    let onFileSelected: (CodePreviewSelection) -> Void
    let availableEditors: [ExternalEditorDescriptor]
    let defaultEditor: ExternalEditorDescriptor?
    let onOpenInDefaultEditor: () -> Void
    let onOpenInEditor: (ExternalEditorID) -> Void
    let rightPaneStateStore: RightPaneStateStore
    @Binding var isRightPaneVisible: Bool

    var body: some View {
        HSplitView {
            previewAndTerminalPanel
                .frame(minWidth: 400)

            // Collapsible right pane
            if isRightPaneVisible {
                if let selectedWorkspace {
                    let state = rightPaneStateStore.state(for: selectedWorkspace)
                    RightPaneView(
                        workspace: selectedWorkspace,
                        state: state,
                        diagnosticWorkspaceDirectories: diagnosticWorkspaceDirectories,
                        agentStatuses: agentStatuses,
                        onFileSelected: onFileSelected
                    )
                    .rightPaneWidth(for: state)
                } else if let selectedRepo {
                    let state = rightPaneStateStore.state(for: selectedRepo)
                    RightPaneView(
                        repo: selectedRepo,
                        state: state,
                        diagnosticWorkspaceDirectories: diagnosticWorkspaceDirectories,
                        agentStatuses: agentStatuses,
                        onFileSelected: onFileSelected
                    )
                    .rightPaneWidth(for: state)
                }
            }
        }
        .navigationTitle(navigationTitle)
    }

    private var diagnosticWorkspaceDirectories: [URL] {
        var seen = Set<String>()
        var directories: [URL] = []

        var candidateDirectories = hostTerminalSessions.map(\.directoryURL)
        if let activeSplitHostSession {
            candidateDirectories.append(activeSplitHostSession.directoryURL)
        }
        if let selectedWorkspaceDirectory = selectedWorkspace?.localDirectoryURL {
            candidateDirectories.append(selectedWorkspaceDirectory)
        }
        if let selectedRepo {
            candidateDirectories.append(selectedRepo.localURL)
        }

        for directory in candidateDirectories {
            let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
            if seen.insert(path).inserted {
                directories.append(URL(fileURLWithPath: path, isDirectory: true))
            }
        }

        return directories
    }

    @ViewBuilder
    private var previewAndTerminalPanel: some View {
        VStack(spacing: 0) {
            repoTerminalBreadcrumb
            previewAndTerminalPanelContent
        }
    }

    @ViewBuilder
    private var previewAndTerminalPanelContent: some View {
        if let selectedCodePreview {
            if isTerminalPanelVisible {
                VSplitView {
                    CodeFilePreviewView(
                        selection: selectedCodePreview,
                        editorOptions: availableEditors,
                        defaultEditor: defaultEditor,
                        onOpenInDefaultEditor: onOpenInDefaultEditor,
                        onOpenInEditor: onOpenInEditor
                    ) {
                        self.selectedCodePreview = nil
                        self.isTerminalPanelVisible = true
                    }
                    .frame(minHeight: 220)

                    hostTerminalPanel
                        .frame(minHeight: 160)
                }
            } else {
                CodeFilePreviewView(
                    selection: selectedCodePreview,
                    editorOptions: availableEditors,
                    defaultEditor: defaultEditor,
                    onOpenInDefaultEditor: onOpenInDefaultEditor,
                    onOpenInEditor: onOpenInEditor
                ) {
                    self.selectedCodePreview = nil
                    self.isTerminalPanelVisible = true
                }
            }
        } else {
            hostTerminalPanel
        }
    }

    @ViewBuilder
    private var repoTerminalBreadcrumb: some View {
        if selectedWorkspace == nil, let selectedRepo {
            HStack(spacing: 8) {
                Button {
                    onOpenRepoOverview(selectedRepo)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "folder")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(selectedRepo.name)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text(selectedRepo.localPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Repo Overview")

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }

    private var hostTerminalPanel: some View {
        HostTerminalSessionStack(
            sessions: visibleHostTerminalSessions,
            activeSessionID: activeHostTerminalSessionID,
            splitSession: activeSplitHostSession,
            splitLayout: activeSplitLayout,
            splitFraction: activeSplitFraction,
            surfaceStore: hostSurfaceStore,
            tabTitleOverrides: tabTitleOverrides,
            onSplitFractionChanged: onSplitFractionChanged,
            onSelectTab: onSelectTerminalTab,
            onCloseTab: onCloseTerminalTab,
            onCloseConfirmationRequired: onTerminalCloseConfirmationRequired,
            onTerminalProcessExit: onTerminalProcessExit,
            contextMenuProvider: terminalContextMenuProvider
        )
    }

    private var navigationTitle: String {
        if let selectedWorkspace {
            return selectedWorkspace.name
        }

        if let selectedRepo {
            return selectedRepo.name
        }

        guard let activeHostSession else { return "WorkSpaces" }

        switch activeHostSession.key {
        case .defaultHome:
            return "WorkSpaces"
        case .repoPath, .hostPath:
            return activeHostSession.directoryURL.lastPathComponent
        case .backendSession(_, let instanceID):
            return selectedWorkspace?.name ?? "Workspace \(instanceID)"
        }
    }
}

struct WorkspaceConnectingOverlay: View {
    let workspaceName: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Connecting to \(workspaceName ?? "workspace")...")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

#Preview {
    ContentViewPreviewHost()
        .modelContainer(for: [Repo.self, Workspace.self, WebSource.self], inMemory: true)
}

private struct ContentViewPreviewHost: View {
    @State private var deepLinkState = WorkspaceDeepLinkState()
    @State private var lastSurfaceRawValue = ""
    @StateObject private var appCommandState = AppCommandState()
    @StateObject private var hostTerminalState = HostTerminalStateStore()
    @StateObject private var workspaceProviderSetupCoordinator = WorkspaceProviderSetupCoordinator()
    @StateObject private var hostLumeSmokeAutomation = HostLumeSmokeAutomationController(
        environment: [:]
    )

    var body: some View {
        ContentView(
            deepLinkState: $deepLinkState,
            lastSurfaceRawValue: $lastSurfaceRawValue,
            appCommandState: appCommandState,
            hostTerminalState: hostTerminalState,
            workspaceProviderSetupCoordinator: workspaceProviderSetupCoordinator,
            hostLumeSmokeAutomation: hostLumeSmokeAutomation
        )
    }
}
