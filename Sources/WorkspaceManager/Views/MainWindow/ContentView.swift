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

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var deepLinkState: WorkspaceDeepLinkState
    @Binding var lastSurfaceRawValue: String
    @ObservedObject var hostTerminalState: HostTerminalStateStore
    @Query(sort: \Repo.addedAt, order: .reverse) private var repos: [Repo]
    @Query(sort: \WebSource.addedAt, order: .reverse) private var webSources: [WebSource]
    @AppStorage(TerminalMultiplexingMode.storageKey)
    private var terminalMultiplexingModeRawValue: String = TerminalMultiplexingMode.defaultValue.rawValue
    @AppStorage(NotificationConstants.enabledKey)
    private var notificationsEnabled = NotificationConstants.defaultEnabled
    @Environment(\.externalEditorService) private var externalEditorService
    @Environment(\.remoteBackend) private var remoteBackend
    @Environment(\.workspaceService) private var workspaceService
    @ObservedObject private var notificationCoordinator = NotificationCoordinator.shared

    @State private var viewState = MainWindowViewState()
    @State private var repoForNewWorkspaceFromLanding: Repo?
    @State private var webSourceCreationTarget: WebSourceCreationTarget?
    @State private var landingErrorMessage: String?
    @State private var isRemoteBackendAvailableForLanding = false
    @StateObject private var rightPaneStateStore = RightPaneStateStore()
    @StateObject private var webSurfaceStore = WebSurfaceStore()
    @StateObject private var terminalFocusCoordinator = TerminalFocusCoordinator()
    private let buildIdentity = AppBuildIdentity.current
    private let resolvedDefaultHostDirectory = HostTerminalDefaults.defaultWorkingDirectory()
        .standardizedFileURL
        .resolvingSymlinksInPath()
    private let bootstrapController = MainWindowBootstrapController()
    private let inspectorStateController = InspectorStateController()
    private let mainSelectionCoordinator = MainSelectionCoordinator()
    private let navigationStateController = MainWindowNavigationStateController()
    private let remoteWorkspaceStateController = MainWindowRemoteWorkspaceStateController()
    private let surfaceResolutionController = MainWindowSurfaceResolutionController()
    private let presentationController = MainWindowPresentationController()
    private let splitRoutingController = SplitRoutingController()

    private var launchRepositoryService: LaunchRepositoryService {
        LaunchRepositoryService(modelContext: modelContext)
    }

    private var sessionPresentation: HostTerminalSessionPresentation {
        hostTerminalState.sessionPresentation
    }

    private var terminalMultiplexingMode: TerminalMultiplexingMode {
        TerminalMultiplexingMode(rawValue: terminalMultiplexingModeRawValue) ?? .defaultValue
    }

    private var activeHostSession: HostTerminalSession? {
        presentationController.activeHostSession(
            activeSessionID: hostTerminalState.activeSessionID,
            sessions: hostTerminalState.sessions
        )
    }

    private var currentSelectedWorkspace: Workspace? {
        mainSelectionCoordinator.workspace(with: viewState.selectedWorkspace?.workspaceID, in: repos)
    }

    private var currentSelectedWebSource: WebSource? {
        mainSelectionCoordinator.webSource(with: viewState.selectedWebSource?.webSourceID, in: webSources)
    }

    private var currentSelectedRepoForLanding: Repo? {
        mainSelectionCoordinator.repo(with: viewState.selectedRepoForLandingID, in: repos)
    }

    private var normalizedRepoPathSnapshot: [String] {
        repos.map { normalizePath($0.localPath) }
    }

    private var repoIDSnapshot: [UUID] {
        repos.map(\.id)
    }

    private var workspaceIDSnapshot: [UUID] {
        repos.flatMap(\.workspaces).map(\.id)
    }

    private var webSourceIDSnapshot: [UUID] {
        webSources.map(\.id)
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
            activeHostTerminalSessionID: hostTerminalState.activeSessionID,
            activeSplitHostSession: hostTerminalState.splitSession(for: hostTerminalState.activeSessionID),
            activeSplitLayout: hostTerminalState.splitLayout(for: hostTerminalState.activeSessionID),
            activeSplitFraction: hostTerminalState.splitFraction(for: hostTerminalState.activeSessionID),
            hostSurfaceStore: hostTerminalState.surfaceStore,
            terminalContextMenuProvider: terminalContextMenu(for:),
            onSplitFractionChanged: { nextFraction in
                guard let activeSessionID = hostTerminalState.activeSessionID else { return }
                _ = hostTerminalState.updateSplitFraction(
                    nextFraction,
                    forPrimarySessionID: activeSessionID
                )
            },
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
                    repoForNewWorkspaceFromLanding = repo
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
            terminalDetailContent
        }
    }

    private var baseSplitView: some View {
        NavigationSplitView(columnVisibility: $viewState.columnVisibility) {
            SidebarView(
                repos: repos,
                webSources: webSources,
                selectedRepo: selectedRepoForSidebar,
                selectedWorkspace: selectedWorkspaceBinding,
                selectedWebSource: selectedWebSourceBinding,
                paneCountBySessionKey: paneCountBySessionKeyForSidebar,
                activeSessionKey: activeSessionKeyForSidebar,
                connectingSandboxId: viewState.connectingSandboxId,
                onRepoSelected: handleRepoSelection,
                onRepoTerminalSelected: handleRepoTerminalSelection,
                onWebSourceSelected: handleWebSourceSelection,
                onRequestWebSourceCreation: { target in
                    webSourceCreationTarget = target
                },
                onWorkspaceCreated: handleWorkspaceCreated
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 350)
        } detail: {
            ZStack {
                detailContent
                if viewState.connectingSandboxId != nil {
                    SandboxConnectingOverlay(workspaceName: viewState.pendingRemoteWorkspace?.workspaceName)
                }
            }
        }
    }

    private var splitViewWithToolbar: some View {
        baseSplitView
            .toolbar {
                ToolbarItem(placement: .principal) {
                    AppBuildIdentityBadge(identity: buildIdentity)
                }

                ToolbarItemGroup(placement: .automatic) {
                    if let selectedWebSource = currentSelectedWebSource {
                        Button {
                            openSelectedWebSourceInBrowser()
                        } label: {
                            Image(systemName: "safari")
                        }
                        .help("Open in Browser")
                        .disabled(selectedWebSource.baseURL == nil)

                        Button {
                            reloadSelectedWebSource()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Reload")
                        .disabled(selectedWebSource.baseURL == nil)
                    } else if let defaultEditor = defaultEditorDescriptor,
                        let workspace = currentSelectedWorkspace
                    {
                        WorkspaceEditorToolbarButton(
                            workspaceName: workspace.name,
                            editorOptions: availableEditors,
                            defaultEditor: defaultEditor,
                            onOpenInDefaultEditor: openInDefaultEditor,
                            onOpenInEditor: openInSelectedEditor,
                            onRevealInFinder: revealInFinder,
                            onCopyPath: copyWorkspacePath
                        )
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
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

    private var splitViewWithLifecycleHandlers: some View {
        splitViewWithToolbar
            .onAppear {
                ensureInitialHostSession()
                resolveSurfaceLifecycle()
                pruneRightPaneState()
                syncOpenInEditorShortcutRouting()
                notificationCoordinator.loadStoredAuth()
            }
            .task {
                isRemoteBackendAvailableForLanding = await remoteBackend.isAvailable()
                await syncCloudWorkspaceStatuses()
            }
            .onDisappear {
                ShortcutRoutingPolicy.shared.setOverride(nil, for: AppChromeShortcut.openInEditor.chord)
            }
            .onChange(of: deepLinkState.pendingRequest) { _, _ in
                resolveSurfaceLifecycle()
            }
            .onChange(of: repoIDSnapshot) { _, _ in
                reconcileSelectionAfterModelChange()
                resolveSurfaceLifecycle()
            }
            .onChange(of: workspaceIDSnapshot) { _, _ in
                reconcileSelectionAfterModelChange()
                resolveSurfaceLifecycle()
            }
            .onChange(of: normalizedRepoPathSnapshot) { _, paths in
                hostTerminalState.pruneRepoSessions(validRepoPaths: Set(paths))
            }
            .onChange(of: webSourceIDSnapshot) { _, _ in
                reconcileSelectionAfterModelChange()
                resolveSurfaceLifecycle()
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
    }

    private var splitViewWithFocusAndAlerts: some View {
        splitViewWithLifecycleHandlers
            .focusedSceneValue(\.toggleSidebarAction, toggleSidebarVisibility)
            .focusedSceneValue(\.toggleInspectorAction, toggleInspectorVisibility)
            .focusedSceneValue(\.toggleTerminalPanelAction, toggleTerminalPanelVisibility)
            .focusedSceneValue(\.openInEditorAction, openInEditorFocusedAction)
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
                "Could Not Connect to Sandbox",
                isPresented: Binding(
                    get: { viewState.remoteErrorMessage != nil },
                    set: { if !$0 { viewState.remoteErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { viewState.remoteErrorMessage = nil }
            } message: {
                Text(viewState.remoteErrorMessage ?? "Unknown error.")
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
            .sheet(item: $repoForNewWorkspaceFromLanding) { repo in
                NewWorkspaceSheet(
                    repo: repo,
                    isRemoteBackendAvailable: isRemoteBackendAvailableForLanding,
                    isCreateDisabled: false
                ) { name, backend in
                    Task { @MainActor in
                        await createWorkspaceFromLanding(repo: repo, name: name, backend: backend)
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
        guard viewState.connectingSandboxId != nil || viewState.pendingRemoteWorkspace != nil else {
            return
        }

        NSLog("[RemoteBackend] Discarding pending sandbox connection (%@)", reason)
        viewState.connectingSandboxId = nil
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
    @discardableResult
    private func applySurfaceResolutionAction(_ action: MainWindowSurfaceResolutionAction) -> Bool {
        switch action {
        case .none, .waitForRepos:
            return false

        case .clearDeepLinkNoMatch(let request):
            NSLog("[DeepLink] No workspace match for cwd: %@", request.cwd)
            deepLinkState.clearPendingRequest()
            return true

        case .selectDeepLinkedWorkspace(let request, let workspace):
            NSLog(
                "[DeepLink] Matched workspace '%@' for cwd '%@' (session_id=%@ source=%@)",
                workspace.name,
                request.cwd,
                request.sessionID ?? "",
                request.source ?? ""
            )

            abandonPendingRemoteConnection(reason: "deep_link_selected")
            handleWorkspaceSelection(
                workspace,
                preferredDirectory: URL(fileURLWithPath: request.cwd, isDirectory: true)
            )
            deepLinkState.clearPendingRequest()
            viewState.didResolveInitialSurface = true
            focusWorkspaceWindow()
            return false

        case .selectDeepLinkedRepo(let request, let repo):
            NSLog(
                "[DeepLink] Matched repo '%@' for cwd '%@' (session_id=%@ source=%@)",
                repo.name,
                request.cwd,
                request.sessionID ?? "",
                request.source ?? ""
            )

            abandonPendingRemoteConnection(reason: "deep_link_selected")
            handleRepoTerminalSelection(
                repo,
                preferredDirectory: URL(fileURLWithPath: request.cwd, isDirectory: true)
            )
            deepLinkState.clearPendingRequest()
            viewState.didResolveInitialSurface = true
            focusWorkspaceWindow()
            return false

        case .importDeepLinkedRepo(let request, let repoRoot):
            guard let repo = launchRepositoryService.existingOrImportedRepo(at: repoRoot) else {
                NSLog("[DeepLink] Failed to import repo for cwd '%@' repo_root='%@'", request.cwd, repoRoot)
                deepLinkState.clearPendingRequest()
                return true
            }

            NSLog(
                "[DeepLink] Imported repo '%@' for cwd '%@' (repo_root=%@)",
                repo.name,
                request.cwd,
                repoRoot
            )

            abandonPendingRemoteConnection(reason: "deep_link_repo_imported")
            handleRepoTerminalSelection(
                repo,
                preferredDirectory: URL(fileURLWithPath: request.cwd, isDirectory: true)
            )
            deepLinkState.clearPendingRequest()
            viewState.didResolveInitialSurface = true
            focusWorkspaceWindow()
            return false

        case .perfAutoSelect(let repo):
            viewState.didRunPerfAutoSelection = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Task { @MainActor in
                    viewState.didResolveInitialSurface = true
                    handleRepoTerminalSelection(repo)
                }
            }
            return false

        case .recordMissingPreviewBootstrap(let configuration):
            viewState.didApplyFixturePreviewBootstrap = true
            NSLog(
                "[UIFixture] Preview bootstrap skipped (repo=%@ path=%@)",
                configuration.repoName,
                configuration.relativePath
            )
            return true

        case .applyPreviewBootstrap(_, let repo, let selection):
            viewState.didApplyFixturePreviewBootstrap = true
            viewState.didResolveInitialSurface = true
            handleRepoTerminalSelection(repo)
            viewState.selectedCodePreview = selection
            viewState.isTerminalPanelVisible = true
            viewState.isRightPaneVisible = true

            NSLog(
                "[UIFixture] Preview bootstrap applied (repo=%@ file=%@)",
                repo.name,
                selection.relativePath
            )
            return false

        case .recordMissingWebBootstrap(let targetName):
            viewState.didApplyFixtureWebBootstrap = true
            NSLog("[UIFixture] Web bootstrap skipped (target=%@)", targetName)
            return true

        case .applyWebBootstrap(let targetName, let selectedSource):
            viewState.didApplyFixtureWebBootstrap = true
            viewState.didResolveInitialSurface = true
            handleWebSourceSelection(selectedSource)
            NSLog(
                "[UIFixture] Web bootstrap applied (target=%@ selected=%@)",
                targetName,
                selectedSource.name
            )
            return false

        case .clearInvalidLastSurface:
            lastSurfaceRawValue = ""
            return true

        case .restore(let surface):
            viewState.didResolveInitialSurface = true
            applyLaunchSurface(surface)
            return false

        case .fallback(let surface):
            viewState.didResolveInitialSurface = true
            applyLaunchSurface(surface)
            return false
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
            handleRepoTerminalSelection(repo)
        case .workspace(let workspace):
            handleWorkspaceSelection(workspace)
        case .webView(let source):
            handleWebSourceSelection(source)
        }
    }

    @MainActor
    private func handleRepoSelection(_ repo: Repo) {
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

        abandonPendingRemoteConnection(reason: "repo_terminal_selected")
        markAccessed(repo: repo)
        applyNavigationDestination(.repoTerminal(repo))
        let session = activateHostSession(
            key: .repoPath(repoDirectory.path),
            directory: launchDirectory
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Task { @MainActor in
                terminalFocusCoordinator.requestMainTerminalFocus(
                    targetSessionID: session.id,
                    surfaceStore: hostTerminalState.surfaceStore,
                    activeSessionID: hostTerminalState.activeSessionID,
                    onTargetFocused: {
                        terminalFocusCoordinator.completeRepoClickMeasurement(
                            sessionID: session.id,
                            outcome: "focused_retry"
                        )
                    }
                )
            }
        }
    }

    @MainActor
    private func handleWorkspaceSelection(_ workspace: Workspace) {
        handleWorkspaceSelection(workspace, preferredDirectory: nil)
    }

    @MainActor
    private func handleWorkspaceSelection(_ workspace: Workspace, preferredDirectory: URL?) {
        terminalFocusCoordinator.cancelPendingRepoClickMeasurement(reason: "workspace_selected")

        if workspace.isRemote, let sandboxId = workspace.remoteId {
            handleRemoteWorkspaceSelection(workspace, sandboxId: sandboxId)
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
            terminalFocusCoordinator.requestMainTerminalFocus(
                targetSessionID: session.id,
                surfaceStore: hostTerminalState.surfaceStore,
                activeSessionID: hostTerminalState.activeSessionID
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Task { @MainActor in
                    terminalFocusCoordinator.requestMainTerminalFocus(
                        targetSessionID: session.id,
                        surfaceStore: hostTerminalState.surfaceStore,
                        activeSessionID: hostTerminalState.activeSessionID
                    )
                }
            }
        }

    }

    @MainActor
    private func handleRemoteWorkspaceSelection(_ workspace: Workspace, sandboxId: String) {
        let sessionKey = HostTerminalSessionKey.remoteSandbox(sandboxId)
        let placeholderDir = FileManager.default.temporaryDirectory

        // Reuse existing session for this specific sandbox
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

        switch remoteWorkspaceStateController.selectionDecision(
            for: workspace,
            connectingSandboxID: viewState.connectingSandboxId
        ) {
        case .ignoreInFlightConnection(let existingSandboxID):
            NSLog(
                "[RemoteBackend] Ignoring selection — already connecting to %@",
                existingSandboxID
            )
            return
        case .beginConnection(let pendingSelection):
            viewState.connectingSandboxId = sandboxId
            viewState.pendingRemoteWorkspace = pendingSelection
        }

        let backend = remoteBackend
        let needsStart = workspace.status == .stopped || workspace.status == .archived

        Task {
            do {
                let info: RemoteSandboxInfo
                if needsStart {
                    NSLog("[RemoteBackend] Starting sandbox %@ (was %@)", sandboxId, workspace.status.rawValue)
                    info = try await backend.startSandbox(sandboxId: sandboxId)
                    await MainActor.run {
                        workspace.status = .active
                    }
                } else {
                    info = try await backend.getSSHCommand(sandboxId: sandboxId)
                }

                await MainActor.run {
                    guard let pendingSelection = viewState.pendingRemoteWorkspace else {
                        return
                    }
                    let shouldAcceptCompletion = remoteWorkspaceStateController.shouldAcceptCompletion(
                        sandboxID: sandboxId,
                        pendingSelection: pendingSelection
                    )
                    guard shouldAcceptCompletion else {
                        return
                    }
                    let currentWorkspace = mainSelectionCoordinator.workspace(
                        with: pendingSelection.workspaceID,
                        in: repos
                    )

                    viewState.connectingSandboxId = nil
                    viewState.pendingRemoteWorkspace = nil
                    guard let currentWorkspace else { return }
                    markAccessed(workspace: currentWorkspace)
                    applyNavigationDestination(.workspaceTerminal(currentWorkspace))
                    let session = activateHostSession(
                        key: sessionKey,
                        directory: placeholderDir,
                        customCommand: info.sshCommand
                    )
                    terminalFocusCoordinator.requestMainTerminalFocus(
                        targetSessionID: session.id,
                        surfaceStore: hostTerminalState.surfaceStore,
                        activeSessionID: hostTerminalState.activeSessionID
                    )
                    NSLog("[RemoteBackend] SSH session created for sandbox %@", sandboxId)
                }
            } catch {
                NSLog("[RemoteBackend] Failed to connect to sandbox %@: %@", sandboxId, error.localizedDescription)
                await MainActor.run {
                    guard let pendingSelection = viewState.pendingRemoteWorkspace else {
                        return
                    }
                    let shouldAcceptCompletion = remoteWorkspaceStateController.shouldAcceptCompletion(
                        sandboxID: sandboxId,
                        pendingSelection: pendingSelection
                    )
                    guard shouldAcceptCompletion else {
                        return
                    }
                    viewState.connectingSandboxId = nil
                    viewState.pendingRemoteWorkspace = nil
                    viewState.remoteErrorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func handleWebSourceSelection(_ source: WebSource) {
        terminalFocusCoordinator.cancelPendingRepoClickMeasurement(reason: "web_source_selected")
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
    private func createWorkspaceFromLanding(repo: Repo, name: String, backend: WorkspaceBackendChoice) async {
        let controller = SidebarWorkspaceController(
            modelContext: modelContext,
            workspaceService: workspaceService,
            remoteBackend: remoteBackend
        )
        do {
            let workspace: Workspace
            switch backend {
            case .local:
                workspace = try await controller.createWorkspace(from: repo, name: name, progress: { _ in })
            case .remoteVM:
                workspace = try await controller.createRemoteWorkspace(from: repo, name: name)
            }
            abandonPendingRemoteConnection(reason: "workspace_created")
            handleWorkspaceSelection(workspace)
        } catch {
            landingErrorMessage = "Failed to create workspace: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func archiveWorkspaceFromLanding(_ workspace: Workspace) async {
        if workspace.isRemote {
            let controller = SidebarWorkspaceController(
                modelContext: modelContext,
                workspaceService: workspaceService,
                remoteBackend: remoteBackend
            )
            do {
                try await controller.archive(workspace)
            } catch {
                landingErrorMessage = "Failed to archive workspace: \(error.localizedDescription)"
            }
        } else {
            workspace.status = .archived
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
        repo.lastAccessedAt = Date()
        saveAccessTimestampChanges()
    }

    @MainActor
    private func markAccessed(workspace: Workspace) {
        let accessDate = Date()
        workspace.lastAccessedAt = accessDate
        workspace.sourceRepo?.lastAccessedAt = accessDate
        saveAccessTimestampChanges()
    }

    @MainActor
    private func markAccessed(webSource: WebSource) {
        let accessDate = Date()
        webSource.lastAccessedAt = accessDate
        webSource.ownerRepo?.lastAccessedAt = accessDate
        saveAccessTimestampChanges()
    }

    @MainActor
    private func saveAccessTimestampChanges() {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
        }
    }

    @MainActor
    private func handleTerminalProcessExit(sessionID: UUID) {
        NSLog("[HostSession] Process exit detected for session %@", sessionID.uuidString)
        guard
            let focusSessionID = hostTerminalState.handleProcessExitAndResolveFocusTarget(
                for: sessionID,
                defaultHomeDirectory: resolvedDefaultHostDirectory
            )
        else {
            return
        }

        // Sync sidebar selection to match the new active session.
        syncSidebarSelectionToActiveSession()

        terminalFocusCoordinator.requestMainTerminalFocus(
            targetSessionID: focusSessionID,
            activateApp: false,
            surfaceStore: hostTerminalState.surfaceStore,
            activeSessionID: hostTerminalState.activeSessionID
        )
    }

    @MainActor
    private func syncSidebarSelectionToActiveSession() {
        let syncedWorkspace = mainSelectionCoordinator.syncedWorkspaceSelection(
            for: activeHostSession,
            repos: repos,
            normalizePath: normalizePath
        )
        setSelectedWorkspace(syncedWorkspace)
    }

    private func syncCloudWorkspaceStatuses() async {
        let cloudWorkspaces = repos.flatMap(\.workspaces).filter { $0.remoteId != nil }
        guard !cloudWorkspaces.isEmpty else { return }

        let backend = remoteBackend
        let statuses: [RemoteSandboxStatus]
        do {
            statuses = try await backend.listSandboxes()
        } catch {
            NSLog("[RemoteBackend] Failed to sync sandbox statuses: %@", error.localizedDescription)
            return
        }

        let stateById = Dictionary(uniqueKeysWithValues: statuses.map { ($0.sandboxId, $0.state) })
        var changed = false

        for workspace in cloudWorkspaces {
            guard let sandboxId = workspace.remoteId else { continue }
            let newStatus: WorkspaceStatus
            if let state = stateById[sandboxId] {
                switch state {
                case "started", "starting":
                    newStatus = .active
                case "stopped", "stopping":
                    newStatus = .stopped
                case "archived", "archiving":
                    newStatus = .archived
                default:
                    continue
                }
            } else {
                // Sandbox no longer exists on remote backend — mark archived
                newStatus = .archived
            }

            if workspace.status != newStatus {
                NSLog(
                    "[RemoteBackend] Syncing workspace '%@' status: %@ → %@",
                    workspace.name, workspace.status.rawValue, newStatus.rawValue)
                workspace.status = newStatus
                changed = true
            }
        }

        if changed {
            try? modelContext.save()
        }
    }

    @MainActor
    private func ensureInitialHostSession() {
        guard !hostTerminalState.hasSessions else { return }
        _ = activateHostSession(
            key: .defaultHome,
            directory: resolvedDefaultHostDirectory
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

        case .remoteSandbox(let sandboxID):
            guard
                let workspace =
                    repos
                    .flatMap(\.workspaces)
                    .first(where: { $0.remoteId == sandboxID })
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
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first(where: \.isVisible) ?? NSApp.windows.first
        window?.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let terminal = TerminalFocusManager.shared.focusedTerminal else { return }
            TerminalFocusManager.shared.requestFocus(for: terminal)
        }
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
    let activeHostTerminalSessionID: UUID?
    let activeSplitHostSession: HostTerminalSession?
    let activeSplitLayout: HostTerminalStateStore.SplitPaneLayout?
    let activeSplitFraction: CGFloat?
    let hostSurfaceStore: HostTerminalSurfaceStore
    let terminalContextMenuProvider: (HostTerminalSession) -> NSMenu?
    let onSplitFractionChanged: (CGFloat) -> Void
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
                    RightPaneView(
                        workspace: selectedWorkspace,
                        state: rightPaneStateStore.state(for: selectedWorkspace),
                        onFileSelected: onFileSelected
                    )
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
                } else if let selectedRepo {
                    RightPaneView(
                        repo: selectedRepo,
                        state: rightPaneStateStore.state(for: selectedRepo),
                        onFileSelected: onFileSelected
                    )
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
                }
            }
        }
        .navigationTitle(navigationTitle)
    }

    @ViewBuilder
    private var previewAndTerminalPanel: some View {
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

    private var hostTerminalPanel: some View {
        HostTerminalSessionStack(
            sessions: hostTerminalSessions,
            activeSessionID: activeHostTerminalSessionID,
            splitSession: activeSplitHostSession,
            splitLayout: activeSplitLayout,
            splitFraction: activeSplitFraction,
            surfaceStore: hostSurfaceStore,
            onSplitFractionChanged: onSplitFractionChanged,
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

        guard let activeHostSession else { return "WorkspaceManager" }

        switch activeHostSession.key {
        case .defaultHome:
            return "WorkspaceManager"
        case .repoPath, .hostPath:
            return activeHostSession.directoryURL.lastPathComponent
        case .remoteSandbox(let sandboxID):
            return selectedWorkspace?.name ?? "Sandbox \(sandboxID)"
        }
    }
}

struct SandboxConnectingOverlay: View {
    let workspaceName: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Connecting to \(workspaceName ?? "sandbox")...")
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
    @StateObject private var hostTerminalState = HostTerminalStateStore()

    var body: some View {
        ContentView(
            deepLinkState: $deepLinkState,
            lastSurfaceRawValue: $lastSurfaceRawValue,
            hostTerminalState: hostTerminalState
        )
    }
}
