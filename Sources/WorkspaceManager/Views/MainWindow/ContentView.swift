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
    private enum OpenInEditorContextKey: Equatable {
        case none
        case file(String)
        case workspace(UUID)
        case repo(UUID)
    }

    @Environment(\.modelContext) private var modelContext
    @Binding var deepLinkState: WorkspaceDeepLinkState
    @ObservedObject var hostTerminalState: HostTerminalStateStore
    @Query(sort: \Repo.addedAt, order: .reverse) private var repos: [Repo]
    @Query(sort: \WebSource.addedAt, order: .reverse) private var webSources: [WebSource]
    @AppStorage(TerminalMultiplexingMode.storageKey)
    private var terminalMultiplexingModeRawValue: String = TerminalMultiplexingMode.defaultValue.rawValue
    @Environment(\.externalEditorService) private var externalEditorService
    @Environment(\.remoteBackend) private var remoteBackend

    @State private var selectedWorkspace: Workspace?
    @State private var selectedWebSource: WebSource?
    @State private var selectedCodePreview: CodePreviewSelection?
    @State private var isTerminalPanelVisible = true
    @State private var isRightPaneVisible = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var didRunPerfAutoSelection = false
    @State private var didApplyFixturePreviewBootstrap = false
    @State private var didApplyFixtureWebBootstrap = false
    @State private var openInEditorErrorMessage: String?
    @State private var remoteErrorMessage: String?
    @State private var connectingSandboxId: String?
    @StateObject private var rightPaneStateStore = RightPaneStateStore()
    @StateObject private var webSurfaceStore = WebSurfaceStore()
    @StateObject private var terminalFocusCoordinator = TerminalFocusCoordinator()
    private let resolvedDefaultHostDirectory = HostTerminalDefaults.defaultWorkingDirectory()
        .standardizedFileURL
        .resolvingSymlinksInPath()
    private let inspectorStateController = InspectorStateController()
    private let mainSelectionCoordinator = MainSelectionCoordinator()
    private let splitRoutingController = SplitRoutingController()

    private var sessionPresentation: HostTerminalSessionPresentation {
        hostTerminalState.sessionPresentation
    }

    private var terminalMultiplexingMode: TerminalMultiplexingMode {
        TerminalMultiplexingMode(rawValue: terminalMultiplexingModeRawValue) ?? .defaultValue
    }

    private var activeHostSession: HostTerminalSession? {
        guard let activeSessionID = hostTerminalState.activeSessionID else {
            return hostTerminalState.sessions.last
        }
        return hostTerminalState.sessions.first(where: { $0.id == activeSessionID }) ?? hostTerminalState.sessions.last
    }

    private var repoByNormalizedPath: [String: Repo] {
        var index: [String: Repo] = [:]
        index.reserveCapacity(repos.count)

        for repo in repos {
            let normalizedPath = normalizePath(repo.localPath)
            if index[normalizedPath] == nil {
                index[normalizedPath] = repo
            }
        }

        return index
    }

    private var normalizedRepoPathSnapshot: [String] {
        repos.map { normalizePath($0.localPath) }
    }

    private var selectedRepoForInspector: Repo? {
        guard selectedWorkspace == nil, selectedWebSource == nil else {
            return nil
        }

        if let activeRepoPath = sessionPresentation.activeRepoPath {
            let normalizedActiveRepoPath = normalizePath(activeRepoPath)
            if let matchedRepo = repoByNormalizedPath[normalizedActiveRepoPath] {
                return matchedRepo
            }
        }

        guard let activeHostSession else {
            return nil
        }

        let normalizedActiveSessionPath = normalizePath(activeHostSession.directoryPath)
        return repoByNormalizedPath[normalizedActiveSessionPath]
    }

    private var paneCountBySessionKeyForSidebar: [HostTerminalSessionKey: Int] {
        var paneCounts: [HostTerminalSessionKey: Int] = [:]
        paneCounts.reserveCapacity(hostTerminalState.sessions.count)

        for session in hostTerminalState.sessions {
            paneCounts[session.key, default: 0] &+= 1
            if hostTerminalState.splitSession(for: session.id) != nil {
                paneCounts[session.key, default: 0] &+= 1
            }
        }

        return paneCounts
    }

    private var activeSessionKeyForSidebar: HostTerminalSessionKey? {
        Self.sidebarActiveSessionKey(
            selectedWebSourceID: selectedWebSource?.id,
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
        guard let activeSessionID else { return nil }
        return sessions.first(where: { $0.id == activeSessionID })?.key
    }

    private var hasInspectorTarget: Bool {
        inspectorStateController.hasInspectorTarget(
            selectedWorkspace: selectedWorkspace,
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
        if let selectedCodePreview {
            return .projectAndFile(
                rootURL: selectedCodePreview.rootURL,
                fileURL: selectedCodePreview.fileURL
            )
        }
        if let selectedWorkspace {
            return .project(rootURL: selectedWorkspace.workspaceURL)
        }
        if let selectedRepoForInspector {
            return .project(rootURL: selectedRepoForInspector.localURL)
        }
        return nil
    }

    private var openInEditorContextKey: OpenInEditorContextKey {
        if let selectedCodePreview {
            return .file(selectedCodePreview.id)
        }
        if let selectedWorkspace {
            return .workspace(selectedWorkspace.id)
        }
        if let selectedRepoForInspector {
            return .repo(selectedRepoForInspector.id)
        }
        return .none
    }

    private var openInEditorFocusedAction: (@MainActor () -> Void)? {
        guard openInEditorTarget != nil else { return nil }
        return openInDefaultEditor
    }

    private var isShowingOpenInEditorError: Binding<Bool> {
        Binding(
            get: { openInEditorErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    openInEditorErrorMessage = nil
                }
            }
        )
    }

    @ViewBuilder
    private var terminalDetailContent: some View {
        MainTerminalDetailView(
            selectedWorkspace: selectedWorkspace,
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
            selectedCodePreview: $selectedCodePreview,
            isTerminalPanelVisible: $isTerminalPanelVisible,
            onFileSelected: handleCodePreviewSelection,
            availableEditors: availableEditors,
            defaultEditor: defaultEditorDescriptor,
            onOpenInDefaultEditor: openInDefaultEditor,
            onOpenInEditor: openInSelectedEditor,
            rightPaneStateStore: rightPaneStateStore,
            isRightPaneVisible: $isRightPaneVisible
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selectedWebSource {
            WebSourceDetailView(
                source: selectedWebSource,
                surfaceStore: webSurfaceStore
            )
        } else {
            ZStack {
                terminalDetailContent
                if connectingSandboxId != nil {
                    SandboxConnectingOverlay(workspaceName: selectedWorkspace?.name)
                }
            }
        }
    }

    private var baseSplitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                repos: repos,
                webSources: webSources,
                selectedWorkspace: $selectedWorkspace,
                selectedWebSource: $selectedWebSource,
                defaultHostPath: resolvedDefaultHostDirectory.path,
                paneCountBySessionKey: paneCountBySessionKeyForSidebar,
                activeSessionKey: activeSessionKeyForSidebar,
                connectingSandboxId: connectingSandboxId,
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
                    if let selectedWebSource {
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
                        let workspace = selectedWorkspace
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
                            isRightPaneVisible.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .help(isRightPaneVisible ? "Hide Inspector" : "Show Inspector")
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
                if let selectedWebSource, !validIDs.contains(selectedWebSource.id) {
                    self.selectedWebSource = nil
                    webSurfaceStore.releaseInactiveSurface()
                }
                maybeApplyFixtureWebBootstrap()
            }
            .onChange(of: inspectorTargetIDSet) { _, _ in
                pruneRightPaneState()
            }
            .onChange(of: selectedWorkspace?.id) { _, _ in
                guard let selectedWorkspace else { return }
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
                    openInEditorErrorMessage = nil
                }
            } message: {
                Text(openInEditorErrorMessage ?? "Unknown error.")
            }
            .alert(
                "Could Not Connect to Sandbox",
                isPresented: Binding(
                    get: { remoteErrorMessage != nil },
                    set: { if !$0 { remoteErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { remoteErrorMessage = nil }
            } message: {
                Text(remoteErrorMessage ?? "Unknown error.")
            }
    }

    var body: some View {
        splitViewWithFocusAndAlerts
    }

    @MainActor
    private func processPendingDeepLink() {
        guard let request = deepLinkState.pendingRequest else { return }

        guard let workspace = bestWorkspaceMatch(for: request.cwd) else {
            // On cold launch, wait for SwiftData to load before deciding this is a no-match.
            if repos.isEmpty { return }
            NSLog("[DeepLink] No workspace match for cwd: %@", request.cwd)
            deepLinkState.clearPendingRequest()
            return
        }

        NSLog(
            "[DeepLink] Matched workspace '%@' for cwd '%@' (session_id=%@ source=%@)",
            workspace.name,
            request.cwd,
            request.sessionID ?? "",
            request.source ?? ""
        )

        selectedWebSource = nil
        selectedWorkspace = workspace
        clearCodePreview()
        columnVisibility = .all
        deepLinkState.clearPendingRequest()
        focusWorkspaceWindow()
    }

    @MainActor
    private func maybeAutoSelectRepoForPerf() {
        guard ProcessInfo.processInfo.environment["WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO"] == "1" else { return }
        guard !didRunPerfAutoSelection else { return }
        guard deepLinkState.pendingRequest == nil else { return }
        guard let firstRepo = repos.first else { return }

        didRunPerfAutoSelection = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Task { @MainActor in
                handleRepoSelection(firstRepo)
            }
        }
    }

    @MainActor
    private func maybeApplyFixturePreviewBootstrap() {
        guard !didApplyFixturePreviewBootstrap else { return }
        guard deepLinkState.pendingRequest == nil else { return }
        guard let configuration = fixturePreviewBootstrapConfiguration else { return }

        guard !repos.isEmpty else { return }
        didApplyFixturePreviewBootstrap = true

        guard
            let resolved = UIFixturePreviewBootstrap.resolveSelection(
                configuration: configuration,
                repos: repos
            )
        else {
            NSLog(
                "[UIFixture] Preview bootstrap skipped (repo=%@ path=%@)",
                configuration.repoName,
                configuration.relativePath
            )
            return
        }

        handleRepoSelection(resolved.repo)
        selectedCodePreview = resolved.selection
        isTerminalPanelVisible = true
        isRightPaneVisible = true

        NSLog(
            "[UIFixture] Preview bootstrap applied (repo=%@ file=%@)",
            resolved.repo.name,
            resolved.selection.relativePath
        )
    }

    @MainActor
    private func maybeApplyFixtureWebBootstrap() {
        guard !didApplyFixtureWebBootstrap else { return }
        guard deepLinkState.pendingRequest == nil else { return }
        guard let configuration = fixtureWebBootstrapConfiguration else { return }
        guard !webSources.isEmpty else { return }
        didApplyFixtureWebBootstrap = true

        let targetName = configuration.webSourceName
        let selectedSource =
            webSources.first(where: { $0.name.caseInsensitiveCompare(targetName) == .orderedSame })
            ?? webSources.first(where: { $0.name.localizedCaseInsensitiveContains(targetName) })
            ?? webSources.first

        guard let selectedSource else {
            NSLog("[UIFixture] Web bootstrap skipped (target=%@)", targetName)
            return
        }

        handleWebSourceSelection(selectedSource)
        NSLog(
            "[UIFixture] Web bootstrap applied (target=%@ selected=%@)",
            targetName,
            selectedSource.name
        )
    }

    @MainActor
    private func handleRepoSelection(_ repo: Repo) {
        let repoDirectory = repo.localURL.standardizedFileURL.resolvingSymlinksInPath()

        selectedWebSource = nil
        selectedWorkspace = nil
        clearCodePreview()
        let session = activateHostSession(
            key: .repoPath(repoDirectory.path),
            directory: repoDirectory
        )
        terminalFocusCoordinator.beginRepoClickMeasurement(
            sessionID: session.id,
            repoPath: repoDirectory.path
        )
        columnVisibility = .all

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
        selectedWebSource = nil
        selectedWorkspace = nil
        clearCodePreview()
        let session = activateHostSession(
            key: .defaultHome,
            directory: resolvedDefaultHostDirectory
        )
        columnVisibility = .all

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
        selectedWebSource = nil
        clearCodePreview()

        if workspace.isRemote, let sandboxId = workspace.remoteId {
            handleRemoteWorkspaceSelection(workspace, sandboxId: sandboxId)
        } else {
            let workspaceDirectory = workspace.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
            let session = activateHostSession(
                key: .hostPath(workspaceDirectory.path),
                directory: workspaceDirectory
            )
            columnVisibility = .all

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
            columnVisibility = .all
            terminalFocusCoordinator.requestMainTerminalFocus(
                targetSessionID: existing.id,
                surfaceStore: hostTerminalState.surfaceStore,
                activeSessionID: hostTerminalState.activeSessionID
            )
            return
        }

        // Prevent concurrent connection attempts
        guard connectingSandboxId == nil else {
            NSLog("[RemoteBackend] Ignoring selection — already connecting to %@", connectingSandboxId ?? "")
            return
        }

        let backend = remoteBackend
        let needsStart = workspace.status == .stopped || workspace.status == .archived
        connectingSandboxId = sandboxId

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
                    guard connectingSandboxId == sandboxId else { return }
                    connectingSandboxId = nil
                    let session = activateHostSession(
                        key: sessionKey,
                        directory: placeholderDir,
                        customCommand: info.sshCommand
                    )
                    columnVisibility = .all
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
                    guard connectingSandboxId == sandboxId else { return }
                    connectingSandboxId = nil
                    remoteErrorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func handleWebSourceSelection(_ source: WebSource) {
        terminalFocusCoordinator.cancelPendingRepoClickMeasurement(reason: "web_source_selected")
        selectedWorkspace = nil
        clearCodePreview()
        isRightPaneVisible = false
        selectedWebSource = source
        columnVisibility = .all
        webSurfaceStore.cancelPendingRelease()
    }

    @MainActor
    private func handleWorkspaceCreated() {
        guard selectedWorkspace == nil else { return }
        isRightPaneVisible = false
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
        selectedWorkspace = mainSelectionCoordinator.syncedWorkspaceSelection(
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
            switch columnVisibility {
            case .detailOnly:
                columnVisibility = .all
            case .all:
                columnVisibility = .detailOnly
            default:
                columnVisibility = .detailOnly
            }
        }
    }

    @MainActor
    private func toggleInspectorVisibility() {
        withAnimation(.easeInOut(duration: 0.2)) {
            inspectorStateController.toggleInspectorVisibility(
                hasTarget: hasInspectorTarget,
                isVisible: &isRightPaneVisible
            )
        }
    }

    @MainActor
    private func toggleTerminalPanelVisibility() {
        guard selectedCodePreview != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isTerminalPanelVisible.toggle()
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
        selectedCodePreview = selection
        isTerminalPanelVisible = true
    }

    @MainActor
    private func openSelectedWebSourceInBrowser() {
        guard let selectedWebSource else { return }
        let webView = webSurfaceStore.ensureSurface(for: selectedWebSource)
        if let currentURL = webView.url {
            NSWorkspace.shared.open(currentURL)
        } else if let baseURL = selectedWebSource.baseURL {
            NSWorkspace.shared.open(baseURL)
        }
    }

    @MainActor
    private func reloadSelectedWebSource() {
        guard let selectedWebSource else { return }
        let webView = webSurfaceStore.ensureSurface(for: selectedWebSource)
        if let currentURL = webView.url {
            webView.load(URLRequest(url: currentURL))
        } else if let baseURL = selectedWebSource.baseURL {
            webView.load(URLRequest(url: baseURL))
        }
    }

    private func clearCodePreview() {
        selectedCodePreview = nil
        isTerminalPanelVisible = true
    }

    @MainActor
    private func syncOpenInEditorShortcutRouting() {
        OpenInEditorShortcutFlow.syncRouting(for: openInEditorTarget)
    }

    @MainActor
    private func presentOpenInEditorError(_ error: Error) {
        if let externalEditorError = error as? ExternalEditorError {
            openInEditorErrorMessage = externalEditorError.errorDescription ?? "Could not open the selected file."
        } else {
            openInEditorErrorMessage = error.localizedDescription
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

    private func bestWorkspaceMatch(for cwd: String) -> Workspace? {
        mainSelectionCoordinator.bestWorkspaceMatch(
            for: cwd,
            repos: repos,
            normalizePath: normalizePath,
            pathIsInside: path(_:isInside:)
        )
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
