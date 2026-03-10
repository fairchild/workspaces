//
//  SidebarView.swift
//  WorkspaceManager
//
//  Left sidebar showing repositories and workspaces
//

import SwiftData
import SwiftUI
import WorkspaceManagerCore

struct SandboxActionState {
    let sandboxId: String
    let message: String
}

struct WorkspaceCreationStatus {
    let message: String
}

struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.gitService) private var gitService
    @Environment(\.workspaceService) private var workspaceService
    @Environment(\.remoteBackend) private var remoteBackend
    let repos: [Repo]
    let webSources: [WebSource]
    let selectedRepo: Repo?
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedWebSource: WebSource?
    let paneCountBySessionKey: [HostTerminalSessionKey: Int]
    let activeSessionKey: HostTerminalSessionKey?
    let connectingSandboxId: String?
    let onRepoSelected: (Repo) -> Void
    let onRepoTerminalSelected: (Repo) -> Void
    let onWebSourceSelected: (WebSource) -> Void
    let onRequestWebSourceCreation: (WebSourceCreationTarget) -> Void
    let onWorkspaceCreated: () -> Void

    @AppStorage(SidebarRepoSortMode.storageKey)
    private var repoSortModeRawValue: String = SidebarRepoSortMode.alphabetical.rawValue

    @State private var isAddingRepo = false
    @State private var repoForNewWorkspace: Repo?
    @State private var isRemoteBackendAvailable = false

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
    @State private var sandboxAction: SandboxActionState?
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
            remoteBackend: remoteBackend
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
            .sheet(item: $repoForNewWorkspace) { repo in
                NewWorkspaceSheet(
                    repo: repo,
                    isRemoteBackendAvailable: isRemoteBackendAvailable,
                    isCreateDisabled: isCreatingWorkspace(for: repo.id)
                ) { name, backend in
                    Task { @MainActor in
                        switch backend {
                        case .local:
                            await createWorkspace(from: repo, name: name)
                        case .remoteVM:
                            await createRemoteWorkspace(from: repo, name: name)
                        }
                    }
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
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
                isRemoteBackendAvailable = await remoteBackend.isAvailable()
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
                    Picker(
                        "Sort Repositories",
                        selection: Binding(
                            get: { repoSortMode },
                            set: updateRepoSortMode
                        )
                    ) {
                        ForEach(SidebarRepoSortMode.allCases) { mode in
                            Text(mode.title).tag(mode)
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
                repoForNewWorkspace = repo
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
                repoForNewWorkspace = repo
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

                    if !workspace.isRemote {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(
                                nil, inFileViewerRootedAtPath: workspace.path)
                        }
                    }

                    Divider()

                    if workspace.isRemote {
                        remoteWorkspaceActions(workspace)
                    } else {
                        localWorkspaceActions(workspace)
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
    private func createWorkspace(from repo: Repo, name: String) async {
        let repoID = repo.id
        guard !isCreatingWorkspace(for: repoID) else { return }
        expandedRepoIDs.insert(repoID)
        updateLocalCreationStatus(repoID: repoID, phase: .preparing)

        do {
            let workspace = try await workspaceController.createWorkspace(
                from: repo,
                name: name,
                progress: { phase in
                    await MainActor.run {
                        updateLocalCreationStatus(repoID: repoID, phase: phase)
                    }
                }
            )
            workspaceCreationStatusByRepoID.removeValue(forKey: repoID)
            onWorkspaceCreated()
            selectedWorkspace = workspace
        } catch {
            workspaceCreationStatusByRepoID.removeValue(forKey: repoID)
            errorMessage = "Failed to create workspace: \(error.localizedDescription)"
            showingError = true
        }
    }

    @MainActor
    private func createRemoteWorkspace(from repo: Repo, name: String) async {
        let repoID = repo.id
        guard !isCreatingWorkspace(for: repoID) else { return }
        workspaceCreationStatusByRepoID[repoID] = WorkspaceCreationStatus(
            message: "Creating cloud workspace..."
        )
        expandedRepoIDs.insert(repoID)

        do {
            let workspace = try await workspaceController.createRemoteWorkspace(from: repo, name: name)
            workspaceCreationStatusByRepoID.removeValue(forKey: repoID)
            onWorkspaceCreated()
            selectedWorkspace = workspace
        } catch {
            workspaceCreationStatusByRepoID.removeValue(forKey: repoID)
            errorMessage = "Failed to create remote workspace: \(error.localizedDescription)"
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
    private func remoteWorkspaceActions(_ workspace: Workspace) -> some View {
        switch workspace.status {
        case .active:
            Button("Stop") {
                performStop(workspace)
            }
            Button("Archive") {
                performArchive(workspace)
            }
        case .stopped:
            Button("Start") {
                performStart(workspace)
            }
            Button("Archive") {
                performArchive(workspace)
            }
        case .archived:
            Button("Start") {
                performStart(workspace)
            }
        }
    }

    @ViewBuilder
    private func localWorkspaceActions(_ workspace: Workspace) -> some View {
        if workspace.status == .active {
            Button("Archive") {
                workspace.status = .archived
            }
        } else {
            Button("Unarchive") {
                workspace.status = .active
            }
        }
    }

    private func performStop(_ workspace: Workspace) {
        guard let sandboxId = workspace.remoteId else { return }
        sandboxAction = SandboxActionState(sandboxId: sandboxId, message: "Stopping...")

        Task { @MainActor in
            do {
                try await workspaceController.stop(workspace)
                sandboxAction = nil
            } catch {
                sandboxAction = nil
                errorMessage = "Failed to stop sandbox: \(error.localizedDescription)"
                showingError = true
            }
        }
    }

    private func performStart(_ workspace: Workspace) {
        guard let sandboxId = workspace.remoteId else { return }
        sandboxAction = SandboxActionState(sandboxId: sandboxId, message: "Starting...")

        Task { @MainActor in
            do {
                try await workspaceController.start(workspace)
                sandboxAction = nil
                selectedWorkspace = workspace
            } catch {
                sandboxAction = nil
                errorMessage = "Failed to start sandbox: \(error.localizedDescription)"
                showingError = true
            }
        }
    }

    private func performArchive(_ workspace: Workspace) {
        guard let sandboxId = workspace.remoteId else { return }
        sandboxAction = SandboxActionState(sandboxId: sandboxId, message: "Archiving...")

        Task { @MainActor in
            do {
                try await workspaceController.archive(workspace)
                sandboxAction = nil
            } catch {
                sandboxAction = nil
                errorMessage = "Failed to archive sandbox: \(error.localizedDescription)"
                showingError = true
            }
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

        repoForNewWorkspace = preferredRepo
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
        if let sandboxId = workspace.remoteId {
            return .remoteSandbox(sandboxId)
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
        guard let remoteId = workspace.remoteId else { return nil }
        if connectingSandboxId == remoteId { return "Connecting..." }
        if let action = sandboxAction, action.sandboxId == remoteId { return action.message }
        return nil
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

}
