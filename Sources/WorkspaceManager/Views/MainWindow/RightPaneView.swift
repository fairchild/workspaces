//
//  RightPaneView.swift
//  WorkspaceManager
//
//  Collapsible Detail Pane with Files, Changes, Timeline, Activity, and Diagnostics tabs.
//

import AppKit
import SwiftUI
import WorkspaceManagerCore

struct RightPaneTabPolicy {
    let supportsFilesystemInspection: Bool
    let showTimeline: Bool
    let showActivity: Bool
    let notificationsEnabled: Bool

    var visibleTabs: [RightPaneView.Tab] {
        var tabs: [RightPaneView.Tab] = [.files]
        if supportsFilesystemInspection {
            tabs.append(.changes)
        }

        if showTimeline {
            tabs.append(.timeline)
        }

        let canShowActivity = showActivity && notificationsEnabled
        if canShowActivity {
            tabs.append(.activity)
        }

        tabs.append(.diagnostics)
        return tabs
    }

    func normalizedSelection(for selectedTab: RightPaneView.Tab) -> RightPaneView.Tab {
        if visibleTabs.contains(selectedTab) {
            return selectedTab
        }
        return visibleTabs[0]
    }
}

struct RightPaneWidth: Equatable {
    let minimum: CGFloat
    let ideal: CGFloat
    let maximum: CGFloat
}

struct RightPaneWidthPolicy {
    func width(for selectedTab: RightPaneView.Tab) -> RightPaneWidth {
        selectedTab == .diagnostics
            ? RightPaneWidth(minimum: 360, ideal: 640, maximum: 760)
            : RightPaneWidth(minimum: 220, ideal: 280, maximum: 400)
    }
}

private struct RightPaneWidthModifier: ViewModifier {
    @ObservedObject var state: RightPaneSessionState
    private let policy = RightPaneWidthPolicy()

    func body(content: Content) -> some View {
        let width = policy.width(for: state.selectedTab)
        content.frame(
            minWidth: width.minimum,
            idealWidth: width.ideal,
            maxWidth: width.maximum
        )
    }
}

extension View {
    func rightPaneWidth(for state: RightPaneSessionState) -> some View {
        modifier(RightPaneWidthModifier(state: state))
    }
}

@MainActor
final class RightPaneSessionState: ObservableObject {
    @Published var selectedTab: RightPaneView.Tab = .files
    @Published var fileTree: FileNode?
    @Published var changedFiles: [FileChange] = []
    @Published var isLoading = false
    @Published var lastRefresh = Date()
    @Published var timelineLastRefresh: Date?
    @Published var expandedDirectoryPaths: Set<String> = []
    @Published var hasLoadedOnce = false
}

@MainActor
final class RightPaneStateStore: ObservableObject {
    private var states: [String: RightPaneSessionState] = [:]

    func state(for targetID: String) -> RightPaneSessionState {
        if let existing = states[targetID] {
            return existing
        }
        let created = RightPaneSessionState()
        states[targetID] = created
        return created
    }

    func state(for workspace: Workspace) -> RightPaneSessionState {
        state(for: "workspace-\(workspace.id.uuidString)")
    }

    func state(for repo: Repo) -> RightPaneSessionState {
        state(for: "repo-\(repo.id.uuidString)")
    }

    func prune(keeping validTargetIDs: Set<String>) {
        guard !states.isEmpty else { return }
        states = states.filter { validTargetIDs.contains($0.key) }
    }
}

struct RightPaneView: View {
    let targetID: String
    let directoryURL: URL?
    let onFileSelected: (CodePreviewSelection) -> Void
    let diagnosticWorkspaceDirectories: [URL]
    let agentStatuses: [AgentSessionStatus]
    private let workspaceID: UUID?
    private let timelineHostSessionID: UUID?
    private let showTimeline: Bool
    private let showActivity: Bool
    private let supportsFilesystemInspection: Bool

    @AppStorage(NotificationConstants.enabledKey)
    private var notificationsEnabled = NotificationConstants.defaultEnabled
    @Environment(\.gitService) private var gitService
    @EnvironmentObject private var workspaceJournal: WorkspaceJournal
    @ObservedObject private var state: RightPaneSessionState
    @ObservedObject private var notificationCoordinator = NotificationCoordinator.shared

