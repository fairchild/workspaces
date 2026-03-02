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
    @State private var pendingRepoFocusMeasurementSessionID: UUID?
    @State private var didRunPerfAutoSelection = false
    @State private var didApplyFixturePreviewBootstrap = false
    @State private var didApplyFixtureWebBootstrap = false
    @State private var openInEditorErrorMessage: String?
    @State private var remoteErrorMessage: String?
    @State private var connectingSandboxId: String?
    @StateObject private var rightPaneStateStore = RightPaneStateStore()
    @StateObject private var webSurfaceStore = WebSurfaceStore()
    private let resolvedDefaultHostDirectory = HostTerminalDefaults.defaultWorkingDirectory()
        .standardizedFileURL
        .resolvingSymlinksInPath()

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
        selectedWorkspace != nil || selectedRepoForInspector != nil
    }

    private var inspectorTargetIDSet: Set<String> {
        var ids = Set<String>()
        ids.reserveCapacity(repos.count * 2)

        for repo in repos {
            ids.insert("repo-\(repo.id.uuidString)")
            for workspace in repo.workspaces {
                ids.insert("workspace-\(workspace.id.uuidString)")
            }
        }

        return ids
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
            hostSurfaceStore: hostTerminalState.surfaceStore,
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
                    handleGhosttySplitAction(notification)
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
        beginRepoClickMeasurement(
            sessionID: session.id,
            repoPath: repoDirectory.path
        )
        columnVisibility = .all

        requestMainTerminalFocus(
            targetSessionID: session.id,
            onTargetFocused: {
                completeRepoClickMeasurement(
                    sessionID: session.id,
                    outcome: "focused"
                )
            }
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Task { @MainActor in
                requestMainTerminalFocus(
                    targetSessionID: session.id,
                    onTargetFocused: {
                        completeRepoClickMeasurement(
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
        cancelPendingRepoClickMeasurement(reason: "default_host_selected")
        selectedWebSource = nil
        selectedWorkspace = nil
        clearCodePreview()
        let session = activateHostSession(
            key: .defaultHome,
            directory: resolvedDefaultHostDirectory
        )
        columnVisibility = .all

        requestMainTerminalFocus(targetSessionID: session.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Task { @MainActor in
                requestMainTerminalFocus(targetSessionID: session.id)
            }
        }
    }

    @MainActor
    private func handleWorkspaceSelection(_ workspace: Workspace) {
        cancelPendingRepoClickMeasurement(reason: "workspace_selected")
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

            requestMainTerminalFocus(targetSessionID: session.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Task { @MainActor in
                    requestMainTerminalFocus(targetSessionID: session.id)
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
            requestMainTerminalFocus(targetSessionID: existing.id)
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
                    requestMainTerminalFocus(targetSessionID: session.id)
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
        cancelPendingRepoClickMeasurement(reason: "web_source_selected")
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

        requestMainTerminalFocus(
            targetSessionID: focusSessionID,
            activateApp: false
        )
    }

    @MainActor
    private func syncSidebarSelectionToActiveSession() {
        guard let activeSession = activeHostSession else {
            selectedWorkspace = nil
            return
        }

        switch activeSession.key {
        case .remoteSandbox(let sandboxId):
            let match = repos.flatMap(\.workspaces).first { $0.remoteId == sandboxId }
            selectedWorkspace = match
        case .hostPath(let path):
            let normalizedPath = normalizePath(path)
            let match = repos.flatMap(\.workspaces).first { normalizePath($0.path) == normalizedPath }
            selectedWorkspace = match
        case .repoPath, .defaultHome:
            selectedWorkspace = nil
        }
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
        guard hasInspectorTarget else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isRightPaneVisible.toggle()
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
        rightPaneStateStore.prune(keeping: inspectorTargetIDSet)
    }

    @MainActor
    private func handleGhosttySplitAction(_ notification: Notification) {
        guard terminalMultiplexingMode == .ghosttyManagedSplits else {
            NSLog(
                "[SplitRouting] Ignored split action while terminal mode=%@",
                terminalMultiplexingMode.rawValue
            )
            return
        }

        guard let request = GhosttyAppManager.splitActionRequest(from: notification) else {
            NSLog("[SplitRouting] Ignored split action notification with invalid payload")
            return
        }

        let sourceSessionID =
            (notification.object as? GhosttySurfaceView)
            .flatMap { hostTerminalState.surfaceStore.sessionID(for: $0) }

        switch request.kind {
        case .newSplit:
            handleGhosttyNewSplitRequest(
                sourceSessionID: sourceSessionID,
                direction: request.splitDirection
            )

        case .gotoSplit:
            handleGhosttyGotoSplitRequest(
                sourceSessionID: sourceSessionID,
                direction: request.focusDirection
            )
        }
    }

    @MainActor
    private func handleGhosttyNewSplitRequest(
        sourceSessionID: UUID?,
        direction: GhosttyAppManager.SplitDirection?
    ) {
        let primarySessionID =
            sourceSessionID.flatMap { hostTerminalState.activatePrimarySession(containing: $0) }
            ?? hostTerminalState.activeSessionID

        guard let primarySessionID else {
            NSLog("[SplitRouting] new_split ignored: no active/primary session")
            return
        }
        NSLog(
            "[SplitRouting] new_split source=%@ primary=%@", sourceSessionID?.uuidString ?? "nil",
            primarySessionID.uuidString)
        let preferredLayout = splitLayout(for: direction)
        NSLog(
            "[SplitRouting] new_split layout axis=%@ splitBeforePrimary=%@ direction=%@",
            preferredLayout.axis == .topBottom ? "topBottom" : "leadingTrailing",
            preferredLayout.splitBeforePrimary ? "true" : "false",
            String(describing: direction)
        )
        createAndFocusSplit(
            primarySessionID: primarySessionID,
            preferredLayout: preferredLayout
        )
    }

    private func splitLayout(
        for direction: GhosttyAppManager.SplitDirection?
    ) -> HostTerminalStateStore.SplitPaneLayout {
        switch direction {
        case .left:
            return HostTerminalStateStore.SplitPaneLayout(
                axis: .leadingTrailing,
                splitBeforePrimary: true
            )
        case .up:
            return HostTerminalStateStore.SplitPaneLayout(
                axis: .topBottom,
                splitBeforePrimary: true
            )
        case .down:
            return HostTerminalStateStore.SplitPaneLayout(
                axis: .topBottom,
                splitBeforePrimary: false
            )
        case .right, .none:
            return .defaultTrailing
        }
    }

    @MainActor
    private func handleGhosttyGotoSplitRequest(
        sourceSessionID: UUID?,
        direction: GhosttyAppManager.SplitFocusDirection?
    ) {
        guard let sourceSessionID,
            let direction
        else {
            NSLog("[SplitRouting] goto_split ignored: missing source or direction")
            return
        }

        guard
            let targetSessionID = hostTerminalState.splitFocusTarget(
                from: sourceSessionID,
                direction: direction
            )
        else {
            NSLog(
                "[SplitRouting] goto_split no-op source=%@ direction=%@",
                sourceSessionID.uuidString,
                String(describing: direction)
            )
            return
        }

        NSLog(
            "[SplitRouting] goto_split source=%@ target=%@ direction=%@",
            sourceSessionID.uuidString,
            targetSessionID.uuidString,
            String(describing: direction)
        )
        focusTerminal(sessionID: targetSessionID)
    }

    @MainActor
    private func createAndFocusSplit(
        primarySessionID: UUID,
        preferredLayout: HostTerminalStateStore.SplitPaneLayout
    ) {
        guard
            let splitSession = hostTerminalState.ensureSplit(
                forPrimarySessionID: primarySessionID,
                preferredLayout: preferredLayout
            )
        else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Task { @MainActor in
                focusTerminal(sessionID: splitSession.id)
            }
        }
    }

    @MainActor
    private func focusTerminal(sessionID: UUID) {
        guard let terminal = hostTerminalState.surfaceStore.terminal(for: sessionID) else {
            NSLog("[SplitRouting] focus skipped: no terminal for session %@", sessionID.uuidString)
            return
        }
        TerminalFocusManager.shared.requestFocus(for: terminal)
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
        let normalizedCWD = normalizePath(cwd)
        let allWorkspaces = repos.flatMap(\.workspaces)

        let matches = allWorkspaces.compactMap { workspace -> (workspace: Workspace, matchLength: Int)? in
            let workspacePath = normalizePath(workspace.path)
            guard path(normalizedCWD, isInside: workspacePath) else { return nil }
            return (workspace, workspacePath.count)
        }

        let bestMatch = matches.sorted { lhs, rhs in
            if lhs.matchLength == rhs.matchLength {
                return lhs.workspace.lastAccessedAt > rhs.workspace.lastAccessedAt
            }
            return lhs.matchLength > rhs.matchLength
        }.first

        guard let bestMatch else {
            return nil
        }

        return bestMatch.workspace
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

    @MainActor
    private func requestMainTerminalFocus(
        targetSessionID: UUID? = nil,
        activateApp: Bool = true,
        onTargetFocused: (() -> Void)? = nil
    ) {
        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
            let window = NSApp.windows.first(where: \.isVisible) ?? NSApp.windows.first
            window?.makeKeyAndOrderFront(nil)
        }

        if let targetSessionID,
            let terminal = hostTerminalState.surfaceStore.terminal(for: targetSessionID)
        {
            TerminalFocusManager.shared.requestFocus(
                for: terminal,
                activateApp: activateApp,
                onFocused: onTargetFocused
            )
            return
        }

        if let activeSessionID = hostTerminalState.activeSessionID,
            let terminal = hostTerminalState.surfaceStore.terminal(for: activeSessionID)
        {
            TerminalFocusManager.shared.requestFocus(
                for: terminal,
                activateApp: activateApp
            )
            return
        }

        if let terminal = TerminalFocusManager.shared.focusedTerminal {
            TerminalFocusManager.shared.requestFocus(
                for: terminal,
                activateApp: activateApp
            )
        }
    }

    @MainActor
    private func beginRepoClickMeasurement(sessionID: UUID, repoPath: String) {
        if let pendingSessionID = pendingRepoFocusMeasurementSessionID,
            pendingSessionID != sessionID
        {
            PerformanceSignposts.cancelRepoClickToFocusedInputIfNeeded(
                sessionID: pendingSessionID,
                reason: "replaced_by_new_repo_click"
            )
        }

        pendingRepoFocusMeasurementSessionID = sessionID
        PerformanceSignposts.beginRepoClickToFocusedInput(
            sessionID: sessionID,
            repoPath: repoPath
        )
    }

    @MainActor
    private func completeRepoClickMeasurement(sessionID: UUID, outcome: String) {
        guard pendingRepoFocusMeasurementSessionID == sessionID else { return }
        pendingRepoFocusMeasurementSessionID = nil
        PerformanceSignposts.endRepoClickToFocusedInputIfNeeded(
            sessionID: sessionID,
            outcome: outcome
        )
    }

    @MainActor
    private func cancelPendingRepoClickMeasurement(reason: String) {
        guard let sessionID = pendingRepoFocusMeasurementSessionID else { return }
        pendingRepoFocusMeasurementSessionID = nil
        PerformanceSignposts.cancelRepoClickToFocusedInputIfNeeded(
            sessionID: sessionID,
            reason: reason
        )
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
    let hostSurfaceStore: HostTerminalSurfaceStore
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
            surfaceStore: hostSurfaceStore,
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

struct HostTerminalSessionStack: View {
    let sessions: [HostTerminalSession]
    let activeSessionID: UUID?
    let splitSession: HostTerminalSession?
    let splitLayout: HostTerminalStateStore.SplitPaneLayout?
    let surfaceStore: HostTerminalSurfaceStore
    var onTerminalProcessExit: ((UUID) -> Void)?

    private var activeSession: HostTerminalSession? {
        guard let activeSessionID else { return sessions.last }
        return sessions.first(where: { $0.id == activeSessionID }) ?? sessions.last
    }

    private var resolvedSplitLayout: HostTerminalStateStore.SplitPaneLayout {
        splitLayout ?? .defaultTrailing
    }

    @ViewBuilder
    private func paneView(
        for session: HostTerminalSession,
        axis: HostTerminalStateStore.SplitPaneLayout.Axis
    ) -> some View {
        PersistentHostTerminalContainerView(
            session: session,
            surfaceStore: surfaceStore,
            onProcessExit: {
                onTerminalProcessExit?(session.id)
            }
        )
        .frame(
            minWidth: axis == .leadingTrailing ? 240 : nil,
            minHeight: axis == .topBottom ? 160 : nil
        )
    }

    var body: some View {
        if let activeSession {
            if let splitSession {
                if resolvedSplitLayout.axis == .topBottom {
                    VSplitView {
                        if resolvedSplitLayout.splitBeforePrimary {
                            paneView(for: splitSession, axis: .topBottom)
                            paneView(for: activeSession, axis: .topBottom)
                        } else {
                            paneView(for: activeSession, axis: .topBottom)
                            paneView(for: splitSession, axis: .topBottom)
                        }
                    }
                } else {
                    HSplitView {
                        if resolvedSplitLayout.splitBeforePrimary {
                            paneView(for: splitSession, axis: .leadingTrailing)
                            paneView(for: activeSession, axis: .leadingTrailing)
                        } else {
                            paneView(for: activeSession, axis: .leadingTrailing)
                            paneView(for: splitSession, axis: .leadingTrailing)
                        }
                    }
                }
            } else {
                paneView(for: activeSession, axis: .leadingTrailing)
            }
        }
    }
}

@MainActor
final class HostTerminalStateStore: ObservableObject {
    struct SplitPaneLayout: Equatable {
        enum Axis: Equatable {
            case leadingTrailing
            case topBottom
        }

        let axis: Axis
        let splitBeforePrimary: Bool

        static let defaultTrailing = SplitPaneLayout(
            axis: .leadingTrailing,
            splitBeforePrimary: false
        )
    }

    @Published private(set) var sessions: [HostTerminalSession] = []
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var splitSessionsByPrimaryID: [UUID: HostTerminalSession] = [:]
    @Published private(set) var splitLayoutsByPrimaryID: [UUID: SplitPaneLayout] = [:]
    @Published private(set) var sessionPresentation = HostTerminalSessionPresentation()

    let surfaceStore = HostTerminalSurfaceStore()
    private var coordinator = HostTerminalSessionCoordinator()

    var hasSessions: Bool {
        !sessions.isEmpty
    }

    @discardableResult
    func activateSession(
        key: HostTerminalSessionKey,
        directory: URL,
        customCommand: String? = nil
    ) -> HostTerminalSessionActivationResult {
        let result = coordinator.activate(key: key, directory: directory, customCommand: customCommand)
        publishSnapshot()
        return result
    }

    @discardableResult
    func activateExistingSession(sessionID: UUID) -> Bool {
        guard let session = coordinator.sessions.first(where: { $0.id == sessionID }) else {
            return false
        }

        _ = coordinator.activate(key: session.key, directory: session.directoryURL)
        publishSnapshot()
        return true
    }

    /// Ensures the primary (non-split) session that contains `sessionID` is active.
    /// If `sessionID` already refers to a primary session, it becomes active directly.
    @discardableResult
    func activatePrimarySession(containing sessionID: UUID) -> UUID? {
        if coordinator.sessions.contains(where: { $0.id == sessionID }) {
            guard activateExistingSession(sessionID: sessionID) else { return nil }
            return sessionID
        }

        guard let primarySessionID = splitSessionsByPrimaryID.first(where: { $0.value.id == sessionID })?.key else {
            return nil
        }

        guard activateExistingSession(sessionID: primarySessionID) else { return nil }
        return primarySessionID
    }

    func pruneRepoSessions(validRepoPaths: Set<String>) {
        let removedSessionIDs = coordinator.pruneRepoSessions(validRepoPaths: validRepoPaths)
        guard !removedSessionIDs.isEmpty else { return }

        for removedSessionID in removedSessionIDs {
            surfaceStore.invalidate(sessionID: removedSessionID)
            if let splitSession = splitSessionsByPrimaryID.removeValue(forKey: removedSessionID) {
                surfaceStore.invalidate(sessionID: splitSession.id)
            }
            splitLayoutsByPrimaryID.removeValue(forKey: removedSessionID)
        }

        publishSnapshot()
    }

    @discardableResult
    func handleProcessExit(for sessionID: UUID) -> Bool {
        var removed = false

        if let primarySessionID = splitSessionsByPrimaryID.first(where: { $0.value.id == sessionID })?.key {
            if let splitSession = splitSessionsByPrimaryID.removeValue(forKey: primarySessionID) {
                surfaceStore.invalidate(sessionID: splitSession.id)
                splitLayoutsByPrimaryID.removeValue(forKey: primarySessionID)
                removed = true
            }
        }

        if coordinator.remove(sessionID: sessionID) != nil {
            surfaceStore.invalidate(sessionID: sessionID)

            if let splitSession = splitSessionsByPrimaryID.removeValue(forKey: sessionID) {
                surfaceStore.invalidate(sessionID: splitSession.id)
            }
            splitLayoutsByPrimaryID.removeValue(forKey: sessionID)
            removed = true
        }

        if removed {
            publishSnapshot()
        }

        return removed
    }

    /// Handles process-exit cleanup and resolves which session should receive focus.
    /// Returns `nil` if the session was unknown/no-op.
    @discardableResult
    func handleProcessExitAndResolveFocusTarget(
        for sessionID: UUID,
        defaultHomeDirectory: URL
    ) -> UUID? {
        guard handleProcessExit(for: sessionID) else {
            return nil
        }

        if sessions.isEmpty {
            let replacement = activateSession(
                key: .defaultHome,
                directory: defaultHomeDirectory
            )
            return replacement.session.id
        }

        return activeSessionID
    }

    func splitSession(for primarySessionID: UUID?) -> HostTerminalSession? {
        guard let primarySessionID else { return nil }
        return splitSessionsByPrimaryID[primarySessionID]
    }

    func splitLayout(for primarySessionID: UUID?) -> SplitPaneLayout? {
        guard let primarySessionID else { return nil }
        return splitLayoutsByPrimaryID[primarySessionID]
    }

    @discardableResult
    func ensureSplitForActiveSession(
        preferredLayout: SplitPaneLayout = .defaultTrailing
    ) -> HostTerminalSession? {
        guard let activeSessionID else { return nil }
        return ensureSplit(
            forPrimarySessionID: activeSessionID,
            preferredLayout: preferredLayout
        )
    }

    @discardableResult
    func ensureSplit(
        forPrimarySessionID primarySessionID: UUID,
        preferredLayout: SplitPaneLayout = .defaultTrailing
    ) -> HostTerminalSession? {
        guard let primarySession = sessions.first(where: { $0.id == primarySessionID }) else {
            return nil
        }

        if let existing = splitSessionsByPrimaryID[primarySessionID] {
            if splitLayoutsByPrimaryID[primarySessionID] != preferredLayout {
                splitLayoutsByPrimaryID[primarySessionID] = preferredLayout
                objectWillChange.send()
            }
            return existing
        }

        let splitSession = HostTerminalSession(
            key: primarySession.key,
            directory: primarySession.directoryURL
        )
        splitSessionsByPrimaryID[primarySessionID] = splitSession
        splitLayoutsByPrimaryID[primarySessionID] = preferredLayout
        objectWillChange.send()
        return splitSession
    }

    /// Computes the target session for split focus navigation in our current
    /// two-pane split model (primary + optional split with direction-aware layout).
    func splitFocusTarget(
        from sourceSessionID: UUID,
        direction: GhosttyAppManager.SplitFocusDirection
    ) -> UUID? {
        guard let primarySessionID = activatePrimarySession(containing: sourceSessionID),
            let splitSession = splitSessionsByPrimaryID[primarySessionID]
        else {
            return nil
        }

        let layout = splitLayoutsByPrimaryID[primarySessionID] ?? .defaultTrailing
        let sourceIsSplit = splitSession.id == sourceSessionID

        switch direction {
        case .previous, .next:
            return sourceIsSplit ? primarySessionID : splitSession.id

        case .left:
            guard layout.axis == .leadingTrailing else { return nil }
            if layout.splitBeforePrimary {
                return sourceIsSplit ? nil : splitSession.id
            }
            return sourceIsSplit ? primarySessionID : nil

        case .right:
            guard layout.axis == .leadingTrailing else { return nil }
            if layout.splitBeforePrimary {
                return sourceIsSplit ? primarySessionID : nil
            }
            return sourceIsSplit ? nil : splitSession.id

        case .up:
            guard layout.axis == .topBottom else { return nil }
            if layout.splitBeforePrimary {
                return sourceIsSplit ? nil : splitSession.id
            }
            return sourceIsSplit ? primarySessionID : nil

        case .down:
            guard layout.axis == .topBottom else { return nil }
            if layout.splitBeforePrimary {
                return sourceIsSplit ? primarySessionID : nil
            }
            return sourceIsSplit ? nil : splitSession.id
        }
    }

    private func publishSnapshot() {
        sessions = coordinator.sessions
        activeSessionID = coordinator.activeSessionID
        sessionPresentation = coordinator.presentation

        let validPrimaryIDs = Set(sessions.map(\.id))
        let stalePrimaryIDs = splitSessionsByPrimaryID.keys.filter { !validPrimaryIDs.contains($0) }
        for primaryID in stalePrimaryIDs {
            if let splitSession = splitSessionsByPrimaryID.removeValue(forKey: primaryID) {
                surfaceStore.invalidate(sessionID: splitSession.id)
            }
            splitLayoutsByPrimaryID.removeValue(forKey: primaryID)
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
