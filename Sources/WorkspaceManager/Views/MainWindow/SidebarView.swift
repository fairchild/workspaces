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
    static func preferredRepoForNewWorkspace(
        selectedWorkspace: Workspace?,
        activeSessionKey: HostTerminalSessionKey?,
        repos: [Repo],
        normalizeRepoPath: (URL) -> String
    ) -> Repo? {
        if let selectedWorkspace {
            return selectedWorkspace.sourceRepo
        }

        if case .repoPath(let activeRepoPath) = activeSessionKey {
            let normalizedActiveRepoPath = normalizeRepoPath(URL(fileURLWithPath: activeRepoPath))
            if let matchedRepo = repos.first(where: {
                normalizeRepoPath($0.localURL) == normalizedActiveRepoPath
            }) {
                return matchedRepo
            }
        }

        return repos.first
    }

    static func cleanupRemoteSandboxAfterFailedPersistence(
        sandboxId: String,
        deleteSandbox: @Sendable (String) async throws -> Void
    ) async -> Error? {
        do {
            try await deleteSandbox(sandboxId)
            return nil
        } catch {
            return error
        }
    }

    static func remoteWorkspacePersistenceFailureMessage(
        existingMessage: String?,
        sandboxId: String,
        cleanupError: Error
    ) -> String {
        let cleanupMessage =
            "Cleanup also failed for remote sandbox '\(sandboxId)': \(cleanupError.localizedDescription)"

        if let existingMessage, !existingMessage.isEmpty {
            return "\(existingMessage)\n\n\(cleanupMessage)"
        }

        return cleanupMessage
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.gitService) private var gitService
    @Environment(\.workspaceService) private var workspaceService
    @Environment(\.remoteBackend) private var remoteBackend
    let repos: [Repo]
    let webSources: [WebSource]
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedWebSource: WebSource?
    let defaultHostPath: String
    let paneCountBySessionKey: [HostTerminalSessionKey: Int]
    let activeSessionKey: HostTerminalSessionKey?
    let connectingSandboxId: String?
    let onDefaultHostSelected: () -> Void
    let onRepoSelected: (Repo) -> Void
    let onWebSourceSelected: (WebSource) -> Void
    let onWorkspaceCreated: () -> Void

    @State private var isAddingRepo = false
    @State private var isAddingWebSource = false
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
    @State private var didInitializeRepoExpansion = false
    @State private var sandboxAction: SandboxActionState?
    @State private var workspaceCreationStatusByRepoID: [UUID: WorkspaceCreationStatus] = [:]

    private var isUIFixtureMode: Bool {
        ProcessInfo.processInfo.environment["WORKSPACES_UI_FIXTURE"] == "1"
    }

    private var isRepoAutoImportDisabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return isUIFixtureMode || environment["WORKSPACES_DISABLE_AUTO_IMPORT"] == "1"
    }

    var body: some View {
        List {
            // Repositories Section
            Section("Repositories") {
                Button {
                    selectedWebSource = nil
                    onDefaultHostSelected()
                } label: {
                    HostTerminalRow(
                        defaultHostPath: defaultHostPath,
                        sessionActivity: sessionActivity(for: .defaultHome),
                        paneCount: paneCount(for: .defaultHome)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if repos.isEmpty {
                    Text("No repositories")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(repos) { repo in
                        let normalizedRepoPath = normalizePath(repo.localURL)
                        let repoSessionKey = HostTerminalSessionKey.repoPath(normalizedRepoPath)
                        RepoRow(
                            repo: repo,
                            sessionActivity: sessionActivity(for: repoSessionKey),
                            paneCount: paneCount(for: repoSessionKey),
                            isExpanded: isRepoExpanded(repo),
                            onToggleExpansion: {
                                toggleRepoExpansion(repo)
                            },
                            onSelectRepo: {
                                if !repo.workspaces.isEmpty, !isRepoExpanded(repo) {
                                    expandedRepoIDs.insert(repo.id)
                                }
                                selectedWebSource = nil
                                onRepoSelected(repo)
                            }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("New Workspace...") {
                                repoForNewWorkspace = repo
                            }
                            .disabled(isCreatingWorkspace(for: repo.id))

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
                            let repoWorkspaces = sortedWorkspaces(for: repo)

                            if repoWorkspaces.isEmpty, creationStatus(for: repo.id) == nil {
                                Text("No workspaces")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                    .padding(.leading, 28)
                            } else {
                                ForEach(repoWorkspaces) { workspace in
                                    let workspaceSessionKey: HostTerminalSessionKey = {
                                        if let sandboxId = workspace.remoteId {
                                            return .remoteSandbox(sandboxId)
                                        }
                                        return .hostPath(normalizePath(workspace.workspaceURL))
                                    }()
                                    Button {
                                        selectWorkspace(workspace)
                                    } label: {
                                        WorkspaceRow(
                                            workspace: workspace,
                                            isSelected: selectedWorkspace?.id == workspace.id,
                                            statusMessage: workspaceStatusMessage(workspace),
                                            sessionActivity: sessionActivity(for: workspaceSessionKey),
                                            paneCount: paneCount(for: workspaceSessionKey),
                                            isNested: true
                                        )
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
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
                    }
                }
            }

            Section("Web") {
                if webSources.isEmpty {
                    Text("No URL sources")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(webSources) { source in
                        Button {
                            selectedWorkspace = nil
                            selectedWebSource = source
                            source.lastAccessedAt = Date()
                            if !saveModelContext(action: "update URL source access time") {
                                modelContext.rollback()
                            }
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
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 30)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Divider()

                VStack(spacing: 6) {
                    Button {
                        isAddingRepo = true
                    } label: {
                        Label("Add Repository", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)

                    Button {
                        isAddingWebSource = true
                    } label: {
                        Label("Add URL Source", systemImage: "globe")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
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
                Task {
                    switch backend {
                    case .local:
                        await createWorkspace(from: repo, name: name)
                    case .remoteVM:
                        await createRemoteWorkspace(from: repo, name: name)
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingWebSource) {
            NewWebSourceSheet { rawURL, displayName, additionalAllowedDomainsRaw in
                addWebSource(
                    rawURL: rawURL,
                    displayName: displayName,
                    additionalAllowedDomainsRaw: additionalAllowedDomainsRaw
                )
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
                performDelete(workspace, deleteFiles: false)
            }
            Button("Delete and Remove Files", role: .destructive) {
                performDelete(workspace, deleteFiles: true)
            }
            Button("Cancel", role: .cancel) {
                workspaceToDelete = nil
            }
        } message: { workspace in
            Text("Are you sure you want to delete '\(workspace.name)'?")
        }
        .focusedSceneValue(\.newWorkspaceAction, handleNewWorkspaceShortcut)
        .onChange(of: selectedWorkspace?.id) { _, _ in
            updateLastAccessedTimestamp()
            expandRepoForSelectedWorkspace()
        }
        .onChange(of: repos.map(\.id)) { _, _ in
            pruneExpandedRepos()
        }
        .onAppear {
            initializeExpandedReposIfNeeded()
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
    private func addWebSource(
        rawURL: String,
        displayName: String,
        additionalAllowedDomainsRaw: String
    ) {
        do {
            let normalized = try WebSourceValidation.normalizeBaseURL(rawURL)
            let normalizedURLString = normalized.baseURL.absoluteString
            let parsedAdditionalDomains = try WebSourceValidation.normalizeAdditionalAllowedDomains(
                additionalAllowedDomainsRaw
            )
            let additionalAllowedDomains = parsedAdditionalDomains.filter { domain in
                domain != normalized.allowedHost
                    && domain != "*.\(normalized.allowedHost)"
            }

            if webSources.contains(where: { normalizeWebURLString($0.baseURLString) == normalizedURLString }) {
                errorMessage = "That URL source is already in the list."
                showingError = true
                return
            }

            let source = WebSource(
                name: WebSourceValidation.normalizedDisplayName(
                    explicitName: displayName,
                    baseURL: normalized.baseURL
                ),
                baseURLString: normalizedURLString,
                allowedHost: normalized.allowedHost,
                additionalAllowedDomains: additionalAllowedDomains
            )

            modelContext.insert(source)
            if saveModelContext(action: "save URL source") {
                selectedWorkspace = nil
                selectedWebSource = source
                onWebSourceSelected(source)
            } else {
                modelContext.rollback()
            }
        } catch {
            if let validationError = error as? WebSourceValidationError {
                errorMessage = validationError.errorDescription
            } else {
                errorMessage = "Failed to add URL source: \(error.localizedDescription)"
            }
            showingError = true
        }
    }

    @MainActor
    private func removeWebSource(_ source: WebSource) {
        let removedWasSelected = selectedWebSource?.id == source.id
        modelContext.delete(source)
        if saveModelContext(action: "remove URL source") {
            if removedWasSelected {
                selectedWebSource = nil
                onDefaultHostSelected()
            }
        } else {
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
            message: localCreationMessage(for: phase)
        )
    }

    private func localCreationMessage(for phase: WorkspaceCreationPhase) -> String {
        switch phase {
        case .preparing:
            return "Preparing workspace..."
        case .copyingRepository:
            return "Copying repository..."
        case .creatingBranch:
            return "Creating branch..."
        case .runningSetupScript:
            return "Running setup script..."
        case .finished:
            return "Finishing workspace..."
        }
    }

    private func createWorkspace(from repo: Repo, name: String) async {
        let repoID = repo.id
        // Extract value types before crossing actor boundary
        let repoName = repo.name
        let repoLocalURL = repo.localURL

        let shouldStart = await MainActor.run { () -> Bool in
            guard !isCreatingWorkspace(for: repoID) else { return false }
            expandedRepoIDs.insert(repoID)
            updateLocalCreationStatus(repoID: repoID, phase: .preparing)
            return true
        }

        guard shouldStart else { return }

        do {
            let info = try await workspaceService.createWorkspace(
                repoName: repoName,
                repoLocalURL: repoLocalURL,
                name: name,
                progress: { phase in
                    await MainActor.run {
                        updateLocalCreationStatus(repoID: repoID, phase: phase)
                    }
                }
            )

            let didPersist = await MainActor.run { () -> Bool in
                // Keep SwiftData model creation and relationship writes on MainActor.
                let workspace = Workspace(
                    name: info.name,
                    path: info.path,
                    sourceRepo: repo,
                    gitBranch: info.gitBranch
                )
                modelContext.insert(workspace)
                if saveModelContext(action: "save workspace") {
                    workspaceCreationStatusByRepoID.removeValue(forKey: repoID)
                    onWorkspaceCreated()
                    selectedWorkspace = workspace
                    return true
                }
                workspaceCreationStatusByRepoID.removeValue(forKey: repoID)
                modelContext.rollback()
                return false
            }

            if !didPersist {
                cleanupWorkspaceDirectoryAfterFailedPersistence(info.path)
            }
        } catch {
            await MainActor.run {
                workspaceCreationStatusByRepoID.removeValue(forKey: repoID)
                errorMessage = "Failed to create workspace: \(error.localizedDescription)"
                showingError = true
            }
        }
    }

    private func createRemoteWorkspace(from repo: Repo, name: String) async {
        let repoId = repo.id
        let cloneURL = repo.remoteURL
        let backend = remoteBackend

        let shouldStart = await MainActor.run { () -> Bool in
            guard !isCreatingWorkspace(for: repoId) else { return false }
            workspaceCreationStatusByRepoID[repoId] = WorkspaceCreationStatus(
                message: "Creating cloud workspace..."
            )
            expandedRepoIDs.insert(repoId)
            return true
        }

        guard shouldStart else { return }

        do {
            let info = try await backend.createSandbox(name: name, cloneURL: cloneURL)

            let didPersist = await MainActor.run { () -> Bool in
                workspaceCreationStatusByRepoID.removeValue(forKey: repoId)
                let workspace = Workspace(
                    name: name,
                    path: FileManager.default.temporaryDirectory,
                    sourceRepo: repo,
                    backendIdentifier: backend.identifier,
                    remoteId: info.sandboxId
                )
                modelContext.insert(workspace)
                if saveModelContext(action: "save remote workspace") {
                    onWorkspaceCreated()
                    selectedWorkspace = workspace
                    return true
                }

                modelContext.rollback()
                return false
            }

            guard !didPersist else { return }

            if let cleanupError = await Self.cleanupRemoteSandboxAfterFailedPersistence(
                sandboxId: info.sandboxId,
                deleteSandbox: { sandboxId in
                    try await backend.deleteSandbox(sandboxId: sandboxId)
                }
            ) {
                NSLog(
                    "[RemoteBackend] Failed to clean up sandbox %@ after persistence failure: %@",
                    info.sandboxId,
                    cleanupError.localizedDescription
                )
                await MainActor.run {
                    errorMessage = Self.remoteWorkspacePersistenceFailureMessage(
                        existingMessage: errorMessage,
                        sandboxId: info.sandboxId,
                        cleanupError: cleanupError
                    )
                    showingError = true
                }
            }
        } catch {
            await MainActor.run {
                workspaceCreationStatusByRepoID.removeValue(forKey: repoId)
                errorMessage = "Failed to create remote workspace: \(error.localizedDescription)"
                showingError = true
            }
        }
    }

    @MainActor
    private func deleteWorkspace(_ workspace: Workspace) {
        workspaceToDelete = workspace
        showingDeleteConfirmation = true
    }

    private func performDelete(_ workspace: Workspace, deleteFiles: Bool) {
        let workspaceURL = workspace.workspaceURL
        let sandboxId = workspace.remoteId
        let isRemote = workspace.isRemote
        let backend = remoteBackend

        Task {
            if isRemote, let sandboxId {
                do {
                    try await backend.deleteSandbox(sandboxId: sandboxId)
                } catch {
                    NSLog("[RemoteBackend] Failed to delete sandbox %@: %@", sandboxId, error.localizedDescription)
                }
            } else {
                do {
                    try await workspaceService.deleteWorkspace(at: workspaceURL, deleteFiles: deleteFiles)
                } catch {
                    await MainActor.run {
                        errorMessage = "Failed to delete workspace: \(error.localizedDescription)"
                        showingError = true
                        workspaceToDelete = nil
                    }
                    return
                }
            }

            await MainActor.run {
                modelContext.delete(workspace)
                if saveModelContext(action: "update workspace list") {
                    if selectedWorkspace == workspace {
                        selectedWorkspace = nil
                    }
                } else {
                    modelContext.rollback()
                }
                workspaceToDelete = nil
            }
        }
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
        let backend = remoteBackend
        sandboxAction = SandboxActionState(sandboxId: sandboxId, message: "Stopping...")

        Task {
            do {
                try await backend.stopSandbox(sandboxId: sandboxId)
                await MainActor.run {
                    sandboxAction = nil
                    workspace.status = .stopped
                    _ = saveModelContext(action: "stop sandbox")
                }
            } catch {
                await MainActor.run {
                    sandboxAction = nil
                    errorMessage = "Failed to stop sandbox: \(error.localizedDescription)"
                    showingError = true
                }
            }
        }
    }

    private func performStart(_ workspace: Workspace) {
        guard let sandboxId = workspace.remoteId else { return }
        let backend = remoteBackend
        sandboxAction = SandboxActionState(sandboxId: sandboxId, message: "Starting...")

        Task {
            do {
                _ = try await backend.startSandbox(sandboxId: sandboxId)
                await MainActor.run {
                    sandboxAction = nil
                    workspace.status = .active
                    _ = saveModelContext(action: "start sandbox")
                    selectedWorkspace = workspace
                }
            } catch {
                await MainActor.run {
                    sandboxAction = nil
                    errorMessage = "Failed to start sandbox: \(error.localizedDescription)"
                    showingError = true
                }
            }
        }
    }

    private func performArchive(_ workspace: Workspace) {
        guard let sandboxId = workspace.remoteId else { return }
        let backend = remoteBackend
        sandboxAction = SandboxActionState(sandboxId: sandboxId, message: "Archiving...")

        Task {
            do {
                try await backend.archiveSandbox(sandboxId: sandboxId)
                await MainActor.run {
                    sandboxAction = nil
                    workspace.status = .archived
                    _ = saveModelContext(action: "archive sandbox")
                }
            } catch {
                await MainActor.run {
                    sandboxAction = nil
                    errorMessage = "Failed to archive sandbox: \(error.localizedDescription)"
                    showingError = true
                }
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
            let preferredRepo = Self.preferredRepoForNewWorkspace(
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
    private func updateLastAccessedTimestamp() {
        guard let selectedWorkspace else { return }

        selectedWorkspace.lastAccessedAt = Date()
        if !saveModelContext(action: "update workspace access time") {
            modelContext.rollback()
        }
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

    private func cleanupWorkspaceDirectoryAfterFailedPersistence(_ workspaceURL: URL) {
        try? FileManager.default.removeItem(at: workspaceURL)

        let parentDir = workspaceURL.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: parentDir.path),
            contents.isEmpty
        {
            try? FileManager.default.removeItem(at: parentDir)
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

    private func isRepoExpanded(_ repo: Repo) -> Bool {
        expandedRepoIDs.contains(repo.id)
    }

    private func toggleRepoExpansion(_ repo: Repo) {
        guard !repo.workspaces.isEmpty else { return }

        if expandedRepoIDs.contains(repo.id) {
            expandedRepoIDs.remove(repo.id)
        } else {
            expandedRepoIDs.insert(repo.id)
        }
    }

    private func initializeExpandedReposIfNeeded() {
        guard !didInitializeRepoExpansion else { return }
        didInitializeRepoExpansion = true

        if isUIFixtureMode {
            expandedRepoIDs = Set(repos.filter { !$0.workspaces.isEmpty }.map(\.id))
            return
        }

        guard let selectedRepoID = selectedWorkspace?.sourceRepo?.id else { return }
        expandedRepoIDs.insert(selectedRepoID)
    }

    private func expandRepoForSelectedWorkspace() {
        guard let selectedRepoID = selectedWorkspace?.sourceRepo?.id else { return }
        expandedRepoIDs.insert(selectedRepoID)
    }

    private func pruneExpandedRepos() {
        let currentRepoIDs = Set(repos.map(\.id))
        expandedRepoIDs.formIntersection(currentRepoIDs)
    }

}
