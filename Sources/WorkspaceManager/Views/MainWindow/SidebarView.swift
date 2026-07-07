//
//  SidebarView.swift
//  WorkspaceManager
//
//  Left sidebar showing repositories and workspaces
//

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

private struct NewWorkspaceSheetContext: Identifiable {
    let repo: Repo

    var id: UUID { repo.id }
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
    let onWorkspaceCreated: () -> Void
    let retireTerminalSessions: @MainActor (HostTerminalSessionKey) async throws -> Void
    let workspaceProviderSetupCoordinator: WorkspaceProviderSetupCoordinator
    let hostLumeSmokeAutomation: HostLumeSmokeAutomationController
    let desktopUISmokeAutomation: DesktopUISmokeAutomationController

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
    @State private var isPreparingNewWorkspaceSheet = false

    /// Real foreground process name per plain terminal tab, resolved lazily when a hover
    /// card opens and preferred over the terminal title. Populated by
    /// `refreshForegroundProcessNames`; empty in ghostty-splits mode (see #666).
    @State private var foregroundNameBySessionID: [UUID: String] = [:]
    private let foregroundResolver = TerminalForegroundProcessResolver()

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

    private var repoSortMode: SidebarRepoSortMode {
        SidebarRepoSortMode(rawValue: repoSortModeRawValue) ?? .alphabetical
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
            Task { @MainActor in
                await maybeDriveHostLumeSmokeAutomation()
            }
            Task { @MainActor in
                await maybeDriveDesktopUISmokeAutomation()
            }
        }
        .onChange(of: repoSortModeRawValue) { _, _ in
            syncRepoSortSnapshot(forceRefresh: true)
        }
        .onAppear {
            initializeExpandedReposIfNeeded()
            expandContainersForSelectedWebSource()
            syncRepoSortSnapshot(forceRefresh: false)
            guard !isRepoAutoImportDisabled else { return }
            guard !didAttemptDefaultRepoImport else { return }
            didAttemptDefaultRepoImport = true
            Task {
                await autoImportReposFromCodeHome()
            }
        }
        .task {
            _ = await seedFixtureProviderStateIfNeeded()
            await maybeDriveHostLumeSmokeAutomation()
            await maybeDriveDesktopUISmokeAutomation()
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
                await hostLumeSmokeAutomation.noteFailure(
                    message: message,
                    recoveryHints: hostLumeSmokeRecoveryHints(for: message)
                )
            }
            Task { @MainActor in
                await desktopUISmokeAutomation.noteFailure(message: message)
            }
        }
    }

    private var sidebarList: some View {
        List {
            repositoriesSection

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
        if let repo = selectedRepo, !isRepoExpanded(repo) {
            toggleRepoExpansion(repo)
            return .handled
        }
        return .ignored
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

    private var repositoriesHeader: some View {
        HStack(spacing: 8) {
            Text("Repositories")
            Spacer(minLength: 8)
            if !repos.isEmpty {
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

    @ViewBuilder
    private func repoListRow(_ repo: Repo) -> some View {
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
            isExpanded: isRepoExpanded(repo),
            sessionActivityTooltip: bubbleTooltip(for: repo, bubbled: bubbledActivity, baseline: baselineActivity),
            onToggleExpansion: {
                toggleRepoExpansion(repo)
            },
            onSelectRepo: {
                sidebarHasKeyFocus = true
                if !isRepoExpanded(repo) {
                    expansionController.expandRepo(repo.id)
                }
                if paneCount(for: repoSessionKey) > 0 {
                    onRepoTerminalSelected(repo)
                } else {
                    onRepoSelected(repo)
                }
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

            Divider()

            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.localPath)
            }

            Divider()

            Button("Remove from List", role: .destructive) {
                removeRepo(repo)
            }
        }

        if isRepoExpanded(repo) {
            repoChildrenList(repo)
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
    private func workspaceRow(_ workspace: Workspace) -> some View {
        WorkspaceRow(
            workspace: workspace,
            isSelected: selectedWorkspace?.id == workspace.id,
            statusMessage: workspaceStatusMessage(workspace),
            sessionActivity: sessionActivity(for: sessionKey(for: workspace)),
            paneCount: paneCount(for: sessionKey(for: workspace)),
            isNested: true,
            isExpanded: isWorkspaceExpanded(workspace),
            showsDisclosure: !workspace.webSources.isEmpty,
            tabsProvider: {
                refreshForegroundProcessNames(for: sessionKey(for: workspace))
                return tabSummaries(for: workspace)
            },
            onToggleExpansion: {
                toggleWorkspaceExpansion(workspace)
            },
            onSelect: {
                selectWorkspace(workspace)
            }
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

            if workspace.backend == .local {
                localWorkspaceActions(workspace)
            } else {
                providerWorkspaceActions(workspace)
            }

            Divider()

            Button("Delete Workspace", role: .destructive) {
                deleteWorkspace(workspace)
            }
        }

        if isWorkspaceExpanded(workspace) {
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
    private func createWorkspace(
        from repo: Repo,
        name: String,
        nameSource: WorkspaceNameSource,
        providerID: String,
        guestOS: WorkspaceGuestOS? = nil
    ) async {
        guard let provider = workspaceProviderRegistry.provider(for: providerID) else {
            presentSidebarError("Workspace provider '\(providerID)' is not registered.")
            return
        }

        do {
            try await workspaceProviderSetupActionRunner.run(
                provider: provider,
                action: .createWorkspace(name: name, guestOS: guestOS)
            ) {
                await refreshWorkspaceEnvironmentState(trigger: "workspace_create_after_setup")
                await createWorkspaceAfterSetup(
                    from: repo,
                    name: name,
                    nameSource: nameSource,
                    providerID: providerID,
                    guestOS: guestOS
                )
            } perform: {
                await createWorkspaceAfterSetup(
                    from: repo,
                    name: name,
                    nameSource: nameSource,
                    providerID: providerID,
                    guestOS: guestOS
                )
            }
        } catch {
            presentSidebarError(error.localizedDescription)
        }
    }

    @MainActor
    private func createWorkspaceAfterSetup(
        from repo: Repo,
        name: String,
        nameSource: WorkspaceNameSource,
        providerID: String,
        guestOS: WorkspaceGuestOS? = nil
    ) async {
        let repoID = repo.id
        guard !isCreatingWorkspace(for: repoID) else { return }
        expansionController.expandRepo(repoID)
        workspaceCreationStatusByRepoID[repoID] = WorkspaceCreationStatus(
            message: initialCreationMessage(for: providerID)
        )
        await hostLumeSmokeAutomation.noteWorkspacePhaseChanged(
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
                progress: { phase in
                    creationLog.debug("createWorkspaceAfterSetup: progress phase=\(phase)")
                    await MainActor.run {
                        workspaceCreationStatusByRepoID[repoID] = WorkspaceCreationStatus(message: phase)
                    }
                    await hostLumeSmokeAutomation.noteWorkspacePhaseChanged(message: phase)
                },
                onPersisted: { record in
                    await hostLumeSmokeAutomation.noteWorkspacePersisted(record)
                }
            )
            creationLog.info("createWorkspaceAfterSetup: workspace created, updating selection")
            workspaceCreationStatusByRepoID.removeValue(forKey: repoID)
            onWorkspaceCreated()
            selectedWorkspace = workspace
            await hostLumeSmokeAutomation.noteWorkspaceActive(
                HostLumeSmokeWorkspaceRecord(workspace: workspace)
            )
        } catch {
            creationLog.error(
                "createWorkspaceAfterSetup: failed: \(error.localizedDescription)"
            )
            workspaceCreationStatusByRepoID.removeValue(forKey: repoID)
            let providerName = providerDisplayName(for: providerID)
            presentSidebarError("Failed to create \(providerName) workspace: \(error.localizedDescription)")
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
    private func maybeDriveHostLumeSmokeAutomation() async {
        guard hostLumeSmokeAutomation.isEnabled else { return }
        guard let targetRepoURL = hostLumeSmokeAutomation.targetRepoURL else { return }

        if let matchedRepo = hostLumeSmokeAutomation.matchingRepo(in: repos, normalizePath: normalizePath(_:)) {
            await hostLumeSmokeAutomation.noteRepoReady(matchedRepo)

            guard hostLumeSmokeAutomation.shouldStartWorkspaceCreation() else { return }
            await hostLumeSmokeAutomation.noteWorkspaceCreationStarted(repo: matchedRepo)
            await createWorkspace(
                from: matchedRepo,
                name: hostLumeSmokeAutomation.targetWorkspaceName ?? "lume-smoke",
                nameSource: .manual,
                providerID: LumeWorkspaceProvider.identifier,
                guestOS: .macOS
            )
            return
        }

        guard FileManager.default.fileExists(atPath: targetRepoURL.path) else {
            let message = "Smoke repo path does not exist: \(targetRepoURL.path)"
            presentSidebarError(message)
            return
        }

        await addRepo(from: targetRepoURL)
    }

    /// Drives the daily-driver desktop flows for the `desktop-ui-smoke`
    /// automation mode: import the target repo if needed, create a local
    /// workspace, confirm it lands in the sidebar with a live terminal, then
    /// switch selection to the repo terminal and back to prove the surface
    /// follows selection. Milestones stream to the events JSONL the host smoke
    /// script asserts against.
    @MainActor
    private func maybeDriveDesktopUISmokeAutomation() async {
        guard desktopUISmokeAutomation.isEnabled else { return }
        guard let targetRepoURL = desktopUISmokeAutomation.targetRepoURL else { return }

        guard
            let repo = desktopUISmokeAutomation.matchingRepo(
                in: repos,
                normalizePath: normalizePath(_:)
            )
        else {
            guard FileManager.default.fileExists(atPath: targetRepoURL.path) else {
                let message = "Desktop UI smoke repo path does not exist: \(targetRepoURL.path)"
                presentSidebarError(message)
                return
            }
            await addRepo(from: targetRepoURL)
            return
        }

        await desktopUISmokeAutomation.noteRepoReady(repo)
        guard desktopUISmokeAutomation.shouldStartScenario() else { return }
        await runDesktopUISmokeScenario(repo: repo)
    }

    @MainActor
    private func runDesktopUISmokeScenario(repo: Repo) async {
        let workspaceName = desktopUISmokeAutomation.targetWorkspaceName ?? "desktop-ui-smoke"

        await desktopUISmokeAutomation.noteWorkspaceCreationStarted(repo: repo)

        let focusBaselineBeforeCreate = desktopUISmokeAutomation.surfaceFocusCount
        await createWorkspace(
            from: repo,
            name: workspaceName,
            nameSource: .manual,
            providerID: LocalWorkspaceProvider.identifier
        )

        guard let workspace = selectedWorkspace else {
            await desktopUISmokeAutomation.noteFailure(
                message: "Local workspace was not created or selected."
            )
            return
        }

        await desktopUISmokeAutomation.noteWorkspaceCreated(workspace)
        await emitDesktopUISmokeSidebarUpdate(for: workspace)

        // Flow 1: the freshly created workspace's terminal becomes ready.
        _ = await desktopUISmokeAutomation.waitForSurfaceFocus(
            after: focusBaselineBeforeCreate,
            timeout: .seconds(15)
        )

        // Flow 2: switch selection to the repo terminal, then back to the
        // workspace. Distinct attached session IDs prove the surface follows
        // selection rather than stranding a stale session.
        let focusBaselineBeforeRepo = desktopUISmokeAutomation.surfaceFocusCount
        onRepoTerminalSelected(repo)
        _ = await desktopUISmokeAutomation.waitForSurfaceFocus(
            after: focusBaselineBeforeRepo,
            timeout: .seconds(15)
        )

        let focusBaselineBeforeReselect = desktopUISmokeAutomation.surfaceFocusCount
        selectWorkspace(workspace)
        _ = await desktopUISmokeAutomation.waitForSurfaceFocus(
            after: focusBaselineBeforeReselect,
            timeout: .seconds(15)
        )

        // Flow 3: web main content renders through the Surface seam, then returning to the
        // workspace routes a terminal session again (session routing is the hard gate; surface
        // focus stays best-effort in headless runs, like Flows 1–2). about:blank keeps the gate
        // network-independent — the milestone is the surface mount, not a page load.
        if let webSource = ensureDesktopUISmokeWebSource() {
            let webBaseline = desktopUISmokeAutomation.webSurfaceAttachCount
            onWebSourceSelected(webSource)
            let webAttached = await desktopUISmokeAutomation.waitForWebSurfaceAttach(
                after: webBaseline,
                timeout: .seconds(10)
            )
            if !webAttached {
                await desktopUISmokeAutomation.noteFailure(
                    message: "Web surface did not mount after web source selection."
                )
            }

            let focusBaselineAfterWeb = desktopUISmokeAutomation.surfaceFocusCount
            selectWorkspace(workspace)
            _ = await desktopUISmokeAutomation.waitForSurfaceFocus(
                after: focusBaselineAfterWeb,
                timeout: .seconds(15)
            )
        }

        await desktopUISmokeAutomation.noteScenarioComplete()
    }

    /// The web source Flow 3 selects, created on first run. `about:blank` renders without network.
    @MainActor
    private func ensureDesktopUISmokeWebSource() -> WebSource? {
        let name = "desktop-ui-smoke-web"
        if let existing = webSources.first(where: { $0.name == name }) {
            return existing
        }
        let source = WebSource(name: name, baseURLString: "about:blank", allowedHost: "")
        modelContext.insert(source)
        guard saveModelContext(action: "create desktop-ui-smoke web source") else { return nil }
        return source
    }

    /// Confirms the new workspace is present under its repo in the live sidebar
    /// model before emitting `sidebar_updated`, polling briefly because the
    /// `@Query` repo list can lag a save by a run loop.
    @MainActor
    private func emitDesktopUISmokeSidebarUpdate(for workspace: Workspace) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let sidebarWorkspaces = repos.flatMap(\.workspaces)
            if sidebarWorkspaces.contains(where: { $0.id == workspace.id }) {
                await desktopUISmokeAutomation.noteSidebarUpdated(
                    workspace: workspace,
                    sidebarWorkspaceCount: sidebarWorkspaces.count
                )
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await desktopUISmokeAutomation.noteFailure(
            message: "Created workspace did not appear in the sidebar: \(workspace.name)"
        )
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
                return SidebarTabSummary(
                    id: session.id,
                    title: displayTitle,
                    agentStatus: agentStatus
                )
            }
    }

    private func tabSummaries(for workspace: Workspace) -> [SidebarTabSummary] {
        tabSummaries(for: sessionKey(for: workspace))
    }

    /// Kicks off async foreground-process resolution for the plain (non-agent) tabs under
    /// `key`, updating `foregroundNameBySessionID` when a name resolves. Fire-and-forget and
    /// idempotent — the resolver caches for ~2s and this writes only on change — so it is safe
    /// to call from the hover card's lazy `tabsProvider`. No-ops outside tmux-per-session mode,
    /// where foreground detection is not available (see #666).
    private func refreshForegroundProcessNames(for key: HostTerminalSessionKey) {
        let mode = TerminalMultiplexingMode.resolve()
        guard mode == .tmuxPerSession else { return }
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
}
