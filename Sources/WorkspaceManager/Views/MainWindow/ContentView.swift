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
    @State private var isRightPaneVisible = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pendingRepoFocusMeasurementSessionID: UUID?
    @State private var didRunPerfAutoSelection = false
    private let resolvedDefaultHostDirectory = HostTerminalDefaults.defaultWorkingDirectory()
        .standardizedFileURL
        .resolvingSymlinksInPath()

    private var sessionPresentation: HostTerminalSessionPresentation {
        hostTerminalState.sessionPresentation
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
                onRepoSelected: handleRepoSelection
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 350)
        } detail: {
            MainTerminalDetailView(
                selectedWorkspace: selectedWorkspace,
                hostTerminalSessions: hostTerminalState.sessions,
                activeHostTerminalSessionID: hostTerminalState.activeSessionID,
                activeSplitHostSession: hostTerminalState.splitSession(for: hostTerminalState.activeSessionID),
                hostSurfaceStore: hostTerminalState.surfaceStore,
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
                .disabled(selectedWorkspace == nil)
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
        .onReceive(NotificationCenter.default.publisher(for: GhosttyAppManager.splitRequestNotification)) { notification in
            Task { @MainActor in
                handleGhosttySplitRequest(notification)
            }
        }
        .focusedSceneValue(\.toggleSidebarAction, toggleSidebarVisibility)
        .focusedSceneValue(\.splitTerminalAction, splitFocusedTerminal)
    }

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
    private func splitFocusedTerminal() {
        createAndFocusSplitForActiveSession()
    }

    @MainActor
    private func handleGhosttySplitRequest(_ notification: Notification) {
        if let sourceTerminal = notification.object as? GhosttySurfaceView,
            let sourceSessionID = hostTerminalState.surfaceStore.sessionID(for: sourceTerminal)
        {
            _ = hostTerminalState.activateExistingSession(sessionID: sourceSessionID)
        }

        createAndFocusSplitForActiveSession()
    }

    @MainActor
    private func createAndFocusSplitForActiveSession() {
        guard let splitSession = hostTerminalState.ensureSplitForActiveSession() else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Task { @MainActor in
                guard let splitTerminal = hostTerminalState.surfaceStore.terminal(for: splitSession.id) else { return }
                TerminalFocusManager.shared.requestFocus(for: splitTerminal)
            }
        }
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
        onTargetFocused: (() -> Void)? = nil
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first(where: \.isVisible) ?? NSApp.windows.first
        window?.makeKeyAndOrderFront(nil)

        if let targetSessionID,
            let terminal = hostTerminalState.surfaceStore.terminal(for: targetSessionID)
        {
            TerminalFocusManager.shared.requestFocus(
                for: terminal,
                onFocused: onTargetFocused
            )
            return
        }

        if let activeSessionID = hostTerminalState.activeSessionID,
            let terminal = hostTerminalState.surfaceStore.terminal(for: activeSessionID)
        {
            TerminalFocusManager.shared.requestFocus(for: terminal)
            return
        }

        if let terminal = TerminalFocusManager.shared.focusedTerminal {
            TerminalFocusManager.shared.requestFocus(for: terminal)
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
    let hostTerminalSessions: [HostTerminalSession]
    let activeHostTerminalSessionID: UUID?
    let activeSplitHostSession: HostTerminalSession?
    let hostSurfaceStore: HostTerminalSurfaceStore
    @Binding var isRightPaneVisible: Bool

    private var activeHostSession: HostTerminalSession? {
        guard let activeHostTerminalSessionID else { return hostTerminalSessions.last }
        return hostTerminalSessions.first(where: { $0.id == activeHostTerminalSessionID }) ?? hostTerminalSessions.last
    }

    var body: some View {
        HSplitView {
            // Main terminal panel
            HostTerminalSessionStack(
                sessions: hostTerminalSessions,
                activeSessionID: activeHostTerminalSessionID,
                splitSession: activeSplitHostSession,
                surfaceStore: hostSurfaceStore
            )
            .frame(minWidth: 400)

            // Collapsible right pane
            if isRightPaneVisible, let selectedWorkspace {
                RightPaneView(workspace: selectedWorkspace)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
            }
        }
        .navigationTitle(selectedWorkspace?.name ?? "Host")
        .navigationSubtitle(selectedWorkspace?.sourceRepo?.name ?? (activeHostSession?.directoryPath ?? ""))
    }
}

struct HostTerminalSessionStack: View {
    let sessions: [HostTerminalSession]
    let activeSessionID: UUID?
    let splitSession: HostTerminalSession?
    let surfaceStore: HostTerminalSurfaceStore

    private var activeSession: HostTerminalSession? {
        guard let activeSessionID else { return sessions.last }
        return sessions.first(where: { $0.id == activeSessionID }) ?? sessions.last
    }

    var body: some View {
        if let activeSession {
            if let splitSession {
                HSplitView {
                    PersistentHostTerminalContainerView(
                        session: activeSession,
                        surfaceStore: surfaceStore
                    )
                    .frame(minWidth: 240)

                    PersistentHostTerminalContainerView(
                        session: splitSession,
                        surfaceStore: surfaceStore
                    )
                    .frame(minWidth: 240)
                }
            } else {
                PersistentHostTerminalContainerView(
                    session: activeSession,
                    surfaceStore: surfaceStore
                )
            }
        }
    }
}

@MainActor
final class HostTerminalStateStore: ObservableObject {
    @Published private(set) var sessions: [HostTerminalSession] = []
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var splitSessionsByPrimaryID: [UUID: HostTerminalSession] = [:]
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

    func pruneRepoSessions(validRepoPaths: Set<String>) {
        let removedSessionIDs = coordinator.pruneRepoSessions(validRepoPaths: validRepoPaths)
        guard !removedSessionIDs.isEmpty else { return }

        for removedSessionID in removedSessionIDs {
            surfaceStore.invalidate(sessionID: removedSessionID)
            if let splitSession = splitSessionsByPrimaryID.removeValue(forKey: removedSessionID) {
                surfaceStore.invalidate(sessionID: splitSession.id)
            }
        }

        publishSnapshot()
    }

    func splitSession(for primarySessionID: UUID?) -> HostTerminalSession? {
        guard let primarySessionID else { return nil }
        return splitSessionsByPrimaryID[primarySessionID]
    }

    @discardableResult
    func ensureSplitForActiveSession() -> HostTerminalSession? {
        guard let activeSessionID,
            let primarySession = sessions.first(where: { $0.id == activeSessionID })
        else {
            return nil
        }

        if let existing = splitSessionsByPrimaryID[activeSessionID] {
            return existing
        }

        let splitSession = HostTerminalSession(
            key: primarySession.key,
            directory: primarySession.directoryURL
        )
        splitSessionsByPrimaryID[activeSessionID] = splitSession
        objectWillChange.send()
        return splitSession
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