    enum Tab: String, CaseIterable {
        case files = "Files"
        case changes = "Changes"
        case timeline = "Timeline"
        case activity = "Activity"
        case diagnostics = "Diagnostics"

        var icon: String {
            switch self {
            case .files: return "folder"
            case .changes: return "arrow.triangle.2.circlepath"
            case .timeline: return "clock"
            case .activity: return "bell"
            case .diagnostics: return "waveform.path.ecg"
            }
        }
    }

    init(
        workspace: Workspace,
        state: RightPaneSessionState,
        diagnosticWorkspaceDirectories: [URL] = [],
        agentStatuses: [AgentSessionStatus] = [],
        timelineHostSessionID: UUID? = nil,
        onFileSelected: @escaping (CodePreviewSelection) -> Void = { _ in }
    ) {
        self.targetID = "workspace-\(workspace.id.uuidString)"
        self.directoryURL = workspace.localDirectoryURL
        self.state = state
        self.onFileSelected = onFileSelected
        self.diagnosticWorkspaceDirectories = diagnosticWorkspaceDirectories
        self.agentStatuses = agentStatuses
        self.workspaceID = workspace.id
        self.timelineHostSessionID = timelineHostSessionID
        self.showTimeline = true
        self.showActivity = true
        self.supportsFilesystemInspection = workspace.localDirectoryURL != nil
    }

