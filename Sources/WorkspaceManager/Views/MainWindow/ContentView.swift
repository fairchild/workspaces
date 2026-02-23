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
    @Binding var deepLinkState: WorkspaceDeepLinkState
    @ObservedObject var hostTerminalState: HostTerminalStateStore
    @Query(sort: \Repo.addedAt, order: .reverse) private var repos: [Repo]

    @State private var selectedWorkspace: Workspace?
    @State private var selectedCodePreview: CodePreviewSelection?
    @State private var isTerminalPanelVisible = true
    @State private var isRightPaneVisible = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pendingRepoFocusMeasurementSessionID: UUID?
    @State private var didRunPerfAutoSelection = false
    private let resolvedDefaultHostDirectory = HostTerminalDefaults.defaultWorkingDirectory()
        .standardizedFileURL
        .resolvingSymlinksInPath()

    private var sessionPresentation: HostTerminalSessionPresentation {
        hostTerminalState.sessionPresentation
    }

    private var selectedRepoForInspector: Repo? {
        guard selectedWorkspace == nil,
            let activeRepoPath = sessionPresentation.activeRepoPath
        else {
            return nil
        }

        let normalizedActiveRepoPath = normalizePath(activeRepoPath)
        return repos.first { normalizePath($0.localPath) == normalizedActiveRepoPath }
    }

    private var hasInspectorTarget: Bool {
        selectedWorkspace != nil || selectedRepoForInspector != nil
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                repos: repos,
                selectedWorkspace: $selectedWorkspace,
                defaultHostPath: resolvedDefaultHostDirectory.path,
                hasDefaultHostSession: sessionPresentation.hasDefaultHomeSession,
                isDefaultHostSessionActive: sessionPresentation.isDefaultHomeSessionActive,
                liveRepoPaths: sessionPresentation.liveRepoPaths,
                activeRepoPath: sessionPresentation.activeRepoPath,
                onDefaultHostSelected: handleDefaultHostSelection,
                onRepoSelected: handleRepoSelection,
                onWorkspaceCreated: handleWorkspaceCreated
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 350)
        } detail: {
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
                isRightPaneVisible: $isRightPaneVisible
            )
        }
        .toolbar {
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
        .onAppear {
            ensureInitialHostSession()
            processPendingDeepLink()
            maybeAutoSelectRepoForPerf()
        }
        .onChange(of: deepLinkState.pendingRequest) { _, _ in
            processPendingDeepLink()
        }
        .onChange(of: repos.count) { _, _ in
            processPendingDeepLink()
            maybeAutoSelectRepoForPerf()
        }
        .onChange(of: repos.map { normalizePath($0.localPath) }) { _, paths in
            hostTerminalState.pruneRepoSessions(validRepoPaths: Set(paths))
        }
        .onChange(of: selectedWorkspace?.id) { _, _ in
            guard let selectedWorkspace else { return }
            handleWorkspaceSelection(selectedWorkspace)
        }
        .onReceive(NotificationCenter.default.publisher(for: GhosttyAppManager.splitActionNotification)) {
            notification in
            Task { @MainActor in
                handleGhosttySplitAction(notification)
            }
        }
        .focusedSceneValue(\.toggleSidebarAction, toggleSidebarVisibility)
        .focusedSceneValue(\.toggleInspectorAction, toggleInspectorVisibility)
        .focusedSceneValue(\.toggleTerminalPanelAction, toggleTerminalPanelVisibility)
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
    private func handleRepoSelection(_ repo: Repo) {
        let repoDirectory = repo.localURL.standardizedFileURL.resolvingSymlinksInPath()

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
        clearCodePreview()
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

    @MainActor
    private func handleWorkspaceCreated() {
        guard selectedWorkspace == nil else { return }
        isRightPaneVisible = false
    }

    @MainActor
    private func handleTerminalProcessExit(sessionID: UUID) {
        NSLog("[HostSession] Process exit detected for session %@", sessionID.uuidString)
        guard hostTerminalState.handleProcessExit(for: sessionID) else {
            return
        }

        if hostTerminalState.sessions.isEmpty {
            let replacementSession = activateHostSession(
                key: .defaultHome,
                directory: resolvedDefaultHostDirectory
            )
            requestMainTerminalFocus(
                targetSessionID: replacementSession.id,
                activateApp: false
            )
            return
        }

        requestMainTerminalFocus(
            targetSessionID: hostTerminalState.activeSessionID,
            activateApp: false
        )
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

    private func handleCodePreviewSelection(_ selection: CodePreviewSelection) {
        selectedCodePreview = selection
        isTerminalPanelVisible = true
    }

    private func clearCodePreview() {
        selectedCodePreview = nil
        isTerminalPanelVisible = true
    }

    @MainActor
    private func handleGhosttySplitAction(_ notification: Notification) {
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
    private func activateHostSession(key: HostTerminalSessionKey, directory: URL) -> HostTerminalSession {
        let result = hostTerminalState.activateSession(
            key: key,
            directory: directory
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
    @Binding var isRightPaneVisible: Bool

    private var activeHostSession: HostTerminalSession? {
        guard let activeHostTerminalSessionID else { return hostTerminalSessions.last }
        return hostTerminalSessions.first(where: { $0.id == activeHostTerminalSessionID }) ?? hostTerminalSessions.last
    }

    var body: some View {
        HSplitView {
            previewAndTerminalPanel
            .frame(minWidth: 400)

            // Collapsible right pane
            if isRightPaneVisible {
                if let selectedWorkspace {
                    RightPaneView(
                        workspace: selectedWorkspace,
                        onFileSelected: onFileSelected
                    )
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
                } else if let selectedRepo {
                    RightPaneView(
                        repo: selectedRepo,
                        onFileSelected: onFileSelected
                    )
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
                }
            }
        }
        .navigationTitle(selectedWorkspace?.name ?? "Host")
        .navigationSubtitle(selectedWorkspace?.sourceRepo?.name ?? (activeHostSession?.directoryPath ?? ""))
    }

    @ViewBuilder
    private var previewAndTerminalPanel: some View {
        if let selectedCodePreview {
            if isTerminalPanelVisible {
                VSplitView {
                    CodeFilePreviewView(selection: selectedCodePreview) {
                        self.selectedCodePreview = nil
                        self.isTerminalPanelVisible = true
                    }
                    .frame(minHeight: 220)

                    hostTerminalPanel
                        .frame(minHeight: 160)
                }
            } else {
                CodeFilePreviewView(selection: selectedCodePreview) {
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
        directory: URL
    ) -> HostTerminalSessionActivationResult {
        let result = coordinator.activate(key: key, directory: directory)
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
        .modelContainer(for: [Repo.self, Workspace.self], inMemory: true)
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
