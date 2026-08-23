//
//  SidebarView.swift
//  WorkspaceManager
//
//  Left sidebar showing repositories and workspaces
//

import Combine
import SwiftData
import SwiftUI
import WorkspaceManagerCore
import os.log

private let creationLog = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "WorkspaceCreation"
)

struct WorkspaceActionState {
    let workspaceID: UUID
    let message: String
}

struct WorkspaceCreationStatus {
    let message: String
}

private enum SidebarWorkspaceCreationResult {
    case created(Workspace)
    case confirmationRequired(AutomationConfirmationRequirement)
    case invalidRequest(String)
    case failed(String)
}

private struct NewWorkspaceSheetContext: Identifiable {
    let repo: Repo

    var id: UUID { repo.id }
}

/// Where a workspace row sits: indented under its repo in the tree arrangements, or
/// flat in a Recent bucket, where the repo name travels with the row as a breadcrumb.
private enum WorkspaceRowPlacement {
    case nested
    case flat(repoContext: String?)

    var isNested: Bool {
        if case .nested = self { return true }
        return false
    }

    var repoContext: String? {
        if case .flat(let repoContext) = self { return repoContext }
        return nil
    }
}

struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.gitService) private var gitService
    @Environment(\.lumeRuntimeService) private var lumeRuntimeService
    @Environment(\.workspaceService) private var workspaceService
    @Environment(\.workspaceProviderRegistry) private var workspaceProviderRegistry
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var workspaceStatusAggregator: WorkspaceStatusAggregator
    @ObservedObject var appCommandState: AppCommandState
    let repos: [Repo]
    let webSources: [WebSource]
    let selectedRepo: Repo?
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedWebSource: WebSource?
    let paneCountBySessionKey: [HostTerminalSessionKey: Int]
    let activeSessionKey: HostTerminalSessionKey?
    let hostSessions: [HostTerminalSession]
    let agentStatusBySessionID: [UUID: AgentSessionStatus]
    /// Display title for a terminal tab (user override → live terminal title →
    /// directory). Resolved lazily by the hover card; mirrors the tab bar's title.
    let titleForSession: @MainActor (HostTerminalSession) -> String
    let connectingWorkspaceID: UUID?
    let onRepoSelected: (Repo) -> Void
    let onRepoTerminalSelected: (Repo) -> Void
    let onWebSourceSelected: (WebSource) -> Void
    let onRequestWebSourceCreation: (WebSourceCreationTarget) -> Void
    /// Resolves a repo's GitHub `owner/name` for the "New Web Session" deep link,
    /// or nil when the remote can't be parsed (the entry is then disabled).
    let webNextSessionSlug: (Repo) -> GitHubRepoSlug?
    /// Opens the embedded web-next surface with a repo-bound new-session deep link.
    let onOpenWebNextSession: (Repo) -> Void
    let onWorkspaceCreated: () -> Void
    let retireTerminalSessions: @MainActor (HostTerminalSessionKey) async throws -> Void
    let workspaceProviderSetupCoordinator: WorkspaceProviderSetupCoordinator
    /// Seam to the debug-only smoke harness; inert in release builds.
    let smokeDriver: SmokeScenarioDriver
    let automationWorkspaceCreateBridge: AutomationWorkspaceCreateGestureBridge

    @AppStorage(SidebarRepoSortMode.storageKey)
    private var repoSortModeRawValue: String = SidebarRepoSortMode.alphabetical.rawValue
    @ExperimentalFeatureFlag(.minimalToolbar)
    private var minimalToolbarEnabled: Bool

    @State private var isAddingRepo = false
    @State private var newWorkspaceSheetContext: NewWorkspaceSheetContext?
    @State private var workspaceEnvironmentSheetState = WorkspaceEnvironmentSheetState.empty

    // Error alert state — routes through the shared main-window error presenter seam.
    @State private var errorPresenter = MainWindowErrorPresenter()
    /// Last failure handed to the smoke automation, so an identical consecutive error does not
    /// re-notify it (the pre-seam `errorMessage` was sticky; the presenter clears on dismiss).
    @State private var lastNotedFailureMessage: String?

    // Delete confirmation state
    @State private var workspaceToDelete: Workspace?
    @State private var showingDeleteConfirmation = false

    @State private var didAttemptDefaultRepoImport = false
    @State private var expansionController = SidebarExpansionStateController()
    @FocusState private var sidebarHasKeyFocus: Bool
    @State private var workspaceAction: WorkspaceActionState?
    @State private var expandedArchivedRepoIDs: Set<UUID> = []
    @State private var workspaceCreationStatusByRepoID: [UUID: WorkspaceCreationStatus] = [:]
    @State private var repoLastAccessedSnapshotByID: [UUID: Date] = [:]
    /// `lastAccessedAt` per repo and workspace id, plus the instant it was taken, so the
    /// Recent arrangement's bucket boundaries are as stable as its ordering.
    @State private var recentSnapshotByID: [UUID: Date] = [:]
    @State private var recentSnapshotTakenAt = Date()
    @State private var isPreparingNewWorkspaceSheet = false

    /// Real foreground process name per plain terminal tab, resolved lazily when a hover
    /// card opens and preferred over the terminal title. Populated by
    /// `refreshForegroundProcessNames`; empty in ghostty-splits mode (see #666).
    @State private var foregroundNameBySessionID: [UUID: String] = [:]
    private let foregroundResolver = TerminalForegroundProcessResolver()

    /// Last assistant message per Claude Code agent tab, resolved lazily when a hover card
    /// opens and shown on the card. Populated by `refreshTranscriptTails`; fails closed to
    /// absent for every non-happy path (see #680).
    @State private var transcriptTailBySessionID: [UUID: String] = [:]
    private let transcriptTailResolver = ClaudeTranscriptTailResolver()

    private var isUIFixtureMode: Bool {
        ProcessInfo.processInfo.environment["WORKSPACES_UI_FIXTURE"] == "1"
    }

    private var isRepoAutoImportDisabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return isUIFixtureMode || environment["WORKSPACES_DISABLE_AUTO_IMPORT"] == "1"
    }

    private var workspaceController: SidebarWorkspaceController {
        SidebarWorkspaceController(
            modelContext: modelContext,
            workspaceService: workspaceService,
            workspaceProviderRegistry: workspaceProviderRegistry,
            retireTerminalSessions: retireTerminalSessions
        )
    }

    private var lumeRuntimeSnapshot: LumeRuntimeSnapshot? {
        workspaceEnvironmentSheetState.lumeRuntimeSnapshot
    }

    @State private var repoSortController = SidebarRepoSortController()

    private var workspaceProviderSetupActionRunner: WorkspaceProviderSetupActionRunner {
        WorkspaceProviderSetupActionRunner(coordinator: workspaceProviderSetupCoordinator)
    }

    private let workspaceEnvironmentOptionsController = WorkspaceEnvironmentOptionsController()
    private let workspacePresentationController = SidebarWorkspacePresentationController()
    private let pinController = SidebarPinController()

    /// Resolved once per process: fixture captures pin the arrangement by environment so a
    /// scenario renders the same way whatever the stored preference happens to be.
    private static let fixtureSortModeOverride = UIFixtureSidebarArrangement.mode(
        from: ProcessInfo.processInfo.environment
    )

    private var repoSortMode: SidebarRepoSortMode {
        Self.fixtureSortModeOverride
            ?? SidebarRepoSortMode(rawValue: repoSortModeRawValue)
            ?? .alphabetical
    }

    private var workspaceIDs: Set<UUID> {
        Set(repos.flatMap(\.workspaces).map(\.id))
    }

    private var repoRootPaneCounts: [UUID: Int] {
        Dictionary(
            uniqueKeysWithValues: repos.map { repo in
                (repo.id, paneCount(for: .repoPath(normalizePath(repo.localURL))))
            }
        )
    }

    private var pinnedWorkspaces: [Workspace] {
        pinController.pinnedWorkspaces(in: repos.flatMap(\.workspaces))
    }

    private var recentBuckets: [RecentBucket] {
        SidebarRecentArrangement.buckets(
            repos: repos,
            snapshot: recentSnapshotByID,
            repoRootPaneCounts: repoRootPaneCounts,
            now: recentSnapshotTakenAt,
            calendar: .current
        )
    }

    private var sortedRepos: [Repo] {
        repoSortController.sortedRepos(
            repos,
            mode: repoSortMode,
            lastAccessedSnapshot: repoLastAccessedSnapshotByID
        )
    }

    private var globalWebSources: [WebSource] {
        webSources
            .filter(\.isGlobal)
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    var body: some View {
        Group {
            if minimalToolbarEnabled {
                sidebarList
                    .listStyle(.sidebar)
                    .environment(\.defaultMinListRowHeight, 34)
                    .safeAreaInset(edge: .bottom) {
                        footerBar
                    }
            } else {
                sidebarList
                    .listStyle(.sidebar)
                    .environment(\.defaultMinListRowHeight, 34)
                    .safeAreaInset(edge: .bottom) {
                        footerBar
                    }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            addSourceMenu
                        }
                    }
            }
        }
        .fileImporter(
            isPresented: $isAddingRepo,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    await addRepo(from: url)
                }
            }
        }
        .sheet(item: $newWorkspaceSheetContext) { context in
            NewWorkspaceSheet(
                repo: context.repo,
                environmentOptions: environmentOptions(for: context.repo),
                isPreparingEnvironmentOptions: isPreparingNewWorkspaceSheet,
                isCreateDisabled: isCreatingWorkspace(for: context.repo.id)
            ) { name, nameSource, providerID, guestOS in
                Task { @MainActor in
                    await createWorkspace(
                        from: context.repo,
                        name: name,
                        nameSource: nameSource,
                        providerID: providerID,
                        guestOS: guestOS
                    )
                }
            }
        }
        .mainWindowErrorAlert($errorPresenter) { kind in
            switch kind {
            case .openVMRuntime:
                openSettingsWindow()
            case .openLumeLog:
                openLumeLog()
            }
        }
        .confirmationDialog(
            "Delete Workspace",
            isPresented: $showingDeleteConfirmation,
            presenting: workspaceToDelete
        ) { workspace in
            Button("Delete (Keep Files)", role: .destructive) {
                Task { @MainActor in
                    await performDelete(workspace, deleteFiles: false)
                }
            }
            Button("Delete and Remove Files", role: .destructive) {
                Task { @MainActor in
                    await performDelete(workspace, deleteFiles: true)
                }
            }
            Button("Cancel", role: .cancel) {
                workspaceToDelete = nil
            }
        } message: { workspace in
            Text("Are you sure you want to delete '\(workspace.name)'?")
        }
        .task {
            syncAppCommands()
        }
        .onDisappear {
            clearAppCommands()
            automationWorkspaceCreateBridge.clear()
        }
        .onAppear {
            installAutomationWorkspaceCreateGesture()
        }
        .onChange(of: selectedWorkspace?.id) { _, _ in
            expandRepoForSelectedWorkspace()
        }
        .onChange(of: selectedWebSource?.id) { _, _ in
            expandContainersForSelectedWebSource()
        }
        .onChange(of: repos.map(\.id)) { _, _ in
            pruneExpandedContainers()
            syncRepoSortSnapshot()
            syncRecentSnapshot(forceRefresh: true)
            Task { @MainActor in
                await smokeDriver.driveHostLumeScenarioIfNeeded(smokeScenarioContext)
            }
            Task { @MainActor in
                await smokeDriver.driveDesktopUIScenarioIfNeeded(smokeScenarioContext)
            }
            installAutomationWorkspaceCreateGesture()
        }
        .onChange(of: repoSortModeRawValue) { _, _ in
            syncRepoSortSnapshot(forceRefresh: true)
            syncRecentSnapshot(forceRefresh: true)
        }
        .onChange(of: workspaceIDs) { _, _ in
            syncRecentSnapshot(forceRefresh: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            syncRecentSnapshot(forceRefresh: true)
        }
        .onAppear {
            installAutomationWorkspaceCreateGesture()
            initializeExpandedReposIfNeeded()
            expandContainersForSelectedWebSource()
            syncRepoSortSnapshot(forceRefresh: false)
            syncRecentSnapshot(forceRefresh: false)
            guard !isRepoAutoImportDisabled else { return }
            guard !didAttemptDefaultRepoImport else { return }
            didAttemptDefaultRepoImport = true
            Task {
                await autoImportReposFromCodeHome()
            }
        }
        .task {
            _ = await seedFixtureProviderStateIfNeeded()
            await smokeDriver.driveScenariosIfNeeded(smokeScenarioContext)
        }
        .onChange(of: errorPresenter.current?.message) { _, message in
            guard
                MainWindowErrorPresenter.shouldNoteFailure(
                    message: message,
                    lastNoted: lastNotedFailureMessage
                ),
                let message
            else { return }
            lastNotedFailureMessage = message
            Task { @MainActor in
                await smokeDriver.noteFailure(message: message)
            }
        }
    }

    /// The view capabilities the smoke scenarios drive — the same selection and
    /// creation paths user gestures enter, packaged for `SmokeScenarioDriver`.
    private var smokeScenarioContext: SmokeScenarioSidebarContext {
        SmokeScenarioSidebarContext(
            repos: repos,
            webSources: webSources,
            selectedWorkspace: { selectedWorkspace },
            sidebarWorkspaces: { repos.flatMap(\.workspaces) },
            normalizePath: normalizePath(_:),
            presentError: presentSidebarError,
            addRepo: { await addRepo(from: $0) },
            createWorkspace: { repo, name, providerID, guestOS in
                await createWorkspace(
                    from: repo,
                    name: name,
                    nameSource: .manual,
                    providerID: providerID,
                    guestOS: guestOS
                )
            },
            selectRepoTerminal: onRepoTerminalSelected,
            selectWorkspace: selectWorkspace(_:),
            selectWebSource: onWebSourceSelected,
            insertWebSource: { source in
                modelContext.insert(source)
                return saveModelContext(action: "create desktop-ui-smoke web source")
            }
        )
    }

    private var sidebarList: some View {
        List {
            pinnedSection

            if repoSortMode == .recent {
                recentSections
            } else {
                repositoriesSection
            }

            if !globalWebSources.isEmpty {
                webSection
            }
        }
        .focusable()
        .focused($sidebarHasKeyFocus)
        .onKeyPress(.leftArrow) { handleSidebarLeftArrow() }
        .onKeyPress(.rightArrow) { handleSidebarRightArrow() }
    }

    /// Tree-style ← behavior. When a workspace is selected, collapse its
    /// parent repo and lift selection to that parent. When a repo is selected
    /// and expanded, collapse it. Otherwise pass through.
    private func handleSidebarLeftArrow() -> KeyPress.Result {
        guard repoSortMode != .recent else { return .ignored }
        if let workspace = selectedWorkspace, let parent = workspace.sourceRepo {
            selectedWorkspace = nil
            onRepoSelected(parent)
            if isRepoExpanded(parent) {
                toggleRepoExpansion(parent)
            }
            return .handled
        }
        if let repo = selectedRepo, isRepoExpanded(repo) {
            toggleRepoExpansion(repo)
            return .handled
        }
        return .ignored
    }

    /// Tree-style → behavior. When a repo is selected and collapsed, expand
    /// it. (Moving selection into the first child is intentionally not
    /// implemented yet — Finder/Xcode both treat → as expand-then-enter, but
    /// the second step is fiddly and not yet warranted.)
    private func handleSidebarRightArrow() -> KeyPress.Result {
        guard repoSortMode != .recent else { return .ignored }
        if let repo = selectedRepo, !isRepoExpanded(repo) {
            toggleRepoExpansion(repo)
            return .handled
        }
        return .ignored
    }

    /// Sits above every arrangement when non-empty. Rows are flat — the repo travels with
    /// the workspace — and in the tree arrangements the workspace also keeps its place in
    /// its repo: Pinned is a shortcut list, not a move.
    @ViewBuilder
    private var pinnedSection: some View {
        let pinned = pinnedWorkspaces

        if !pinned.isEmpty {
            Section {
                ForEach(pinned) { workspace in
                    workspaceRow(
                        workspace,
                        placement: .flat(repoContext: workspace.sourceRepo?.name)
                    )
                }
            } header: {
                sidebarSectionHeader(title: "Pinned", showsSortMenu: !repos.isEmpty)
            }
        }
    }

    /// The arrangement menu lives on the topmost header: Pinned when it exists, otherwise
    /// the first header of the arrangement itself.
    private var hasPinnedRows: Bool {
        !pinnedWorkspaces.isEmpty
    }

    private var repositoriesSection: some View {
        Section {
            if repos.isEmpty {
                Text("No repositories")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(sortedRepos) { repo in
                    repoListRow(repo)
                }
            }
        } header: {
            repositoriesHeader
        }
    }

    /// Flat, date-bucketed arrangement. Only the first bucket's header carries the sort
    /// menu; the empty state still renders one so Recent is never a mode you can't leave.
    @ViewBuilder
    private var recentSections: some View {
        let buckets = recentBuckets

        if buckets.isEmpty {
            Section {
                Text("No recent workspaces")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } header: {
                sidebarSectionHeader(title: "Recent", showsSortMenu: !repos.isEmpty && !hasPinnedRows)
            }
        } else {
            ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                Section {
                    ForEach(bucket.rows) { row in
                        recentRow(row)
                    }
                } header: {
                    sidebarSectionHeader(title: bucket.title, showsSortMenu: index == 0 && !hasPinnedRows)
                }
            }
        }
    }

    @ViewBuilder
    private func recentRow(_ row: RecentRow) -> some View {
        switch row {
        case .workspace(let workspace):
            workspaceRow(workspace, placement: .flat(repoContext: workspace.sourceRepo?.name))
        case .repoRoot(let repo):
            repoListRow(repo, showsChildren: false)
        }
    }

    private var repositoriesHeader: some View {
        sidebarSectionHeader(title: "Repositories", showsSortMenu: !repos.isEmpty && !hasPinnedRows)
    }

    private func sidebarSectionHeader(title: String, showsSortMenu: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            if showsSortMenu {
                Menu {
                    ForEach(SidebarRepoSortMode.allCases) { mode in
                        Button {
                            updateRepoSortMode(mode)
                        } label: {
                            if repoSortMode == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Sort repositories")
            }
        }
    }

    private var webSection: some View {
        Section("Web") {
            ForEach(globalWebSources) { source in
                Button {
                    onWebSourceSelected(source)
                } label: {
                    WebSourceRow(
                        source: source,
                        isSelected: selectedWebSource?.id == source.id
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open in Browser") {
                        openWebSourceExternally(source)
                    }

                    Divider()

                    Button("Remove from List", role: .destructive) {
                        removeWebSource(source)
                    }
                }
            }
        }
    }

    private var footerBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                Text(repos.isEmpty ? "Add a repository to get started" : "\(repos.count) repositories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var addSourceMenu: some View {
        Menu {
            Button("Add Repository") {
                isAddingRepo = true
            }

            Button("Add URL Source") {
                onRequestWebSourceCreation(.global)
            }
        } label: {
            Image(systemName: "plus")
        }
    }

    /// `showsChildren: false` is the Recent arrangement's flat repo root — no subtree, so
    /// the folder glyph selects the repo rather than toggling an expansion nothing shows.
    @ViewBuilder
    private func repoListRow(_ repo: Repo, showsChildren: Bool = true) -> some View {
        let normalizedRepoPath = normalizePath(repo.localURL)
        let repoSessionKey = HostTerminalSessionKey.repoPath(normalizedRepoPath)
        let baselineActivity = sessionActivity(for: repoSessionKey)
        let bubbledActivity = bubbledRepoActivity(for: repo, baseline: baselineActivity)

        RepoRow(
            repo: repo,
            activeWorkspaceCount: SidebarWorkspaceController.activeWorkspaceCount(in: repo.workspaces),
            sessionActivity: bubbledActivity,
            paneCount: paneCount(for: repoSessionKey),
            isSelected: selectedRepo?.id == repo.id,
            isExpanded: showsChildren && isRepoExpanded(repo),
            showsExpansion: showsChildren,
            sessionActivityTooltip: bubbleTooltip(for: repo, bubbled: bubbledActivity, baseline: baselineActivity),
            onToggleExpansion: {
                if showsChildren {
                    toggleRepoExpansion(repo)
                } else {
                    selectRepo(repo, sessionKey: repoSessionKey, expanding: false)
                }
            },
            onSelectRepo: {
                selectRepo(repo, sessionKey: repoSessionKey, expanding: showsChildren)
            },
            onNewWorkspace: {
                Task { @MainActor in
                    await prepareNewWorkspaceSheet(for: repo)
                }
            },
            onNewWebView: {
                onRequestWebSourceCreation(.repo(repo))
            },
            tabsProvider: {
                refreshForegroundProcessNames(for: repoSessionKey)
                refreshTranscriptTails(for: repoSessionKey)
                return tabSummaries(for: repoSessionKey)
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open Terminal") {
                onRepoTerminalSelected(repo)
            }

            Divider()

            Button("New Workspace...") {
                Task { @MainActor in
                    await prepareNewWorkspaceSheet(for: repo)
                }
            }
            .disabled(isCreatingWorkspace(for: repo.id))

            Button("Add Web View...") {
                onRequestWebSourceCreation(.repo(repo))
            }

            Button("New Web Session") {
                onOpenWebNextSession(repo)
            }
            .disabled(webNextSessionSlug(repo) == nil)

            Divider()

            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.localPath)
            }

            Divider()

            Button("Remove from List", role: .destructive) {
                removeRepo(repo)
            }
        }

        if showsChildren, isRepoExpanded(repo) {
            repoChildrenList(repo)
        }
    }

    private func selectRepo(_ repo: Repo, sessionKey: HostTerminalSessionKey, expanding: Bool) {
        sidebarHasKeyFocus = true
        if expanding, !isRepoExpanded(repo) {
            expansionController.expandRepo(repo.id)
        }
        if paneCount(for: sessionKey) > 0 {
            onRepoTerminalSelected(repo)
        } else {
            onRepoSelected(repo)
        }
    }

    @ViewBuilder
    private func repoChildrenList(_ repo: Repo) -> some View {
        repoWebSourceList(repo)
        repoWorkspaceList(repo)
    }

    @ViewBuilder
    private func repoWorkspaceList(_ repo: Repo) -> some View {
        let activeWorkspaces = activeWorkspaces(for: repo)
        let archivedWorkspaces = archivedWorkspaces(for: repo)

        ForEach(activeWorkspaces) { workspace in
            workspaceRow(workspace)
        }

        if !archivedWorkspaces.isEmpty {
            archivedSectionHeader(for: repo, count: archivedWorkspaces.count)

            if isArchivedSectionExpanded(repo) {
                ForEach(archivedWorkspaces) { workspace in
                    workspaceRow(workspace)
                }
            }
        }

        if let creationStatus = creationStatus(for: repo.id) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                Text(creationStatus.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 28)
        }
    }

    @ViewBuilder
    private func workspaceRow(
        _ workspace: Workspace,
        placement: WorkspaceRowPlacement = .nested
    ) -> some View {
        WorkspaceRow(
            workspace: workspace,
            isSelected: selectedWorkspace?.id == workspace.id,
            statusMessage: workspaceStatusMessage(workspace),
            sessionActivity: sessionActivity(for: sessionKey(for: workspace)),
            paneCount: paneCount(for: sessionKey(for: workspace)),
            repoContext: placement.repoContext,
            isNested: placement.isNested,
            isExpanded: placement.isNested && isWorkspaceExpanded(workspace),
            showsDisclosure: placement.isNested && !workspace.webSources.isEmpty,
            isPinned: workspace.isPinned,
            tabsProvider: {
                refreshForegroundProcessNames(for: sessionKey(for: workspace))
                refreshTranscriptTails(for: sessionKey(for: workspace))
                return tabSummaries(for: workspace)
            },
            onToggleExpansion: {
                toggleWorkspaceExpansion(workspace)
            },
            onSelect: {
                selectWorkspace(workspace)
            },
            onTogglePin: pinController.isPinnable(workspace) ? { togglePin(workspace) } : nil
        )
        .contextMenu {
            Button("Open in New Window") {
                openInNewWindow(workspace)
            }
            .disabled(true)

            if usesHostWorkspaceFiles(for: workspace) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: workspace.path)
                }
            }

            Divider()

            if pinController.isPinnable(workspace) {
                Button(workspace.isPinned ? "Unpin" : "Pin") {
                    togglePin(workspace)
                }

                Divider()
            }

            if workspace.backend == .local {
                localWorkspaceActions(workspace)
            } else {
                providerWorkspaceActions(workspace)
            }

            if let repo = workspace.sourceRepo {
                Button("New Web Session") {
                    onOpenWebNextSession(repo)
                }
                .disabled(webNextSessionSlug(repo) == nil)
            }

            Divider()

            Button("Delete Workspace", role: .destructive) {
                deleteWorkspace(workspace)
            }
        }

        if placement.isNested, isWorkspaceExpanded(workspace) {
            workspaceWebSourceList(workspace)
        }
    }

    @ViewBuilder
    private func archivedSectionHeader(for repo: Repo, count: Int) -> some View {
        let expanded = isArchivedSectionExpanded(repo)
        Button {
            toggleArchivedSection(for: repo)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                Text("Archived (\(count))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.leading, 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Archived workspaces, \(count)")
    }

    @ViewBuilder
    private func repoWebSourceList(_ repo: Repo) -> some View {
        let sources = sortedRepoWebSources(for: repo)

        if !sources.isEmpty {
            ForEach(sources) { source in
                sidebarWebSourceButton(source, paddingLeading: 18)
            }
        }
    }

    @ViewBuilder
    private func workspaceWebSourceList(_ workspace: Workspace) -> some View {
        let sources = sortedWorkspaceWebSources(for: workspace)

        ForEach(sources) { source in
            sidebarWebSourceButton(source, paddingLeading: 42)
        }
    }

    @ViewBuilder
    private func sidebarWebSourceButton(_ source: WebSource, paddingLeading: CGFloat) -> some View {
        Button {
            onWebSourceSelected(source)
        } label: {
            WebSourceRow(
                source: source,
                isSelected: selectedWebSource?.id == source.id
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.leading, paddingLeading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in Browser") {
                openWebSourceExternally(source)
            }

            Divider()

            Button("Remove from List", role: .destructive) {
                removeWebSource(source)
            }
        }
    }

    // MARK: - Actions

    private func addRepo(from url: URL) async {
        // Security-scoped access (returns false in non-sandboxed builds, which is fine)
        let hasSecurityAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Avoid duplicate repo entries by canonical path.
        let normalizedURLPath = normalizePath(url)
        guard !repos.contains(where: { normalizePath($0.localURL) == normalizedURLPath }) else {
            return
        }

        // Validate it's a git repo
        let gitDir = url.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir.path) else {
            await MainActor.run {
                presentSidebarError("The selected folder is not a Git repository.\n\nPath: \(url.lastPathComponent)")
            }
            return
        }

        let repo = Repo(
            name: url.lastPathComponent,
            localPath: url
        )

        // Try to get remote URL
        if let remote = try? await gitService.getRemoteURL(at: url) {
            repo.remoteURL = remote
        }

        await MainActor.run {
            // Re-check against latest model state to avoid async races creating duplicates.
            guard !repos.contains(where: { normalizePath($0.localURL) == normalizedURLPath }) else {
                return
            }

            modelContext.insert(repo)
            if !saveModelContext(action: "save repository") {
                modelContext.rollback()
            }
        }
    }

    @MainActor
    private func removeRepo(_ repo: Repo) {
        modelContext.delete(repo)
        if !saveModelContext(action: "remove repository") {
            modelContext.rollback()
        }
    }

    @MainActor
    private func removeWebSource(_ source: WebSource) {
        modelContext.delete(source)
        if !saveModelContext(action: "remove URL source") {
            modelContext.rollback()
        }
    }

    private func openWebSourceExternally(_ source: WebSource) {
        guard let url = source.baseURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Surfaces a sidebar failure through the shared error presenter, offering the Lume recovery
    /// actions whenever the message carries host-Lume recovery hints (same condition as before).
    private func presentSidebarError(_ message: String) {
        errorPresenter.present(
            source: .sidebar,
            title: "Error",
            message: message,
            recoveryActions: MainWindowErrorRecoveryAction.lumeRecoveryActions(forMessage: message)
        )
    }

    private func openSettingsWindow() {
        openSettings()
    }

    private func openLumeLog() {
        let candidatePaths = [
            lumeRuntimeSnapshot?.errorLogPath,
            lumeRuntimeSnapshot?.infoLogPath,
        ]

        for path in candidatePaths {
            guard let path, !path.isEmpty else { continue }
            let logURL = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: logURL.path) {
                NSWorkspace.shared.open(logURL)
                return
            }
        }

        presentSidebarError("No Lume log file is available yet.")
    }

    private func creationStatus(for repoID: UUID) -> WorkspaceCreationStatus? {
        workspaceCreationStatusByRepoID[repoID]
    }

    private func isCreatingWorkspace(for repoID: UUID) -> Bool {
        workspaceCreationStatusByRepoID[repoID] != nil
    }

    private func updateLocalCreationStatus(repoID: UUID, phase: WorkspaceCreationPhase) {
        workspaceCreationStatusByRepoID[repoID] = WorkspaceCreationStatus(
            message: SidebarWorkspaceController.localCreationMessage(for: phase)
        )
    }

    @MainActor
    private func installAutomationWorkspaceCreateGesture() {
        automationWorkspaceCreateBridge.install { command in
            await performAutomationWorkspaceCreate(command)
        }
    }

    @MainActor
    private func performAutomationWorkspaceCreate(
        _ command: AutomationWorkspaceCreateCommand
    ) async -> AutomationWorkspaceCreateOutcome {
        guard newWorkspaceSheetContext == nil else {
            return .confirmationRequired(
                AutomationConfirmationRequirement(
                    action: "workspace.create",
                    title: "New Workspace",
                    message:
                        "A New Workspace sheet is already open; confirm or dismiss it before creating another workspace."
                )
            )
        }
        if let confirmation = workspaceProviderSetupCoordinator.confirmationRequest {
            return .confirmationRequired(automationConfirmation(from: confirmation))
        }
        if let progress = workspaceProviderSetupCoordinator.progressPresentation {
            return .confirmationRequired(
                AutomationConfirmationRequirement(
                    action: "workspace.create",
                    title: progress.title,
                    message:
                        "\(progress.providerDisplayName) setup is already in progress for \(progress.action.summary).",
                    providerID: progress.providerID,
                    providerDisplayName: progress.providerDisplayName
                )
            )
        }

        guard let repo = repos.first(where: { $0.id == command.repoID }) else {
            return .notFound
        }

        let result = await createWorkspace(
            from: repo,
            name: command.name,
            nameSource: .manual,
            providerID: command.providerID,
            guestOS: command.guestOS,
            shouldSelect: command.shouldSelect,
            fromRef: command.fromRef
        )

        switch result {
        case .created(let workspace):
            await smokeDriver.noteWorkspaceCreated(
                workspace,
                sidebarWorkspaces: { repos.flatMap(\.workspaces) }
            )
            return .completed(
                AutomationWorkspaceCreateEffect(
                    repoID: repo.id,
                    workspaceID: workspace.id,
                    workspaceName: workspace.name,
                    workspacePath: workspace.path,
                    selectedWorkspaceID: command.shouldSelect ? workspace.id : selectedWorkspace?.id,
                    attachedSurfaceID: nil,
                    attachedTerminal: false
                )
            )
        case .confirmationRequired(let confirmation):
            workspaceProviderSetupCoordinator.cancelPendingAction()
            return .confirmationRequired(confirmation)
        case .invalidRequest(let message):
            return .invalidRequest(message)
        case .failed(let message):
            return .unsupported(message)
        }
    }

    private func automationConfirmation(
        from request: WorkspaceProviderSetupConfirmationRequest
    ) -> AutomationConfirmationRequirement {
        let message = "\(request.action.summary) requires \(request.providerDisplayName) setup confirmation."
        return AutomationConfirmationRequirement(
            action: "workspace.create",
            title: request.title,
            message: message,
            providerID: request.providerID,
            providerDisplayName: request.providerDisplayName,
            primaryButtonTitle: request.primaryButtonTitle
        )
    }

    @MainActor
    @discardableResult
    private func createWorkspace(
        from repo: Repo,
        name: String,
        nameSource: WorkspaceNameSource,
        providerID: String,
        guestOS: WorkspaceGuestOS? = nil,
        shouldSelect: Bool = true,
        fromRef: String? = nil
    ) async -> SidebarWorkspaceCreationResult {
        guard let provider = workspaceProviderRegistry.provider(for: providerID) else {
            let message = "Workspace provider '\(providerID)' is not registered."
            presentSidebarError(message)
            return .invalidRequest(message)
        }

        do {
            var createdWorkspace: Workspace?
            let intercepted = try await workspaceProviderSetupActionRunner.run(
                provider: provider,
                action: .createWorkspace(name: name, guestOS: guestOS)
            ) {
                await refreshWorkspaceEnvironmentState(trigger: "workspace_create_after_setup")
                createdWorkspace = await createWorkspaceAfterSetup(
                    from: repo,
                    name: name,
                    nameSource: nameSource,
                    providerID: providerID,
                    guestOS: guestOS,
                    shouldSelect: shouldSelect,
                    fromRef: fromRef
                )
            } perform: {
                createdWorkspace = await createWorkspaceAfterSetup(
                    from: repo,
                    name: name,
                    nameSource: nameSource,
                    providerID: providerID,
                    guestOS: guestOS,
                    shouldSelect: shouldSelect,
                    fromRef: fromRef
                )
            }
            if intercepted {
                if let confirmation = workspaceProviderSetupCoordinator.confirmationRequest {
                    return .confirmationRequired(automationConfirmation(from: confirmation))
                }
                let message = "Workspace provider setup is already in progress."
                return .confirmationRequired(
                    AutomationConfirmationRequirement(
                        action: "workspace.create",
                        title: "Workspace Provider Setup",
                        message: message,
                        providerID: providerID,
                        providerDisplayName: provider.descriptor.displayName
                    )
                )
            }
            guard let createdWorkspace else {
                let message = "Workspace creation did not produce a workspace."
                return .failed(message)
            }
            return .created(createdWorkspace)
        } catch {
            let message = error.localizedDescription
            presentSidebarError(message)
            return .failed(message)
        }
    }

    @MainActor
    @discardableResult
    private func createWorkspaceAfterSetup(
        from repo: Repo,
        name: String,
        nameSource: WorkspaceNameSource,
        providerID: String,
        guestOS: WorkspaceGuestOS? = nil,
        shouldSelect: Bool = true,
        fromRef: String? = nil
    ) async -> Workspace? {
        let repoID = repo.id
        guard !isCreatingWorkspace(for: repoID) else { return nil }
        expansionController.expandRepo(repoID)
        workspaceCreationStatusByRepoID[repoID] = WorkspaceCreationStatus(
            message: initialCreationMessage(for: providerID)
        )
        await smokeDriver.noteWorkspaceCreationPhase(
            message: initialCreationMessage(for: providerID)
        )

        creationLog.info(
            "createWorkspaceAfterSetup: starting repo=\(repo.name) provider=\(providerID)"
        )

        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            let currentPhase = workspaceCreationStatusByRepoID[repoID]?.message ?? "unknown"
            creationLog.error(
                "createWorkspaceAfterSetup: WATCHDOG — creation stalled for 30s at phase=\(currentPhase)"
            )
            workspaceCreationStatusByRepoID[repoID] = WorkspaceCreationStatus(
                message: "Creation is taking longer than expected..."
            )
        }
        defer { watchdog.cancel() }

        do {
            let workspace = try await workspaceController.createWorkspace(
                from: repo,
                name: name,
                nameSource: nameSource,
                providerID: providerID,
                guestOS: guestOS,
                fromRef: fromRef,
                progress: { phase in
                    creationLog.debug("createWorkspaceAfterSetup: progress phase=\(phase)")
                    await MainActor.run {
                        workspaceCreationStatusByRepoID[repoID] = WorkspaceCreationStatus(message: phase)
                    }
                    await smokeDriver.noteWorkspaceCreationPhase(message: phase)
                },
                onPersisted: { result in
                    await smokeDriver.noteWorkspacePersisted(result)
                }
            )
            creationLog.info("createWorkspaceAfterSetup: workspace created, updating selection")
            workspaceCreationStatusByRepoID.removeValue(forKey: repoID)
            onWorkspaceCreated()
            if shouldSelect {
                selectedWorkspace = workspace
            }
            await smokeDriver.noteWorkspaceActive(workspace)
            return workspace
        } catch {
            creationLog.error(
                "createWorkspaceAfterSetup: failed: \(error.localizedDescription)"
            )
            workspaceCreationStatusByRepoID.removeValue(forKey: repoID)
            let providerName = providerDisplayName(for: providerID)
            presentSidebarError("Failed to create \(providerName) workspace: \(error.localizedDescription)")
            return nil
        }
    }

    @MainActor
    private func deleteWorkspace(_ workspace: Workspace) {
        workspaceToDelete = workspace
        showingDeleteConfirmation = true
    }

    @MainActor
    private func performDelete(_ workspace: Workspace, deleteFiles: Bool) async {
        do {
            try await workspaceController.deleteWorkspace(workspace, deleteFiles: deleteFiles)
            if selectedWorkspace == workspace {
                selectedWorkspace = nil
            }
        } catch {
            presentSidebarError("Failed to delete workspace: \(error.localizedDescription)")
        }
        workspaceToDelete = nil
    }

    @ViewBuilder
    private func localWorkspaceActions(_ workspace: Workspace) -> some View {
        if workspace.status == .active {
            Button("Archive") {
                performArchive(workspace)
            }
        } else {
            Button("Unarchive") {
                performUnarchive(workspace)
            }
        }
    }

    @ViewBuilder
    private func providerWorkspaceActions(_ workspace: Workspace) -> some View {
        let descriptor = providerDescriptor(for: workspace)

        if descriptor?.supportsDesktop == true {
            Button("Open Desktop") {
                openDesktop(for: workspace)
            }
            .disabled(workspace.status == .provisioning)
        }

        switch workspace.status {
        case .active:
            Button("Stop") {
                performStop(workspace)
            }
            if descriptor?.supportsArchive == true {
                Button("Archive") {
                    performArchive(workspace)
                }
            }
        case .stopped, .archived:
            Button("Start") {
                performStart(workspace)
            }
            if descriptor?.supportsArchive == true, workspace.status == .stopped {
                Button("Archive") {
                    performArchive(workspace)
                }
            }
        case .provisioning:
            EmptyView()
        }
    }

    private func performUnarchive(_ workspace: Workspace) {
        workspaceAction = WorkspaceActionState(workspaceID: workspace.id, message: "Unarchiving...")

        Task { @MainActor in
            do {
                try await workspaceController.unarchive(workspace)
                workspaceAction = nil
            } catch {
                workspaceAction = nil
                presentSidebarError("Failed to unarchive workspace: \(error.localizedDescription)")
            }
        }
    }

    private func performStop(_ workspace: Workspace) {
        workspaceAction = WorkspaceActionState(workspaceID: workspace.id, message: "Stopping...")

        Task { @MainActor in
            do {
                try await workspaceController.stop(workspace)
                workspaceAction = nil
            } catch {
                workspaceAction = nil
                presentSidebarError("Failed to stop workspace: \(error.localizedDescription)")
            }
        }
    }

    private func performStart(_ workspace: Workspace) {
        Task { @MainActor in
            guard let provider = workspaceProviderRegistry.provider(for: workspace) else {
                presentSidebarError("No workspace provider is registered for '\(workspace.backendIdentifier)'.")
                return
            }

            do {
                try await workspaceProviderSetupActionRunner.run(
                    provider: provider,
                    action: .startWorkspace(workspaceName: workspace.name)
                ) {
                    await refreshWorkspaceEnvironmentState(trigger: "workspace_start_after_setup")
                    await performStartAfterSetup(workspace)
                }
            } catch {
                presentSidebarError(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func performStartAfterSetup(_ workspace: Workspace) async {
        workspaceAction = WorkspaceActionState(workspaceID: workspace.id, message: "Starting...")

        do {
            try await workspaceController.start(workspace)
            workspaceAction = nil
            selectedWorkspace = workspace
        } catch {
            workspaceAction = nil
            presentSidebarError("Failed to start workspace: \(error.localizedDescription)")
        }
    }

    private func performArchive(_ workspace: Workspace) {
        workspaceAction = WorkspaceActionState(workspaceID: workspace.id, message: "Archiving...")

        Task { @MainActor in
            do {
                try await workspaceController.archive(workspace)
                workspaceAction = nil
            } catch {
                workspaceAction = nil
                presentSidebarError("Failed to archive workspace: \(error.localizedDescription)")
            }
        }
    }

    private func openDesktop(for workspace: Workspace) {
        Task { @MainActor in
            guard let provider = workspaceProviderRegistry.provider(for: workspace) else {
                presentSidebarError("No workspace provider is registered for '\(workspace.backendIdentifier)'.")
                return
            }

            do {
                try await workspaceProviderSetupActionRunner.run(
                    provider: provider,
                    action: .openDesktop(workspaceName: workspace.name)
                ) {
                    await refreshWorkspaceEnvironmentState(trigger: "workspace_desktop_after_setup")
                    await openDesktopAfterSetup(workspace)
                }
            } catch {
                presentSidebarError(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func openDesktopAfterSetup(_ workspace: Workspace) async {
        guard let provider = workspaceProviderRegistry.provider(for: workspace) else {
            presentSidebarError("No workspace provider is registered for '\(workspace.backendIdentifier)'.")
            return
        }

        workspaceAction = WorkspaceActionState(workspaceID: workspace.id, message: "Opening desktop...")

        do {
            let spec = try await provider.desktopLaunchSpec(for: WorkspaceProviderTarget(workspace))
            workspace.status = spec.statusAfterLaunch
            _ = saveModelContext(action: "update workspace status")
            workspaceAction = nil
            NSWorkspace.shared.open(spec.vncURL)
        } catch {
            workspaceAction = nil
            presentSidebarError("Failed to open desktop: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func openInNewWindow(_ workspace: Workspace) {
        // Multi-window support not yet implemented
    }

    @MainActor
    private func handleNewWorkspaceShortcut() {
        guard
            let preferredRepo = SidebarWorkspaceController.preferredRepoForNewWorkspace(
                selectedWorkspace: selectedWorkspace,
                activeSessionKey: activeSessionKey,
                repos: repos,
                normalizeRepoPath: normalizePath(_:)
            )
        else {
            presentSidebarError("Add a repository first, then create a workspace.")
            return
        }

        guard !isCreatingWorkspace(for: preferredRepo.id) else {
            presentSidebarError("A workspace is already being created for '\(preferredRepo.name)'.")
            return
        }

        Task { @MainActor in
            await prepareNewWorkspaceSheet(for: preferredRepo)
        }
    }

    @MainActor
    private func syncAppCommands() {
        appCommandState.setNewWorkspaceAction(handleNewWorkspaceShortcut)
    }

    @MainActor
    private func clearAppCommands() {
        appCommandState.setNewWorkspaceAction(nil)
    }

    @MainActor
    private func prepareNewWorkspaceSheet(for repo: Repo) async {
        InvestigationDiagnostics.emitSheet(
            phase: "sidebar_sheet_flow_started",
            fields: ["repo_id": repo.id.uuidString]
        )
        let attemptID = PerformanceSignposts.beginNewWorkspaceSheetReady(trigger: "sidebar")

        if await seedFixtureProviderStateIfNeeded() {
            InvestigationDiagnostics.emitSheet(
                phase: "sidebar_fixture_seeded",
                fields: ["repo_id": repo.id.uuidString]
            )
            newWorkspaceSheetContext = NewWorkspaceSheetContext(repo: repo)
            InvestigationDiagnostics.emitSheet(
                phase: "sidebar_sheet_context_set",
                fields: [
                    "repo_id": repo.id.uuidString,
                    "option_count": "\(environmentOptions(for: repo).count)",
                ]
            )
            PerformanceSignposts.endNewWorkspaceSheetReadyIfNeeded(
                attemptID: attemptID,
                outcome: "success"
            )
            return
        }

        workspaceEnvironmentSheetState = workspaceEnvironmentOptionsController.prepareSheetStateForPresentation(
            existingState: workspaceEnvironmentSheetState,
            registry: workspaceProviderRegistry
        )

        newWorkspaceSheetContext = NewWorkspaceSheetContext(repo: repo)
        isPreparingNewWorkspaceSheet = true
        InvestigationDiagnostics.emitSheet(
            phase: "sidebar_sheet_context_set",
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
                isPreparingNewWorkspaceSheet = false
            }
            await refreshWorkspaceEnvironmentState(trigger: "sidebar_sheet_open")
            InvestigationDiagnostics.emitSheet(
                phase: "sidebar_environment_refresh_completed",
                fields: [
                    "repo_id": repo.id.uuidString,
                    "lume_state": lumeRuntimeSnapshot?.state.rawValue ?? "pending",
                    "option_count": "\(environmentOptions(for: repo).count)",
                ]
            )
        }
    }

    @MainActor
    private func togglePin(_ workspace: Workspace) {
        let action = workspace.isPinned ? "unpin workspace" : "pin workspace"
        let workspaces = repos.flatMap(\.workspaces)
        let snapshot = pinController.pinOrderSnapshot(of: workspaces)

        if workspace.isPinned {
            pinController.unpin(workspace, in: workspaces)
        } else {
            pinController.pin(workspace, in: workspaces)
        }

        if !saveModelContext(action: action) {
            pinController.restore(snapshot, in: workspaces)
        }
    }

    @MainActor
    private func selectWorkspace(_ workspace: Workspace) {
        sidebarHasKeyFocus = true
        // Force a value transition when re-selecting the same workspace so the
        // host session activation path in ContentView runs again.
        if selectedWorkspace?.id == workspace.id {
            selectedWorkspace = nil
        }
        selectedWorkspace = workspace
        selectedWebSource = nil
    }

    @MainActor
    @discardableResult
    private func saveModelContext(action: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            presentSidebarError("Failed to \(action): \(error.localizedDescription)")
            return false
        }
    }

    private func autoImportReposFromCodeHome() async {
        let codeHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("code", isDirectory: true)
        var discoveredCount = 0
        var importedCount = 0
        PerformanceSignposts.beginRepoHydration(rootPath: codeHome.path)
        defer {
            PerformanceSignposts.endRepoHydrationIfNeeded(
                discoveredCount: discoveredCount,
                importedCount: importedCount
            )
        }

        let discovered = RepositoryDiscovery.discoverGitRepositories(in: codeHome)
        discoveredCount = discovered.count
        guard !discovered.isEmpty else { return }

        let existingPaths = Set(repos.map { normalizePath($0.localURL) })
        let newRepoDirectories = discovered.filter { !existingPaths.contains(normalizePath($0)) }
        guard !newRepoDirectories.isEmpty else { return }

        var importedRepos: [Repo] = []
        importedRepos.reserveCapacity(newRepoDirectories.count)

        // Defer remote metadata lookup to keep launch-time repo hydration fast.
        for directory in newRepoDirectories {
            let repo = Repo(name: directory.lastPathComponent, localPath: directory)
            importedRepos.append(repo)
        }

        importedCount = await MainActor.run { () -> Int in
            var currentPaths = Set(repos.map { normalizePath($0.localURL) })
            var insertedCount = 0

            for repo in importedRepos {
                let repoPath = normalizePath(repo.localURL)
                guard !currentPaths.contains(repoPath) else { continue }
                modelContext.insert(repo)
                currentPaths.insert(repoPath)
                insertedCount += 1
            }

            guard insertedCount > 0 else { return 0 }

            if !saveModelContext(action: "auto-import repositories from ~/code") {
                modelContext.rollback()
                return 0
            }

            return insertedCount
        }
    }

    private func normalizePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func paneCount(for key: HostTerminalSessionKey) -> Int {
        workspacePresentationController.paneCount(
            for: key,
            paneCountBySessionKey: paneCountBySessionKey
        )
    }

    private func sessionKey(for workspace: Workspace) -> HostTerminalSessionKey {
        workspacePresentationController.sessionKey(
            for: workspace,
            registry: workspaceProviderRegistry,
            normalizePath: normalizePath(_:)
        )
    }

    private func sessionActivity(for key: HostTerminalSessionKey) -> SidebarSessionActivity {
        workspacePresentationController.sessionActivity(
            for: key,
            paneCountBySessionKey: paneCountBySessionKey,
            activeSessionKey: activeSessionKey,
            sessions: hostSessions,
            agentStatusBySessionID: agentStatusBySessionID
        )
    }

    /// One summary per terminal tab sharing `key`, in session order. Each carries
    /// its display title and agent status (when that tab runs a known agent).
    private func tabSummaries(for key: HostTerminalSessionKey) -> [SidebarTabSummary] {
        let normalizedKey = key.normalized()
        return
            hostSessions
            .filter { $0.key == normalizedKey }
            .map { session in
                let agentStatus = agentStatusBySessionID[session.id]
                let title = titleForSession(session)
                // Plain tabs prefer the real foreground process name; agent tabs keep their
                // agent-driven title unchanged.
                let displayTitle =
                    agentStatus == nil
                    ? TerminalForegroundProcessResolver.preferredTabTitle(
                        foregroundName: foregroundNameBySessionID[session.id],
                        terminalTitle: title)
                    : title
                // Only Claude Code tabs carry a transcript tail. Gating on the current kind (not
                // just presence of a cached entry) keeps a stale tail from a prior Claude session
                // from leaking onto a non-Claude agent that later reuses the same host session id.
                let transcriptTail =
                    agentStatus?.kind == .claudeCode ? transcriptTailBySessionID[session.id] : nil
                return SidebarTabSummary(
                    id: session.id,
                    title: displayTitle,
                    agentStatus: agentStatus,
                    transcriptTail: transcriptTail
                )
            }
    }

    private func tabSummaries(for workspace: Workspace) -> [SidebarTabSummary] {
        tabSummaries(for: sessionKey(for: workspace))
    }

    /// Kicks off async foreground-process resolution for the plain (non-agent) tabs under
    /// `key`, updating `foregroundNameBySessionID` when a name resolves. Fire-and-forget and
    /// idempotent — the resolver caches for ~2s and this writes only on change — so it is safe
    /// to call from the hover card's lazy `tabsProvider`. Resolves in every multiplexing mode
    /// (tmux pane command when available, otherwise the directory's running program).
    private func refreshForegroundProcessNames(for key: HostTerminalSessionKey) {
        let mode = TerminalMultiplexingMode.resolve()
        let normalizedKey = key.normalized()
        let plainSessions = hostSessions.filter {
            $0.key == normalizedKey && agentStatusBySessionID[$0.id] == nil
        }
        guard !plainSessions.isEmpty else { return }
        let resolver = foregroundResolver
        Task { @MainActor in
            for session in plainSessions {
                let name = await resolver.foregroundName(for: session, mode: mode)
                if let name, foregroundNameBySessionID[session.id] != name {
                    foregroundNameBySessionID[session.id] = name
                } else if name == nil, foregroundNameBySessionID[session.id] != nil {
                    foregroundNameBySessionID.removeValue(forKey: session.id)
                }
            }
        }
    }

    /// Kicks off async transcript-tail resolution for the Claude Code agent tabs under `key`,
    /// updating `transcriptTailBySessionID` when a message resolves. Fire-and-forget and
    /// idempotent — the resolver caches per file for a short TTL and this writes only on change —
    /// so it is safe to call from the hover card's lazy `tabsProvider`. Non-Claude tabs and every
    /// read/parse failure resolve to absent (#680).
    private func refreshTranscriptTails(for key: HostTerminalSessionKey) {
        let normalizedKey = key.normalized()
        let agentSessions = hostSessions.filter {
            $0.key == normalizedKey && agentStatusBySessionID[$0.id]?.kind == .claudeCode
        }
        guard !agentSessions.isEmpty else { return }
        let resolver = transcriptTailResolver
        Task { @MainActor in
            for session in agentSessions {
                guard let status = agentStatusBySessionID[session.id] else { continue }
                let tail = await resolver.tail(
                    cwd: status.cwd, agentSessionID: status.agentSessionID, kind: status.kind)
                if let tail, transcriptTailBySessionID[session.id] != tail {
                    transcriptTailBySessionID[session.id] = tail
                } else if tail == nil, transcriptTailBySessionID[session.id] != nil {
                    transcriptTailBySessionID.removeValue(forKey: session.id)
                }
            }
        }
    }

    /// Merge the repo's own-session baseline with the aggregator-bubbled state derived
    /// from its child workspaces. Most-severe wins, so a yellow `awaitingInput` child
    /// shows on a collapsed repo row even when the repo's own terminal is idle.
    private func bubbledRepoActivity(
        for repo: Repo,
        baseline: SidebarSessionActivity
    ) -> SidebarSessionActivity {
        guard let bubbledStatus = workspaceStatusAggregator.repoStatuses[repo.id] else {
            return baseline
        }
        return baseline.mergedWithBubbled(SidebarSessionActivity.from(bubbledStatus))
    }

    /// Tooltip that explains the bubbled state when it differs from the baseline,
    /// e.g., "2 workspaces awaiting input".
    private func bubbleTooltip(
        for repo: Repo,
        bubbled: SidebarSessionActivity,
        baseline: SidebarSessionActivity
    ) -> String? {
        guard bubbled != baseline else { return nil }
        let attentionCount = repo.workspaces.reduce(into: 0) { count, workspace in
            guard let status = workspaceStatusAggregator.workspaceStatuses[workspace.id] else { return }
            if AgentChromeProjection.demandsAttention(status.run) { count += 1 }
        }
        guard attentionCount > 0 else { return nil }
        switch bubbled {
        case .errored:
            return "\(attentionCount) workspace\(attentionCount == 1 ? "" : "s") need attention"
        case .awaitingInput:
            return "\(attentionCount) workspace\(attentionCount == 1 ? "" : "s") awaiting input"
        default:
            return nil
        }
    }

    private func workspaceStatusMessage(_ workspace: Workspace) -> String? {
        workspacePresentationController.workspaceStatusMessage(
            workspaceID: workspace.id,
            connectingWorkspaceID: connectingWorkspaceID,
            workspaceAction: workspaceAction
        )
    }

    private func usesHostWorkspaceFiles(for workspace: Workspace) -> Bool {
        workspacePresentationController.usesHostWorkspaceFiles(
            for: workspace,
            registry: workspaceProviderRegistry
        )
    }

    private func providerDescriptor(for workspace: Workspace) -> WorkspaceProviderDescriptor? {
        workspacePresentationController.providerDescriptor(
            for: workspace,
            registry: workspaceProviderRegistry
        )
    }

    private func providerDisplayName(for providerID: String) -> String {
        workspacePresentationController.providerDisplayName(
            for: providerID,
            registry: workspaceProviderRegistry
        )
    }

    private func environmentOptions(for repo: Repo) -> [WorkspaceEnvironmentSheetOption] {
        workspaceEnvironmentOptionsController.environmentOptions(
            for: repo,
            registry: workspaceProviderRegistry,
            sheetState: workspaceEnvironmentSheetState
        )
    }

    @MainActor
    private func refreshWorkspaceEnvironmentState(trigger: String) async {
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

    @MainActor
    private func seedFixtureProviderStateIfNeeded() async -> Bool {
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

    private func initialCreationMessage(for providerID: String) -> String {
        switch providerID {
        case DaytonaWorkspaceProvider.identifier:
            return "Creating cloud workspace..."
        case LumeWorkspaceProvider.identifier:
            return "Preparing VM workspace..."
        default:
            return SidebarWorkspaceController.localCreationMessage(for: .preparing)
        }
    }

    private func normalizeWebURLString(_ rawURL: String) -> String {
        if let normalized = try? WebSourceValidation.normalizeBaseURL(rawURL) {
            return normalized.baseURL.absoluteString
        }
        return rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sortedWorkspaces(for repo: Repo) -> [Workspace] {
        repo.workspaces.sorted { lhs, rhs in
            lhs.lastAccessedAt > rhs.lastAccessedAt
        }
    }

    private func activeWorkspaces(for repo: Repo) -> [Workspace] {
        sortedWorkspaces(for: repo).filter { $0.status != .archived }
    }

    private func archivedWorkspaces(for repo: Repo) -> [Workspace] {
        sortedWorkspaces(for: repo).filter { $0.status == .archived }
    }

    /// Collapsed by default; auto-expands when the selected workspace is archived so a
    /// restored selection isn't hidden inside a collapsed section.
    private func isArchivedSectionExpanded(_ repo: Repo) -> Bool {
        if expandedArchivedRepoIDs.contains(repo.id) {
            return true
        }
        if let selected = selectedWorkspace,
            selected.status == .archived,
            selected.sourceRepo?.id == repo.id
        {
            return true
        }
        return false
    }

    private func toggleArchivedSection(for repo: Repo) {
        if expandedArchivedRepoIDs.contains(repo.id) {
            expandedArchivedRepoIDs.remove(repo.id)
        } else {
            expandedArchivedRepoIDs.insert(repo.id)
        }
    }

    private func sortedRepoWebSources(for repo: Repo) -> [WebSource] {
        repo.webSources.sorted { lhs, rhs in
            lhs.lastAccessedAt > rhs.lastAccessedAt
        }
    }

    private func sortedWorkspaceWebSources(for workspace: Workspace) -> [WebSource] {
        workspace.webSources.sorted { lhs, rhs in
            lhs.lastAccessedAt > rhs.lastAccessedAt
        }
    }

    private func isRepoExpanded(_ repo: Repo) -> Bool {
        expansionController.isRepoExpanded(repo.id)
    }

    private func toggleRepoExpansion(_ repo: Repo) {
        expansionController.toggleRepoExpansion(repo.id)
    }

    private func isWorkspaceExpanded(_ workspace: Workspace) -> Bool {
        expansionController.isWorkspaceExpanded(workspace.id)
    }

    private func toggleWorkspaceExpansion(_ workspace: Workspace) {
        expansionController.toggleWorkspaceExpansion(
            workspace.id,
            hasWebSources: !workspace.webSources.isEmpty
        )
    }

    private func initializeExpandedReposIfNeeded() {
        expansionController.initializeRepoExpansionIfNeeded(
            repoIDs: repos.map(\.id),
            selectedWorkspaceRepoID: selectedWorkspace?.sourceRepo?.id,
            isUIFixtureMode: isUIFixtureMode
        )
    }

    private func expandRepoForSelectedWorkspace() {
        expansionController.expandSelectedWorkspace(
            workspaceID: selectedWorkspace?.id,
            repoID: selectedWorkspace?.sourceRepo?.id,
            hasWebSources: selectedWorkspace?.webSources.isEmpty == false
        )
    }

    private func expandContainersForSelectedWebSource() {
        expansionController.expandSelectedWebSource(
            repoID: selectedWebSource?.ownerRepo?.id,
            workspaceID: selectedWebSource?.sourceWorkspace?.id
        )
    }

    private func pruneExpandedContainers() {
        expansionController.prune(
            validRepoIDs: Set(repos.map(\.id)),
            validWorkspaceIDs: Set(repos.flatMap(\.workspaces).map(\.id))
        )
    }

    private func updateRepoSortMode(_ mode: SidebarRepoSortMode) {
        repoSortModeRawValue = mode.rawValue
        syncRepoSortSnapshot(forceRefresh: true)
        syncRecentSnapshot(forceRefresh: true)
    }

    private func syncRepoSortSnapshot(forceRefresh: Bool = false) {
        guard repoSortMode == .lastAccessed else {
            repoLastAccessedSnapshotByID.removeAll()
            return
        }

        let currentRepoIDs = Set(repos.map(\.id))
        repoLastAccessedSnapshotByID = repoSortController.prunedSnapshot(
            repoLastAccessedSnapshotByID,
            validRepoIDs: currentRepoIDs
        )

        if forceRefresh || repoLastAccessedSnapshotByID.isEmpty {
            repoLastAccessedSnapshotByID = repoSortController.snapshot(for: repos)
        }
    }

    /// Re-reads the dates the Recent arrangement orders and buckets by. Called on mode
    /// change, on appear, when the repo or workspace set changes, and when the app resigns
    /// active — never during ordinary redraws, so rows never move under the cursor. Resign
    /// rather than become: the mouse-down that reactivates the window can click through to
    /// a row, and a refresh on activation would move that row first.
    private func syncRecentSnapshot(forceRefresh: Bool) {
        guard repoSortMode == .recent else {
            if !recentSnapshotByID.isEmpty {
                recentSnapshotByID.removeAll()
            }
            return
        }

        recentSnapshotByID = SidebarRecentArrangement.prunedSnapshot(
            recentSnapshotByID,
            validIDs: SidebarRecentArrangement.identifiers(in: repos)
        )

        if forceRefresh || recentSnapshotByID.isEmpty {
            recentSnapshotByID = SidebarRecentArrangement.snapshot(for: repos)
            recentSnapshotTakenAt = Date()
        }
    }
}