    init(
        repo: Repo,
        state: RightPaneSessionState,
        diagnosticWorkspaceDirectories: [URL] = [],
        agentStatuses: [AgentSessionStatus] = [],
        onFileSelected: @escaping (CodePreviewSelection) -> Void = { _ in }
    ) {
        self.targetID = "repo-\(repo.id.uuidString)"
        self.directoryURL = repo.localURL
        self.state = state
        self.onFileSelected = onFileSelected
        self.diagnosticWorkspaceDirectories = diagnosticWorkspaceDirectories
        self.agentStatuses = agentStatuses
        self.workspaceID = nil
        self.timelineHostSessionID = nil
        self.showTimeline = false
        self.showActivity = false
        self.supportsFilesystemInspection = true
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Detail Pane")
                            .font(.headline)

                        Text(summaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let badge = badgeCount(for: displayedTab), badge > 0 {
                        Text("\(badge)")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }

                Picker("Detail Pane Tab", selection: selectedTabBinding) {
                    ForEach(visibleTabs, id: \.self) { tab in
                        Text(tab.rawValue)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ZStack {
                switch displayedTab {
                case .files:
                    FileTreeTabView(
                        root: state.fileTree,
                        isLoading: state.isLoading,
                        expandedDirectoryPaths: $state.expandedDirectoryPaths,
                        onFileSelected: selectFile
                    )
                case .changes:
                    ChangedFilesTabView(
                        changes: state.changedFiles,
                        isLoading: state.isLoading,
                        onFileSelected: reviewFile
                    )
                case .timeline:
                    TimelineTabView(
                        events: timelineEvents,
                        hasHostSession: timelineHostSessionID != nil
                    )
                case .activity:
                    ActivityTabView(
                        events: notificationCoordinator.events,
                        isConnected: notificationCoordinator.isStreamConnected,
                        authState: notificationCoordinator.authState
                    )
                case .diagnostics:
                    DiagnosticsTabView(
                        workspaceDirectories: diagnosticWorkspaceDirectories,
                        agentStatuses: agentStatuses
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if displayedTab == .activity {
                    Circle()
                        .fill(notificationCoordinator.isStreamConnected ? Color.mint : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(notificationCoordinator.isStreamConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if displayedTab == .diagnostics {
                    Circle()
                        .fill(Color.mint)
                        .frame(width: 6, height: 6)
                    Text("Sampling while open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(
                            "Diagnostics starts a 5-second in-memory process sampler only while this tab is visible. Trace counts come from existing telemetry; process samples are not persisted."
                        )
                } else if displayedTab == .timeline {
                    Circle()
                        .fill(timelineHostSessionID == nil ? Color.secondary : Color.mint)
                        .frame(width: 6, height: 6)
                    Text(timelineFooterText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Updated \(state.lastRefresh.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if supportsRefresh {
                    Button {
                        Task { await refreshDisplayedTab() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(state.isLoading || (displayedTab == .timeline && timelineHostSessionID == nil))
                    .help("Refresh")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .task(id: targetID) {
            normalizeSelectedTab()
            if supportsFilesystemInspection, !state.hasLoadedOnce || state.fileTree == nil {
                await refresh()
            }
        }
        .task(id: timelineRefreshKey) {
            await refreshTimelineIfNeeded()
        }
        .onChange(of: notificationsEnabled) { _, _ in
            normalizeSelectedTab()
        }
    }

    private var tabPolicy: RightPaneTabPolicy {
        RightPaneTabPolicy(
            supportsFilesystemInspection: supportsFilesystemInspection,
            showTimeline: showTimeline,
            showActivity: showActivity,
            notificationsEnabled: notificationsEnabled
        )
    }

    private var visibleTabs: [Tab] {
        tabPolicy.visibleTabs
    }

    private var displayedTab: Tab {
        tabPolicy.normalizedSelection(for: state.selectedTab)
    }

    private var selectedTabBinding: Binding<Tab> {
        Binding(
            get: { displayedTab },
            set: { nextTab in
                state.selectedTab = nextTab
                if nextTab == .activity {
                    notificationCoordinator.markActivitySeen()
                }
            }
        )
    }

    private func badgeCount(for tab: Tab) -> Int? {
        switch tab {
        case .files: return nil
        case .changes:
            let count = state.changedFiles.count
            return count > 0 ? count : nil
        case .timeline:
            let count = timelineEvents.count
            return count > 0 ? count : nil
        case .activity:
            let count = notificationCoordinator.unseenEventCount
            return count > 0 ? count : nil
        case .diagnostics:
            return nil
        }
    }

    @MainActor
    private func normalizeSelectedTab() {
        let normalizedTab = tabPolicy.normalizedSelection(for: state.selectedTab)
        guard state.selectedTab != normalizedTab else { return }
        state.selectedTab = normalizedTab
        if state.selectedTab == .activity {
            notificationCoordinator.markActivitySeen()
        }
    }

    @MainActor
    private func refresh() async {
        guard supportsFilesystemInspection else {
            state.fileTree = nil
            state.changedFiles = []
            state.hasLoadedOnce = true
            state.lastRefresh = Date()
            return
        }

        state.isLoading = true
        defer {
            state.isLoading = false
            state.lastRefresh = Date()
            state.hasLoadedOnce = true
        }

        async let treeTask = loadFileTree()
        async let statusTask = loadGitStatus()

        let (fileTree, changedFiles) = await (treeTask, statusTask)
        state.fileTree = fileTree
        state.changedFiles = changedFiles
    }

    private func loadFileTree() async -> FileNode? {
        guard let directoryURL else { return nil }
        do {
            return try await gitService.getFileTree(at: directoryURL)
        } catch {
            print("Failed to load file tree: \(error)")
            return nil
        }
    }

    private func loadGitStatus() async -> [FileChange] {
        guard let directoryURL else { return [] }
        do {
            return try await gitService.getStatus(at: directoryURL)
        } catch {
            print("Failed to load git status: \(error)")
            return []
        }
    }

    private func selectFile(relativePath: String) {
        select(relativePath: relativePath, mode: .read)
    }

    private func reviewFile(relativePath: String) {
        select(relativePath: relativePath, mode: .reviewDiff)
    }

    private func select(relativePath: String, mode: PreviewMode) {
        guard !relativePath.isEmpty, let directoryURL else { return }
        onFileSelected(
            CodePreviewSelection(
                rootURL: directoryURL,
                relativePath: relativePath,
                mode: mode
            )
        )
    }

    private var summaryText: String {
        switch displayedTab {
        case .files:
            guard supportsFilesystemInspection else {
                return "Files are available only for local workspaces"
            }
            if state.isLoading {
                return "Refreshing file tree"
            }
            if let itemCount = state.fileTree?.children?.count, itemCount > 0 {
                return "\(itemCount) top-level items"
            }
            return "Browse files in this context"
        case .changes:
            guard supportsFilesystemInspection else {
                return "Git changes are available only for local workspaces"
            }
            if state.isLoading {
                return "Refreshing working tree"
            }
            let changeCount = state.changedFiles.count
            if changeCount == 0 {
                return "Working tree clean"
            }
            return "\(changeCount) changed file\(changeCount == 1 ? "" : "s")"
        case .timeline:
            guard timelineHostSessionID != nil else {
                return "Open a workspace terminal to collect agent events"
            }
            let eventCount = timelineEvents.count
            if eventCount == 0 {
                return "No agent events yet"
            }
            return "\(eventCount) workspace event\(eventCount == 1 ? "" : "s")"
        case .activity:
            if notificationCoordinator.unseenEventCount > 0 {
                return "\(notificationCoordinator.unseenEventCount) unseen updates"
            }
            return notificationCoordinator.isStreamConnected
                ? "Live GitHub activity"
                : "GitHub activity stream disconnected"
        case .diagnostics:
            return "Runtime health and process history"
        }
    }

    private var supportsRefresh: Bool {
        switch displayedTab {
        case .files, .changes:
            return supportsFilesystemInspection
        case .timeline:
            return true
        case .activity, .diagnostics:
            return false
        }
    }

    private var timelineEvents: [WorkspaceEvent] {
        guard let workspaceID else { return [] }
        return workspaceJournal.events(for: workspaceID)
    }

    private var timelineFooterText: String {
        guard timelineHostSessionID != nil else {
            return "No workspace terminal session"
        }
        if let refreshed = state.timelineLastRefresh {
            return "Updated \(refreshed.formatted(.relative(presentation: .named)))"
        }
        return "Timeline ready"
    }

    private var latestTimelineAgentEventAt: Date? {
        guard let timelineHostSessionID else { return nil }
        return
            agentStatuses
            .filter { $0.hostSessionID == timelineHostSessionID }
            .map(\.lastEventAt)
            .max()
    }

    private var timelineRefreshKey: TimelineRefreshKey {
        TimelineRefreshKey(
            targetID: targetID,
            selectedTab: displayedTab,
            hostSessionID: timelineHostSessionID,
            latestAgentEventAt: latestTimelineAgentEventAt
        )
    }

    @MainActor
    private func refreshDisplayedTab() async {
        switch displayedTab {
        case .files, .changes:
            await refresh()
        case .timeline:
            await refreshTimelineIfNeeded(force: true)
        case .activity, .diagnostics:
            break
        }
    }

    @MainActor
    private func refreshTimelineIfNeeded(force: Bool = false) async {
        guard displayedTab == .timeline || force,
            let workspaceID,
            let timelineHostSessionID
        else { return }

        await workspaceJournal.refresh(
            workspaceID: workspaceID,
            hostSessionID: timelineHostSessionID
        )
        state.timelineLastRefresh = Date()
    }
}

private struct TimelineRefreshKey: Equatable {
    let targetID: String
    let selectedTab: RightPaneView.Tab
    let hostSessionID: UUID?
    let latestAgentEventAt: Date?
}

// MARK: - Files Tab

struct FileTreeTabView: View {
    let root: FileNode?
    let isLoading: Bool
    @Binding var expandedDirectoryPaths: Set<String>
    let onFileSelected: (String) -> Void

    var body: some View {
        if let root {
            List {
                ForEach(root.children ?? [], id: \.path) { child in
                    FileNodeView(
                        node: child,
                        expandedDirectoryPaths: $expandedDirectoryPaths,
                        onFileSelected: onFileSelected
                    )
                }
            }
            .listStyle(.plain)
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Files",
                systemImage: "folder",
                description: Text("Could not load file tree")
            )
        }
    }
}

struct FileNodeView: View {
    let node: FileNode
    @Binding var expandedDirectoryPaths: Set<String>
    let onFileSelected: (String) -> Void

    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: { expandedDirectoryPaths.contains(node.path) },
            set: { shouldExpand in
                if shouldExpand {
                    expandedDirectoryPaths.insert(node.path)
                } else {
                    expandedDirectoryPaths.remove(node.path)
                }
            }
        )
    }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: isExpandedBinding) {
                ForEach(node.children ?? [], id: \.path) { child in
                    FileNodeView(
                        node: child,
                        expandedDirectoryPaths: $expandedDirectoryPaths,
                        onFileSelected: onFileSelected
                    )
                }
            } label: {
                Label(node.name, systemImage: "folder.fill")
                    .foregroundStyle(.primary)
            }
        } else {
            Button {
                onFileSelected(node.path)
            } label: {
                Label(node.name, systemImage: node.icon)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Changes Tab

struct ChangedFilesTabView: View {
    let changes: [FileChange]
    let isLoading: Bool
    let onFileSelected: (String) -> Void

    var body: some View {
        if changes.isEmpty && !isLoading {
            ContentUnavailableView(
                "No Changes",
                systemImage: "checkmark.circle",
                description: Text("Working directory is clean")
            )
        } else {
            List(changes) { change in
                Button {
                    onFileSelected(change.path)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: change.status.icon)
                            .foregroundStyle(change.status.color)
                            .frame(width: 16)

                        Text(change.path)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Timeline Tab

struct WorkspaceTimelinePresentation: Equatable {
    enum Tone: Equatable {
        case neutral
        case running
        case attention
        case critical
        case success

        var color: Color {
            switch self {
            case .neutral:
                return .secondary
            case .running:
                return .blue
            case .attention:
                return .yellow
            case .critical:
                return .red
            case .success:
                return .mint
            }
        }
    }

    let title: String
    let detail: String
    let systemImage: String
    let tone: Tone

    static func event(_ event: WorkspaceEvent) -> WorkspaceTimelinePresentation {
        switch event.kind {
        case .started:
            return WorkspaceTimelinePresentation(
                title: "Agent started",
                detail: "Workspace session began",
                systemImage: "play.circle",
                tone: .running
            )
        case .stateTransition(_, let runState):
            return runStatePresentation(runState)
        case .toolRun(let name):
            return WorkspaceTimelinePresentation(
                title: "Ran \(name)",
                detail: "Tool execution",
                systemImage: "hammer",
                tone: .running
            )
        case .error(let category, let message):
            return WorkspaceTimelinePresentation(
                title: errorTitle(for: category),
                detail: errorDetail(message),
                systemImage: "exclamationmark.triangle",
                tone: .critical
            )
        case .completed:
            return WorkspaceTimelinePresentation(
                title: "Agent completed",
                detail: "Workspace session finished",
                systemImage: "checkmark.circle",
                tone: .success
            )
        }
    }

    private static func runStatePresentation(_ state: AgentRunState) -> WorkspaceTimelinePresentation {
        let projection = AgentChromeProjection.runState(state)
        switch state {
        case .idle:
            return WorkspaceTimelinePresentation(
                title: "Agent idle",
                detail: projection.summaryText,
                systemImage: "pause.circle",
                tone: .neutral
            )
        case .thinking:
            return WorkspaceTimelinePresentation(
                title: "Agent thinking",
                detail: projection.summaryText,
                systemImage: "brain.head.profile",
                tone: .running
            )
        case .runningTool:
            return WorkspaceTimelinePresentation(
                title: projection.summaryText,
                detail: "Tool execution",
                systemImage: "hammer",
                tone: .running
            )
        case .awaitingInput:
            return WorkspaceTimelinePresentation(
                title: "Agent needs input",
                detail: projection.summaryText,
                systemImage: "hand.raised",
                tone: .attention
            )
        case .complete:
            return WorkspaceTimelinePresentation(
                title: "Agent completed",
                detail: projection.summaryText,
                systemImage: "checkmark.circle",
                tone: .success
            )
        case .errored:
            return WorkspaceTimelinePresentation(
                title: projection.summaryText,
                detail: "Agent reported an error",
                systemImage: "exclamationmark.triangle",
                tone: .critical
            )
        }
    }

    private static func errorTitle(for category: AgentErrorCategory) -> String {
        switch category {
        case .rateLimit:
            return "Rate limited"
        case .authentication:
            return "Authentication error"
        case .server:
            return "Server error"
        case .toolFailure:
            return "Tool failed"
        case .unknown:
            return "Agent error"
        }
    }

    private static func errorDetail(_ message: String?) -> String {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        else {
            return "Agent reported an error"
        }
        return message
    }
}

struct TimelineTabView: View {
    let events: [WorkspaceEvent]
    let hasHostSession: Bool

    var body: some View {
        if !hasHostSession {
            ContentUnavailableView(
                "No Timeline",
                systemImage: "clock",
                description: Text("Open this workspace's terminal to connect agent events to the Timeline.")
            )
        } else if events.isEmpty {
            ContentUnavailableView(
                "No Timeline Events",
                systemImage: "clock",
                description: Text("Agent run state changes will appear here.")
            )
        } else {
            List(events) { event in
                WorkspaceTimelineEventRow(event: event)
            }
            .listStyle(.plain)
        }
    }
}

struct WorkspaceTimelineEventRow: View {
    let event: WorkspaceEvent

    var body: some View {
        let presentation = WorkspaceTimelinePresentation.event(event)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(presentation.tone.color)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.callout)
                    .lineLimit(2)

                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(event.timestamp.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Activity Tab

struct ActivityTabView: View {
    let events: [WebhookEvent]
    let isConnected: Bool
    let authState: NotificationAuthState
    @AppStorage(NotificationConstants.enabledKey)
    private var notificationsEnabled = NotificationConstants.defaultEnabled
    @ObservedObject private var notificationCoordinator = NotificationCoordinator.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        if case .signedIn(let login) = authState {
            if !notificationsEnabled {
                ContentUnavailableView {
                    Label("Notifications Disabled", systemImage: "bell.slash")
                } description: {
                    Text("Connected as \(login). Enable notifications in Settings to show live GitHub activity here.")
                } actions: {
                    SettingsLink {
                        Text("Open Settings")
                    }
                }
            } else if events.isEmpty {
                ContentUnavailableView(
                    "No Events Yet",
                    systemImage: isConnected ? "clock" : "bell.badge",
                    description: Text(
                        isConnected
                            ? "Live GitHub activity will appear here."
                            : "GitHub is signed in, but the activity stream is not connected yet."
                    )
                )
            } else {
                List(events) { event in
                    EventRow(event: event)
                }
                .listStyle(.plain)
            }
        } else {
            authenticationStateView
        }
    }

    @ViewBuilder
    private var authenticationStateView: some View {
        switch authState {
        case .signedOut:
            ContentUnavailableView {
                Label("Connect GitHub", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text(
                    notificationsEnabled
                        ? "Sign in to see pull requests, checks, and other repository activity here."
                        : "Sign in to link your GitHub account. Enable notifications in Settings to see live activity here."
                )
            } actions: {
                VStack(spacing: 10) {
                    Button("Connect GitHub") {
                        Task { await notificationCoordinator.startDeviceFlow() }
                    }
                    .buttonStyle(.borderedProminent)

                    if !notificationsEnabled {
                        SettingsLink {
                            Text("Open Settings")
                        }
                    }
                }
            }

        case .requestingCode:
            ContentUnavailableView {
                Label("Connecting GitHub", systemImage: "person.crop.circle.badge.clock")
            } description: {
                Text("Preparing a secure sign-in flow.")
            } actions: {
                ProgressView()
                    .controlSize(.regular)
            }

        case .awaitingUserAuth(let userCode, let verificationURL):
            ContentUnavailableView {
                Label("Finish on GitHub", systemImage: "number.square")
            } description: {
                Text("Enter this one-time code on GitHub to finish linking your account.")
            } actions: {
                VStack(spacing: 10) {
                    Text(userCode)
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                    HStack(spacing: 10) {
                        Button("Copy Code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(userCode, forType: .string)
                        }
                        .buttonStyle(.bordered)

                        Button("Open GitHub") {
                            guard let url = URL(string: verificationURL) else { return }
                            openURL(url)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

        case .exchangingToken:
            ContentUnavailableView {
                Label("Connecting GitHub", systemImage: "lock.shield")
            } description: {
                Text("Completing sign-in.")
            } actions: {
                ProgressView()
                    .controlSize(.regular)
            }

        case .failed(let message):
            ContentUnavailableView {
                Label("Could Not Connect GitHub", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                VStack(spacing: 10) {
                    Button("Try Again") {
                        Task { await notificationCoordinator.startDeviceFlow() }
                    }
                    .buttonStyle(.borderedProminent)

                    if !notificationsEnabled {
                        SettingsLink {
                            Text("Open Settings")
                        }
                    }
                }
            }

        case .signedIn:
            EmptyView()
        }
    }
}

struct EventRow: View {
    let event: WebhookEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.icon)
                .foregroundStyle(event.color)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary)
                    .font(.callout)
                    .lineLimit(2)

                Text(event.timestamp.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// FileNode is defined in Models/Models.swift
