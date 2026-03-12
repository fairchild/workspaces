//
//  SidebarView.swift
//  WorkspaceManager
//
//  Left sidebar showing repositories and workspaces
//

import SwiftData
import SwiftUI
import WorkspaceManagerCore

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
    let repos: [Repo]
    let webSources: [WebSource]
    let selectedRepo: Repo?
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedWebSource: WebSource?
    let paneCountBySessionKey: [HostTerminalSessionKey: Int]
    let activeSessionKey: HostTerminalSessionKey?
    let connectingWorkspaceID: UUID?
    let onRepoSelected: (Repo) -> Void
    let onRepoTerminalSelected: (Repo) -> Void
    let onWebSourceSelected: (WebSource) -> Void
    let onRequestWebSourceCreation: (WebSourceCreationTarget) -> Void
    let onWorkspaceCreated: () -> Void
    let lumeSetupCoordinator: LumeSetupCoordinator
    let hostLumeSmokeAutomation: HostLumeSmokeAutomationController

    @AppStorage(SidebarRepoSortMode.storageKey)
    private var repoSortModeRawValue: String = SidebarRepoSortMode.alphabetical.rawValue

    @State private var isAddingRepo = false
    @State private var newWorkspaceSheetContext: NewWorkspaceSheetContext?
    @State private var providerAvailabilityByID: [String: WorkspaceProviderAvailability] =
        UIFixtureLumeEnvironment.initialProviderAvailabilityByID()
    @State private var isRefreshingProviderAvailability = false
    @State private var lumeRuntimeSnapshot: LumeRuntimeSnapshot? =
        UIFixtureLumeEnvironment.initialRuntimeSnapshot()

    // Error alert state
    @State private var errorMessage: String?
    @State private var showingError = false

    // Delete confirmation state
    @State private var workspaceToDelete: Workspace?
    @State private var showingDeleteConfirmation = false

    @State private var didAttemptDefaultRepoImport = false
    @State private var expandedRepoIDs: Set<UUID> = []
    @State private var expandedWorkspaceIDs: Set<UUID> = []
    @State private var didInitializeRepoExpansion = false
    @State private var workspaceAction: WorkspaceActionState?
    @State private var workspaceCreationStatusByRepoID: [UUID: WorkspaceCreationStatus] = [:]
    @State private var repoLastAccessedSnapshotByID: [UUID: Date] = [:]

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
            workspaceProviderRegistry: workspaceProviderRegistry
        )
    }

    private var repoSortController: SidebarRepoSortController {
        SidebarRepoSortController()
    }

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
                .id(newWorkspaceSheetRefreshID(for: context.repo))
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}

                if shouldOfferLumeRecoveryActions {
                    Button("Open VM Runtime") {
                        openSettingsWindow()
                    }

                    Button("Open Lume Log") {
                        openLumeLog()
                    }
                }
            } message: {
                Text(errorMessage ?? "An unknown error occurred")
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
            .focusedSceneValue(\.newWorkspaceAction, handleNewWorkspaceShortcut)
            .onChange(of: selectedWorkspace?.id) { _, _ in
                expandRepoForSelectedWorkspace()
            }
            .onChange(of: selectedWebSource?.id) { _, _ in
                expandContainersForSelectedWebSource()
            }
            .onChange(of: repos.map(\.id)) { _, _ in
                pruneExpandedRepos()
                pruneExpandedWorkspaces()
                syncRepoSortSnapshot()
                Task { @MainActor in
                    await maybeDriveHostLumeSmokeAutomation()
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
                if await seedFixtureProviderStateIfNeeded() {
                    return
                }
                await refreshProviderAvailability()
                await refreshLumeRuntimeSnapshot()
                await maybeDriveHostLumeSmokeAutomation()
            }
            .onChange(of: errorMessage) { _, message in
                guard let message else { return }
                Task { @MainActor in
                    await hostLumeSmokeAutomation.noteFailure(
                        message: message,
                        recoveryHints: hostLumeSmokeRecoveryHints(for: message)
                    )
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

        RepoRow(
            repo: repo,
            sessionActivity: sessionActivity(for: repoSessionKey),
            paneCount: paneCount(for: repoSessionKey),
            isSelected: selectedRepo?.id == repo.id,
            isExpanded: isRepoExpanded(repo),
            onToggleExpansion: {
                toggleRepoExpansion(repo)
            },
            onSelectRepo: {
                if !isRepoExpanded(repo) {
                    expandedRepoIDs.insert(repo.id)
                }
                onRepoSelected(repo)
            },
            onNewWorkspace: {
                Task { @MainActor in
                    await prepareNewWorkspaceSheet(for: repo)
                }
            },
            onNewWebView: {
                onRequestWebSourceCreation(.repo(repo))
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
        let repoWorkspaces = sortedWorkspaces(for: repo)

        if !repoWorkspaces.isEmpty {
            ForEach(repoWorkspaces) { workspace in
                WorkspaceRow(
                    workspace: workspace,
                    isSelected: selectedWorkspace?.id == workspace.id,
                    statusMessage: workspaceStatusMessage(workspace),
                    sessionActivity: sessionActivity(for: sessionKey(for: workspace)),
                    paneCount: paneCount(for: sessionKey(for: workspace)),
                    isNested: true,
                    isExpanded: isWorkspaceExpanded(workspace),
                    showsDisclosure: !workspace.webSources.isEmpty,
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

                    if workspace.backendIdentifier == LocalWorkspaceProvider.identifier {
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
                errorMessage = "The selected folder is not a Git repository.\n\nPath: \(url.lastPathComponent)"
                showingError = true
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

    private var shouldOfferLumeRecoveryActions: Bool {
        !hostLumeSmokeRecoveryHints(for: errorMessage).isEmpty
    }

    private func openSettingsWindow() {
        let selector = Selector(("showSettingsWindow:"))
        if NSApp.sendAction(selector, to: nil, from: nil) {
            return
        }

        _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
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

        errorMessage = "No Lume log file is available yet."
        showingError = true
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
        let effectiveGuestOS =
            providerID == LumeWorkspaceProvider.identifier ? (guestOS ?? .macOS) : guestOS

        if providerID == LumeWorkspaceProvider.identifier {
            do {
                let intercepted = try await lumeSetupCoordinator.prepareIfNeeded(
                    for: .createWorkspace(name: name, guestOS: effectiveGuestOS ?? .macOS)
                ) {
                    await refreshLumeRuntimeSnapshot()
                    await createWorkspaceAfterSetup(
                        from: repo,
                        name: name,
                        nameSource: nameSource,
                        providerID: providerID,
                        guestOS: effectiveGuestOS
                    )
                }
                if intercepted {
                    return
                }
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
                return
            }
        }

        await createWorkspaceAfterSetup(
            from: repo,
            name: name,
            nameSource: nameSource,
            providerID: providerID,
            guestOS: effectiveGuestOS
        )
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
        expandedRepoIDs.insert(repoID)
        workspaceCreationStatusByRepoID[repoID] = WorkspaceCreationStatus(
            message: initialCreationMessage(for: providerID)
        )
        await hostLumeSmokeAutomation.noteWorkspacePhaseChanged(
            message: initialCreationMessage(for: providerID)
        )

        do {
            let workspace = try await workspaceController.createWorkspace(
                from: repo,
                name: name,
                nameSource: nameSource,
                providerID: providerID,
                guestOS: guestOS,
                progress: { phase in
                    await MainActor.run {
                        workspaceCreationStatusByRepoID[repoID] = WorkspaceCreationStatus(message: phase)
                    }
                    await hostLumeSmokeAutomation.noteWorkspacePhaseChanged(message: phase)
                },
                onPersisted: { record in
                    await hostLumeSmokeAutomation.noteWorkspacePersisted(record)
                }
            )
            workspaceCreationStatusByRepoID.removeValue(forKey: repoID)
            onWorkspaceCreated()
            selectedWorkspace = workspace
            await hostLumeSmokeAutomation.noteWorkspaceActive(
                HostLumeSmokeWorkspaceRecord(workspace: workspace)
            )
        } catch {
            workspaceCreationStatusByRepoID.removeValue(forKey: repoID)
            let providerName = providerDisplayName(for: providerID)
            errorMessage = "Failed to create \(providerName) workspace: \(error.localizedDescription)"
            showingError = true
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
            errorMessage = "Failed to delete workspace: \(error.localizedDescription)"
            showingError = true
        }
        workspaceToDelete = nil
    }

    @ViewBuilder
    private func localWorkspaceActions(_ workspace: Workspace) -> some View {
        if workspace.status == .active {
            Button("Archive") {
                toggleLocalWorkspaceArchive(workspace, archived: true)
            }
        } else {
            Button("Unarchive") {
                toggleLocalWorkspaceArchive(workspace, archived: false)
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

    private func toggleLocalWorkspaceArchive(_ workspace: Workspace, archived: Bool) {
        workspace.status = archived ? .archived : .active
        if !saveModelContext(action: archived ? "archive workspace" : "unarchive workspace") {
            modelContext.rollback()
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
                errorMessage = "Failed to stop workspace: \(error.localizedDescription)"
                showingError = true
            }
        }
    }

    private func performStart(_ workspace: Workspace) {
        Task { @MainActor in
            if workspace.backendIdentifier == LumeWorkspaceProvider.identifier {
                do {
                    let intercepted = try await lumeSetupCoordinator.prepareIfNeeded(
                        for: .startWorkspace(workspaceName: workspace.name)
                    ) {
                        await refreshLumeRuntimeSnapshot()
                        await performStartAfterSetup(workspace)
                    }
                    if intercepted {
                        return
                    }
                } catch {
                    errorMessage = error.localizedDescription
                    showingError = true
                    return
                }
            }

            await performStartAfterSetup(workspace)
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
            errorMessage = "Failed to start workspace: \(error.localizedDescription)"
            showingError = true
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
                errorMessage = "Failed to archive workspace: \(error.localizedDescription)"
                showingError = true
            }
        }
    }

    private func openDesktop(for workspace: Workspace) {
        Task { @MainActor in
            if workspace.backendIdentifier == LumeWorkspaceProvider.identifier {
                do {
                    let intercepted = try await lumeSetupCoordinator.prepareIfNeeded(
                        for: .openDesktop(workspaceName: workspace.name)
                    ) {
                        await refreshLumeRuntimeSnapshot()
                        await openDesktopAfterSetup(workspace)
                    }
                    if intercepted {
                        return
                    }
                } catch {
                    errorMessage = error.localizedDescription
                    showingError = true
                    return
                }
            }

            await openDesktopAfterSetup(workspace)
        }
    }

    @MainActor
    private func openDesktopAfterSetup(_ workspace: Workspace) async {
        guard let provider = workspaceProviderRegistry.provider(for: workspace) else {
            errorMessage = "No workspace provider is registered for '\(workspace.backendIdentifier)'."
            showingError = true
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
            errorMessage = "Failed to open desktop: \(error.localizedDescription)"
            showingError = true
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
            errorMessage = "Add a repository first, then create a workspace."
            showingError = true
            return
        }

        guard !isCreatingWorkspace(for: preferredRepo.id) else {
            errorMessage = "A workspace is already being created for '\(preferredRepo.name)'."
            showingError = true
            return
        }

        Task { @MainActor in
            await prepareNewWorkspaceSheet(for: preferredRepo)
        }
    }

    @MainActor
    private func prepareNewWorkspaceSheet(for repo: Repo) async {
        if providerAvailabilityIsPending {
            await refreshProviderAvailability()
        }

        await refreshLumeRuntimeSnapshot()

        newWorkspaceSheetContext = NewWorkspaceSheetContext(repo: repo)
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
            errorMessage = message
            showingError = true
            return
        }

        await addRepo(from: targetRepoURL)
    }

    @MainActor
    private func selectWorkspace(_ workspace: Workspace) {
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
            errorMessage = "Failed to \(action): \(error.localizedDescription)"
            showingError = true
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
        paneCountBySessionKey[key] ?? 0
    }

    private func sessionKey(for workspace: Workspace) -> HostTerminalSessionKey {
        if let provider = workspaceProviderRegistry.provider(for: workspace) {
            return provider.sessionKey(for: WorkspaceProviderTarget(workspace))
        }

        return .hostPath(normalizePath(workspace.workspaceURL))
    }

    private func sessionActivity(for key: HostTerminalSessionKey) -> SidebarSessionActivity {
        SidebarSessionActivity(
            hasLiveSession: paneCount(for: key) > 0,
            isActiveSession: activeSessionKey == key
        )
    }

    private func workspaceStatusMessage(_ workspace: Workspace) -> String? {
        if connectingWorkspaceID == workspace.id { return "Connecting..." }
        if let action = workspaceAction, action.workspaceID == workspace.id { return action.message }
        return nil
    }

    private func usesHostWorkspaceFiles(for workspace: Workspace) -> Bool {
        providerDescriptor(for: workspace)?.usesHostWorkspaceFiles ?? !workspace.isRemote
    }

    private func providerDescriptor(for workspace: Workspace) -> WorkspaceProviderDescriptor? {
        workspaceProviderRegistry.provider(for: workspace)?.descriptor
    }

    private func providerDisplayName(for providerID: String) -> String {
        workspaceProviderRegistry.provider(for: providerID)?.descriptor.displayName ?? providerID
    }

    private var providerAvailabilityIsPending: Bool {
        workspaceProviderRegistry.providers.contains { provider in
            providerAvailabilityByID[provider.descriptor.id] == nil
        }
    }

    private var providerAvailabilityRefreshSignature: String {
        workspaceProviderRegistry.providers
            .map(\.descriptor.id)
            .sorted()
            .map { providerID in
                guard let availability = providerAvailabilityByID[providerID] else {
                    return "\(providerID):pending"
                }

                return "\(providerID):\(availability.isAvailable):\(availability.reason ?? "")"
            }
            .joined(separator: "|")
    }

    private var lumeRuntimeRefreshSignature: String {
        guard let snapshot = lumeRuntimeSnapshot else {
            return "runtime:pending"
        }

        return [
            snapshot.state.rawValue,
            snapshot.reason ?? "",
            snapshot.defaultMacOSImage?.entry.imageReference ?? "",
            snapshot.defaultMacOSImageError ?? "",
        ]
        .joined(separator: "|")
    }

    private func newWorkspaceSheetRefreshID(for repo: Repo) -> String {
        [
            repo.id.uuidString,
            providerAvailabilityRefreshSignature,
            lumeRuntimeRefreshSignature,
            isCreatingWorkspace(for: repo.id) ? "creating" : "idle",
        ]
        .joined(separator: "::")
    }

    private func environmentOptions(for repo: Repo) -> [WorkspaceEnvironmentSheetOption] {
        [
            localEnvironmentOption(for: repo),
            cloudLinuxEnvironmentOption(for: repo),
            macOSEnvironmentOption(for: repo),
            linuxVMEnvironmentOption(for: repo),
        ]
    }

    private func availability(
        for descriptor: WorkspaceProviderDescriptor,
        repo: Repo
    ) -> WorkspaceProviderAvailability {
        let baseAvailability: WorkspaceProviderAvailability
        if let resolvedAvailability = providerAvailabilityByID[descriptor.id] {
            baseAvailability = resolvedAvailability
        } else if descriptor.id == LocalWorkspaceProvider.identifier {
            baseAvailability = .available
        } else if isRefreshingProviderAvailability {
            baseAvailability = .unavailable("Checking provider availability...")
        } else {
            baseAvailability = .unavailable("Timed out checking provider availability.")
        }

        guard baseAvailability.isAvailable else { return baseAvailability }

        if descriptor.requiresRemoteRepository,
            repo.remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        {
            return .unavailable("This repository needs a remote origin URL for \(descriptor.displayName).")
        }

        return baseAvailability
    }

    @MainActor
    private func refreshProviderAvailability() async {
        isRefreshingProviderAvailability = true
        defer {
            isRefreshingProviderAvailability = false

            for provider in workspaceProviderRegistry.providers {
                let providerID = provider.descriptor.id
                guard providerAvailabilityByID[providerID] == nil else { continue }
                providerAvailabilityByID[providerID] = .unavailable(
                    "Timed out checking \(provider.descriptor.displayName) availability."
                )
            }
        }

        if providerAvailabilityByID[LocalWorkspaceProvider.identifier] == nil {
            providerAvailabilityByID[LocalWorkspaceProvider.identifier] = .available
        }

        await withTaskGroup(of: (String, WorkspaceProviderAvailability).self) { group in
            for provider in workspaceProviderRegistry.providers {
                let providerID = provider.descriptor.id
                group.addTask {
                    (
                        providerID,
                        await availabilityWithTimeout(
                            for: provider,
                            displayName: provider.descriptor.displayName
                        )
                    )
                }
            }

            for await (providerID, availability) in group {
                providerAvailabilityByID[providerID] = availability
            }
        }
    }

    private func availabilityWithTimeout(
        for provider: any WorkspaceProviderProtocol,
        displayName: String,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async -> WorkspaceProviderAvailability {
        await withTaskGroup(of: WorkspaceProviderAvailability?.self) { group in
            group.addTask {
                await provider.availability()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let firstResult = await group.next() ?? nil
            group.cancelAll()

            if let availability = firstResult {
                return availability
            }

            return .unavailable("Timed out checking \(displayName) availability.")
        }
    }

    @MainActor
    private func refreshLumeRuntimeSnapshot() async {
        lumeRuntimeSnapshot = await lumeRuntimeService.snapshot()
    }

    @MainActor
    private func seedFixtureProviderStateIfNeeded() async -> Bool {
        guard UIFixtureLumeEnvironment.isEnabled() else { return false }

        providerAvailabilityByID = UIFixtureLumeEnvironment.initialProviderAvailabilityByID()
        lumeRuntimeSnapshot = await lumeRuntimeService.snapshot()
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
        expandedRepoIDs.contains(repo.id)
    }

    private func toggleRepoExpansion(_ repo: Repo) {
        if expandedRepoIDs.contains(repo.id) {
            expandedRepoIDs.remove(repo.id)
        } else {
            expandedRepoIDs.insert(repo.id)
        }
    }

    private func isWorkspaceExpanded(_ workspace: Workspace) -> Bool {
        expandedWorkspaceIDs.contains(workspace.id)
    }

    private func toggleWorkspaceExpansion(_ workspace: Workspace) {
        guard !workspace.webSources.isEmpty else { return }

        if expandedWorkspaceIDs.contains(workspace.id) {
            expandedWorkspaceIDs.remove(workspace.id)
        } else {
            expandedWorkspaceIDs.insert(workspace.id)
        }
    }

    private func initializeExpandedReposIfNeeded() {
        guard !didInitializeRepoExpansion else { return }
        didInitializeRepoExpansion = true

        if isUIFixtureMode {
            expandedRepoIDs = Set(repos.map(\.id))
            return
        }

        guard let selectedRepoID = selectedWorkspace?.sourceRepo?.id else { return }
        expandedRepoIDs.insert(selectedRepoID)
    }

    private func expandRepoForSelectedWorkspace() {
        guard let selectedWorkspace else { return }
        guard let selectedRepoID = selectedWorkspace.sourceRepo?.id else { return }
        expandedRepoIDs.insert(selectedRepoID)
        if !selectedWorkspace.webSources.isEmpty {
            expandedWorkspaceIDs.insert(selectedWorkspace.id)
        }
    }

    private func expandContainersForSelectedWebSource() {
        guard let selectedWebSource else { return }

        if let repoID = selectedWebSource.ownerRepo?.id {
            expandedRepoIDs.insert(repoID)
        }

        if let workspaceID = selectedWebSource.sourceWorkspace?.id {
            expandedWorkspaceIDs.insert(workspaceID)
        }
    }

    private func pruneExpandedRepos() {
        let currentRepoIDs = Set(repos.map(\.id))
        expandedRepoIDs.formIntersection(currentRepoIDs)
    }

    private func pruneExpandedWorkspaces() {
        let currentWorkspaceIDs = Set(repos.flatMap(\.workspaces).map(\.id))
        expandedWorkspaceIDs.formIntersection(currentWorkspaceIDs)
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

    private func localEnvironmentOption(for repo: Repo) -> WorkspaceEnvironmentSheetOption {
        let descriptor = workspaceProviderRegistry.provider(for: LocalWorkspaceProvider.identifier)?.descriptor
        let availability = availability(
            for: descriptor
                ?? WorkspaceProviderDescriptor(
                    id: LocalWorkspaceProvider.identifier,
                    displayName: "Local",
                    description: "Create a local workspace copy on this Mac."
                ),
            repo: repo
        )

        return WorkspaceEnvironmentSheetOption(
            kind: .local,
            title: "Local",
            subtitle: "Create a local workspace copy on this Mac",
            description: descriptor?.description ?? "Create a local workspace copy on this Mac.",
            iconName: "plus.rectangle.on.folder.fill",
            providerID: LocalWorkspaceProvider.identifier,
            guestOS: nil,
            isAvailable: availability.isAvailable,
            statusText: nil,
            availabilityReason: availability.reason
        )
    }

    private func cloudLinuxEnvironmentOption(for repo: Repo) -> WorkspaceEnvironmentSheetOption {
        let descriptor = workspaceProviderRegistry.provider(for: DaytonaWorkspaceProvider.identifier)?.descriptor
        let availability = availability(
            for: descriptor
                ?? WorkspaceProviderDescriptor(
                    id: DaytonaWorkspaceProvider.identifier,
                    displayName: "Cloud Linux",
                    description: "Create a cloud Linux workspace."
                ),
            repo: repo
        )

        return WorkspaceEnvironmentSheetOption(
            kind: .cloudLinux,
            title: "Cloud Linux",
            subtitle: "Runs in Daytona cloud infrastructure",
            description: descriptor?.description
                ?? "Create a cloud Linux workspace managed by Daytona.",
            iconName: "cloud.fill",
            providerID: DaytonaWorkspaceProvider.identifier,
            guestOS: .linux,
            isAvailable: availability.isAvailable,
            statusText: nil,
            availabilityReason: availability.reason
        )
    }

    private func macOSEnvironmentOption(for repo: Repo) -> WorkspaceEnvironmentSheetOption {
        let baseAvailability = lumeEnvironmentAvailability()

        let isAvailable: Bool
        let availabilityReason: String?
        if !baseAvailability.isAvailable {
            isAvailable = false
            availabilityReason = baseAvailability.reason
        } else if let snapshot = lumeRuntimeSnapshot,
            snapshot.state == .unsupportedHost
        {
            isAvailable = false
            availabilityReason = snapshot.reason
        } else {
            isAvailable = true
            availabilityReason = nonBlockingMacOSAvailabilityReason()
        }

        let hostMatchSummary = macOSBaseSummary()

        return WorkspaceEnvironmentSheetOption(
            kind: .macOSVM,
            title: "macOS VM",
            subtitle: hostMatchSummary,
            description: macOSEnvironmentDescription(),
            iconName: "desktopcomputer",
            providerID: LumeWorkspaceProvider.identifier,
            guestOS: .macOS,
            isAvailable: isAvailable,
            statusText: macOSRuntimeStatusText(),
            availabilityReason: availabilityReason
        )
    }

    private func linuxVMEnvironmentOption(for repo: Repo) -> WorkspaceEnvironmentSheetOption {
        let availability = lumeEnvironmentAvailability()

        return WorkspaceEnvironmentSheetOption(
            kind: .linuxVM,
            title: "Linux VM",
            subtitle: "Runs in a local Linux VM on this Mac",
            description: linuxVMEnvironmentDescription(),
            iconName: "server.rack",
            providerID: LumeWorkspaceProvider.identifier,
            guestOS: .linux,
            isAvailable: availability.isAvailable,
            statusText: lumeRuntimeStatusText(),
            availabilityReason: availability.reason
        )
    }

    private func lumeEnvironmentAvailability() -> WorkspaceProviderAvailability {
        if let snapshot = lumeRuntimeSnapshot, snapshot.state == .unsupportedHost {
            return .unavailable(snapshot.reason ?? "Lume requires Apple Silicon.")
        }

        #if arch(arm64)
            return .available
        #else
            return .unavailable("Lume requires Apple Silicon.")
        #endif
    }

    private func lumeRuntimeStatusText() -> String? {
        guard let snapshot = lumeRuntimeSnapshot else { return nil }
        switch snapshot.state {
        case .setupRequired:
            return "Setup required"
        case .repairRequired:
            return "Repair required"
        case .ready:
            return "Ready"
        case .installing:
            return "Installing"
        case .verifying:
            return "Verifying"
        case .unsupportedHost:
            return nil
        }
    }

    private func macOSRuntimeStatusText() -> String? {
        if let snapshot = lumeRuntimeSnapshot, snapshot.state != .ready {
            return lumeRuntimeStatusText()
        }

        if let baseSnapshot = lumeRuntimeSnapshot?.baseVM {
            switch baseSnapshot.status {
            case .ready:
                return "Fast clone ready"
            case .preparing:
                return "Preparing base"
            case .missing:
                if baseSnapshot.profile.imageReference != nil {
                    return "Downloads base on first use"
                }
                return "Prepares base on first use"
            case .repairRequired:
                return "Repair base VM"
            }
        }

        if let snapshot = lumeRuntimeSnapshot,
            snapshot.state == .ready,
            snapshot.defaultMacOSImage == nil,
            snapshot.defaultMacOSImageError != nil
        {
            return "Stock macOS"
        }

        return lumeRuntimeStatusText()
    }

    private func macOSEnvironmentDescription() -> String {
        let base =
            "Runs in a local macOS VM. Files stay on the host, the terminal opens in-app with `lume ssh`, and desktop opens in an external VNC client."

        guard let snapshot = lumeRuntimeSnapshot else {
            return base
        }

        switch snapshot.state {
        case .setupRequired:
            return "\(base) Workspaces will install and verify Lume automatically the first time you use this."
        case .repairRequired:
            return "\(base) Workspaces will repair the local VM runtime automatically before continuing."
        case .ready, .installing, .verifying, .unsupportedHost:
            break
        }

        if let baseSnapshot = snapshot.baseVM {
            switch baseSnapshot.status {
            case .ready:
                return "\(base) Workspaces will clone the prepared base VM for a faster macOS workspace start."
            case .preparing:
                return "\(base) A prepared base VM is already being created. Workspaces will clone it once it is ready."
            case .missing:
                if baseSnapshot.profile.imageReference != nil {
                    return """
                        \(base) Workspaces will download the matching base VM once, then clone it for faster future macOS workspaces.
                        """
                }
                return """
                    \(base) No host-matched golden image is available yet, so Workspaces will prepare a stock macOS base VM once and clone it for faster future workspaces.
                    """
            case .repairRequired:
                return "\(base) Workspaces will repair or recreate the prepared base VM before continuing."
            }
        }

        if snapshot.defaultMacOSImage == nil, snapshot.defaultMacOSImageError != nil {
            return """
                \(base) No host-matched golden image is available yet, so Workspaces will fall back to stock macOS setup automatically.
                """
        }

        return base
    }

    private func linuxVMEnvironmentDescription() -> String {
        let base =
            "Uses the same host-shared file model as macOS VM workspaces. Terminal opens in-app, and desktop opens externally when available."

        guard let snapshot = lumeRuntimeSnapshot else {
            return base
        }

        switch snapshot.state {
        case .setupRequired:
            return "\(base) Workspaces will install and verify Lume automatically the first time you use this."
        case .repairRequired:
            return "\(base) Workspaces will repair the local VM runtime automatically before continuing."
        case .ready, .installing, .verifying, .unsupportedHost:
            return base
        }
    }

    private func nonBlockingMacOSAvailabilityReason() -> String? {
        guard let snapshot = lumeRuntimeSnapshot else { return nil }

        if let baseSnapshot = snapshot.baseVM, let reason = baseSnapshot.reason {
            return reason
        }

        if snapshot.defaultMacOSImage == nil, snapshot.defaultMacOSImageError != nil {
            return "Workspaces will use stock macOS because no host-matched golden image is available yet."
        }

        return nil
    }

    private func macOSBaseSummary() -> String {
        guard let snapshot = lumeRuntimeSnapshot else {
            return "Matches this Mac by default"
        }

        if let baseSnapshot = snapshot.baseVM {
            switch baseSnapshot.status {
            case .ready:
                return "Fast clone ready: \(baseSnapshot.profile.displayName)"
            case .preparing:
                return "Preparing base: \(baseSnapshot.profile.displayName)"
            case .missing:
                if baseSnapshot.profile.imageReference != nil {
                    return "Will download base once: \(baseSnapshot.profile.displayName)"
                }
                return "Needs one-time base preparation"
            case .repairRequired:
                return "Needs base VM repair: \(baseSnapshot.profile.displayName)"
            }
        }

        return snapshot.defaultMacOSImage?.profileDisplayName
            ?? snapshot.hostProfile?.displayName
            ?? "Matches this Mac by default"
    }
}
