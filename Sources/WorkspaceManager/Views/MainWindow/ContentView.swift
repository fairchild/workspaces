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
    @ObservedObject var hostTerminalState: HostTerminalStateStore
    @Query(sort: \Repo.addedAt, order: .reverse) private var repos: [Repo]
    @Query(sort: \WebSource.addedAt, order: .reverse) private var webSources: [WebSource]
    @AppStorage(TerminalMultiplexingMode.storageKey)
    private var terminalMultiplexingModeRawValue: String = TerminalMultiplexingMode.defaultValue.rawValue
    @Environment(\.externalEditorService) private var externalEditorService
    @Environment(\.remoteBackend) private var remoteBackend

    @State private var viewState = MainWindowViewState()
    @StateObject private var rightPaneStateStore = RightPaneStateStore()
    @StateObject private var webSurfaceStore = WebSurfaceStore()
    @StateObject private var terminalFocusCoordinator = TerminalFocusCoordinator()
    private let resolvedDefaultHostDirectory = HostTerminalDefaults.defaultWorkingDirectory()
        .standardizedFileURL
        .resolvingSymlinksInPath()
    private let bootstrapController = MainWindowBootstrapController()
    private let inspectorStateController = InspectorStateController()
    private let mainSelectionCoordinator = MainSelectionCoordinator()
    private let presentationController = MainWindowPresentationController()
    private let splitRoutingController = SplitRoutingController()

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

    private var normalizedRepoPathSnapshot: [String] {
        repos.map { normalizePath($0.localPath) }
    }

    private var selectedRepoForInspector: Repo? {
        presentationController.selectedRepoForInspector(
            selectedWorkspace: viewState.selectedWorkspace,
            selectedWebSource: viewState.selectedWebSource,
            activeRepoPath: sessionPresentation.activeRepoPath,
            activeHostSession: activeHostSession,
            repos: repos,
            normalizePath: normalizePath
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
            selectedWebSource: viewState.selectedWebSource,
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
            selectedWorkspace: viewState.selectedWorkspace,
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
            selectedWorkspace: viewState.selectedWorkspace,
            selectedRepo: selectedRepoForInspector
        )
    }

    private var openInEditorContextKey: MainWindowOpenInEditorContextKey {
        presentationController.openInEditorContextKey(
            selectedCodePreview: viewState.selectedCodePreview,
            selectedWorkspace: viewState.selectedWorkspace,
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
            selectedWorkspace: viewState.selectedWorkspace,
            selectedRepo: selectedRepoForInspector,
            hostTerminalSessions: hostTerminalState.sessions,
            activeHostTerminalSessionID: hostTerminalState.activeSessionID,
            activeSplitHostSession: hostTerminalState.splitSession(for: hostTerminalState.activeSessionID),
            activeSplitLayout: hostTerminalState.splitLayout(for: hostTerminalState.activeSessionID),
            activeSplitFraction: hostTerminalState.splitFraction(for: hostTerminalState.activeSessionID),
            hostSurfaceStore: hostTerminalState.surfaceStore,
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
        if let selectedWebSource = viewState.selectedWebSource {
            WebSourceDetailView(
                source: selectedWebSource,
                surfaceStore: webSurfaceStore
            )
        } else {
            ZStack {
                terminalDetailContent
                if viewState.connectingSandboxId != nil {
                    SandboxConnectingOverlay(workspaceName: viewState.selectedWorkspace?.name)
                }
            }
        }
    }

    private var baseSplitView: some View {
        NavigationSplitView(columnVisibility: $viewState.columnVisibility) {
            SidebarView(
                repos: repos,
                webSources: webSources,
                selectedWorkspace: $viewState.selectedWorkspace,
                selectedWebSource: $viewState.selectedWebSource,
                defaultHostPath: resolvedDefaultHostDirectory.path,
                paneCountBySessionKey: paneCountBySessionKeyForSidebar,
                activeSessionKey: activeSessionKeyForSidebar,
                connectingSandboxId: viewState.connectingSandboxId,
                onDefaultHostSelected: handleDefaultHostSelection,
                onRepoSelected: handleRepoSelection,
                onWebSourceSelected: handleWebSourceSelection,
                onWorkspaceCreated: handleWorkspaceCreated
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 350)
        } detail: {
            detailContent
        }
    }

    private var splitViewWithToolbar: some View {
        baseSplitView
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    if let selectedWebSource = viewState.selectedWebSource {
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
                        let workspace = viewState.selectedWorkspace
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
                processPendingDeepLink()
                maybeAutoSelectRepoForPerf()
                maybeApplyFixturePreviewBootstrap()
                maybeApplyFixtureWebBootstrap()
                pruneRightPaneState()
                syncOpenInEditorShortcutRouting()
            }
            .task {
                await syncCloudWorkspaceStatuses()
            }
            .onDisappear {
                ShortcutRoutingPolicy.shared.setOverride(nil, for: AppChromeShortcut.openInEditor.chord)
            }
            .onChange(of: deepLinkState.pendingRequest) { _, _ in
                processPendingDeepLink()
            }
            .onChange(of: repos.count) { _, _ in
                processPendingDeepLink()
                maybeAutoSelectRepoForPerf()
                maybeApplyFixturePreviewBootstrap()
                maybeApplyFixtureWebBootstrap()
            }
            .onChange(of: normalizedRepoPathSnapshot) { _, paths in
                hostTerminalState.pruneRepoSessions(validRepoPaths: Set(paths))
            }
            .onChange(of: webSources.map(\.id)) { _, sourceIDs in
                let validIDs = Set(sourceIDs)
                if let selectedWebSource = viewState.selectedWebSource,
                    !validIDs.contains(selectedWebSource.id)
                {
                    viewState.selectedWebSource = nil
                    webSurfaceStore.releaseInactiveSurface()
                }
                maybeApplyFixtureWebBootstrap()
            }
            .onChange(of: inspectorTargetIDSet) { _, _ in
                pruneRightPaneState()
            }
            .onChange(of: viewState.selectedWorkspace?.id) { _, _ in
                guard let selectedWorkspace = viewState.selectedWorkspace else { return }
                handleWorkspaceSelection(selectedWorkspace)
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

    var body: some View {
        splitViewWithFocusAndAlerts
    }

    @MainActor
    private func processPendingDeepLink() {
        switch bootstrapController.deepLinkDecision(
            pendingRequest: deepLinkState.pendingRequest,
            repos: repos,
            normalizePath: normalizePath,
            pathIsInside: path(_:isInside:)
        ) {
        case .none, .waitForRepos:
            return
        case .clearNoMatch(let request):
            NSLog("[DeepLink] No workspace match for cwd: %@", request.cwd)
            deepLinkState.clearPendingRequest()
        case .select(let request, let workspace):
            NSLog(
                "[DeepLink] Matched workspace '%@' for cwd '%@' (session_id=%@ source=%@)",
                workspace.name,
                request.cwd,
                request.sessionID ?? "",
                request.source ?? ""
            )

            viewState.selectedWebSource = nil
            viewState.selectedWorkspace = workspace
            clearCodePreview()
            viewState.columnVisibility = .all
            deepLinkState.clearPendingRequest()
            focusWorkspaceWindow()
        }
    }

    @MainActor
    private func maybeAutoSelectRepoForPerf() {
        guard
            let firstRepo = bootstrapController.perfAutoSelectedRepo(
                environment: ProcessInfo.processInfo.environment,
                didRun: viewState.didRunPerfAutoSelection,
                pendingRequest: deepLinkState.pendingRequest,
                repos: repos
            )
        else {
            return
        }

        viewState.didRunPerfAutoSelection = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Task { @MainActor in
                handleRepoSelection(firstRepo)
            }
        }
    }

    @MainActor
    private func maybeApplyFixturePreviewBootstrap() {
        switch bootstrapController.previewBootstrapDecision(
            didApply: viewState.didApplyFixturePreviewBootstrap,
            pendingRequest: deepLinkState.pendingRequest,
            configuration: fixturePreviewBootstrapConfiguration,
            repos: repos
        ) {
        case .none:
            return
        case .noMatch(let configuration):
            viewState.didApplyFixturePreviewBootstrap = true
            NSLog(
                "[UIFixture] Preview bootstrap skipped (repo=%@ path=%@)",
                configuration.repoName,
                configuration.relativePath
            )
        case .apply(_, let repo, let selection):
            viewState.didApplyFixturePreviewBootstrap = true
            handleRepoSelection(repo)
            viewState.selectedCodePreview = selection
            viewState.isTerminalPanelVisible = true
            viewState.isRightPaneVisible = true

            NSLog(
                "[UIFixture] Preview bootstrap applied (repo=%@ file=%@)",
                repo.name,
                selection.relativePath
            )
        }
    }

    @MainActor
    private func maybeApplyFixtureWebBootstrap() {
        switch bootstrapController.webBootstrapDecision(
            didApply: viewState.didApplyFixtureWebBootstrap,
            pendingRequest: deepLinkState.pendingRequest,
            configuration: fixtureWebBootstrapConfiguration,
            webSources: webSources
        ) {
        case .none:
            return
        case .noMatch(let targetName):
            viewState.didApplyFixtureWebBootstrap = true
            NSLog("[UIFixture] Web bootstrap skipped (target=%@)", targetName)
        case .select(let targetName, let selectedSource):
            viewState.didApplyFixtureWebBootstrap = true
            handleWebSourceSelection(selectedSource)
            NSLog(
                "[UIFixture] Web bootstrap applied (target=%@ selected=%@)",
                targetName,
                selectedSource.name
            )
        }
    }

    @MainActor
    private func handleRepoSelection(_ repo: Repo) {
        let repoDirectory = repo.localURL.standardizedFileURL.resolvingSymlinksInPath()

        viewState.selectedWebSource = nil
        viewState.selectedWorkspace = nil
        clearCodePreview()
        let session = activateHostSession(
            key: .repoPath(repoDirectory.path),
            directory: repoDirectory
        )
        terminalFocusCoordinator.beginRepoClickMeasurement(
            sessionID: session.id,
            repoPath: repoDirectory.path
        )
        viewState.columnVisibility = .all

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
    private func handleDefaultHostSelection() {
        terminalFocusCoordinator.cancelPendingRepoClickMeasurement(reason: "default_host_selected")
        viewState.selectedWebSource = nil
        viewState.selectedWorkspace = nil
        clearCodePreview()
        let session = activateHostSession(
            key: .defaultHome,
            directory: resolvedDefaultHostDirectory
        )
        viewState.columnVisibility = .all

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

    @MainActor
    private func handleWorkspaceSelection(_ workspace: Workspace) {
        terminalFocusCoordinator.cancelPendingRepoClickMeasurement(reason: "workspace_selected")
        viewState.selectedWebSource = nil
        clearCodePreview()

        if workspace.isRemote, let sandboxId = workspace.remoteId {
            handleRemoteWorkspaceSelection(workspace, sandboxId: sandboxId)
        } else {
            let workspaceDirectory = workspace.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
            let session = activateHostSession(
                key: .hostPath(workspaceDirectory.path),
                directory: workspaceDirectory
            )
            viewState.columnVisibility = .all

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
            hostTerminalState.activateExistingSession(sessionID: existing.id)
            viewState.columnVisibility = .all
            terminalFocusCoordinator.requestMainTerminalFocus(
                targetSessionID: existing.id,
                surfaceStore: hostTerminalState.surfaceStore,
                activeSessionID: hostTerminalState.activeSessionID
            )
            return
        }

        // Prevent concurrent connection attempts
        guard viewState.connectingSandboxId == nil else {
            NSLog(
                "[RemoteBackend] Ignoring selection — already connecting to %@",
                viewState.connectingSandboxId ?? ""
            )
            return
        }

        let backend = remoteBackend
        let needsStart = workspace.status == .stopped || workspace.status == .archived
        viewState.connectingSandboxId = sandboxId

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
                    // Stale completion — user clicked something else while we were connecting
                    guard viewState.connectingSandboxId == sandboxId else { return }
                    viewState.connectingSandboxId = nil
                    let session = activateHostSession(
                        key: sessionKey,
                        directory: placeholderDir,
                        customCommand: info.sshCommand
                    )
                    viewState.columnVisibility = .all
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
                    guard viewState.connectingSandboxId == sandboxId else { return }
                    viewState.connectingSandboxId = nil
                    viewState.remoteErrorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func handleWebSourceSelection(_ source: WebSource) {
        terminalFocusCoordinator.cancelPendingRepoClickMeasurement(reason: "web_source_selected")
        viewState.selectedWorkspace = nil
        clearCodePreview()
        viewState.isRightPaneVisible = false
        viewState.selectedWebSource = source
        viewState.columnVisibility = .all
        webSurfaceStore.cancelPendingRelease()
    }

    @MainActor
    private func handleWorkspaceCreated() {
        guard viewState.selectedWorkspace == nil else { return }
        viewState.isRightPaneVisible = false
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
        viewState.selectedWorkspace = mainSelectionCoordinator.syncedWorkspaceSelection(
            for: activeHostSession,
            repos: repos,
            normalizePath: normalizePath
        )
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
        guard let selectedWebSource = viewState.selectedWebSource else { return }
        let webView = webSurfaceStore.ensureSurface(for: selectedWebSource)
        if let currentURL = webView.url {
            NSWorkspace.shared.open(currentURL)
        } else if let baseURL = selectedWebSource.baseURL {
            NSWorkspace.shared.open(baseURL)
        }
    }

    @MainActor
    private func reloadSelectedWebSource() {
        guard let selectedWebSource = viewState.selectedWebSource else { return }
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

// MARK: - Main Terminal (Host-pinned)

struct MainTerminalDetailView: View {
    let selectedWorkspace: Workspace?
    let selectedRepo: Repo?
    let hostTerminalSessions: [HostTerminalSession]
    let activeHostTerminalSessionID: UUID?
    let activeSplitHostSession: HostTerminalSession?
    let activeSplitLayout: HostTerminalStateStore.SplitPaneLayout?
    let activeSplitFraction: CGFloat?
    let hostSurfaceStore: HostTerminalSurfaceStore
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
        .navigationTitle(selectedWorkspace?.name ?? "Host")
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
            onTerminalProcessExit: onTerminalProcessExit
        )
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
    @StateObject private var hostTerminalState = HostTerminalStateStore()

    var body: some View {
        ContentView(
            deepLinkState: $deepLinkState,
            hostTerminalState: hostTerminalState
        )
    }
}
