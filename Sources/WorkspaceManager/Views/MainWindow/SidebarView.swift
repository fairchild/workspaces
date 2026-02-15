//
//  SidebarView.swift
//  WorkspaceManager
//
//  Left sidebar showing repositories and workspaces
//

import SwiftData
import SwiftUI
import WorkspaceManagerCore

struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.gitService) private var gitService
    @Environment(\.workspaceService) private var workspaceService
    let repos: [Repo]
    @Binding var selectedWorkspace: Workspace?
    let defaultHostPath: String
    let hasDefaultHostSession: Bool
    let isDefaultHostSessionActive: Bool
    let liveRepoPaths: Set<String>
    let activeRepoPath: String?
    let onDefaultHostSelected: () -> Void
    let onRepoSelected: (Repo) -> Void

    @State private var isAddingRepo = false
    @State private var repoForNewWorkspace: Repo?

    // Error alert state
    @State private var errorMessage: String?
    @State private var showingError = false

    // Delete confirmation state
    @State private var workspaceToDelete: Workspace?
    @State private var showingDeleteConfirmation = false

    @State private var didAttemptDefaultRepoImport = false

    var allWorkspaces: [Workspace] {
        repos.flatMap(\.workspaces).sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    var body: some View {
        List(selection: $selectedWorkspace) {
            // Repositories Section
            Section("Repositories") {
                Button {
                    onDefaultHostSelected()
                } label: {
                    HostTerminalRow(
                        defaultHostPath: defaultHostPath,
                        hasLiveSession: hasDefaultHostSession,
                        isActiveSession: isDefaultHostSessionActive
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if repos.isEmpty {
                    Text("No repositories")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(repos) { repo in
                        let normalizedRepoPath = normalizePath(repo.localURL)
                        Button {
                            onRepoSelected(repo)
                        } label: {
                            RepoRow(
                                repo: repo,
                                hasLiveSession: liveRepoPaths.contains(normalizedRepoPath),
                                isActiveSession: activeRepoPath == normalizedRepoPath
                            )
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("New Workspace...") {
                                repoForNewWorkspace = repo
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
                    }
                }
            }

            // Workspaces Section
            Section("Workspaces") {
                if allWorkspaces.isEmpty {
                    Text("No workspaces")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(allWorkspaces) { workspace in
                        WorkspaceRow(workspace: workspace)
                            .tag(workspace)
                            .contextMenu {
                                Button("Open in New Window") {
                                    openInNewWindow(workspace)
                                }
                                .disabled(true)

                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path)
                                }

                                Divider()

                                if workspace.status == .active {
                                    Button("Archive") {
                                        workspace.status = .archived
                                    }
                                } else {
                                    Button("Unarchive") {
                                        workspace.status = .active
                                    }
                                }

                                Divider()

                                Button("Delete Workspace", role: .destructive) {
                                    deleteWorkspace(workspace)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Divider()

                Button {
                    isAddingRepo = true
                } label: {
                    Label("Add Repository", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
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
            NewWorkspaceSheet(repo: repo) { name in
                Task {
                    await createWorkspace(from: repo, name: name)
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
        }
        .onAppear {
            guard !didAttemptDefaultRepoImport else { return }
            didAttemptDefaultRepoImport = true
            Task {
                await autoImportReposFromCodeHome()
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

    private func createWorkspace(from repo: Repo, name: String) async {
        // Extract value types before crossing actor boundary
        let repoName = repo.name
        let repoLocalURL = repo.localURL

        do {
            let info = try await workspaceService.createWorkspace(
                repoName: repoName,
                repoLocalURL: repoLocalURL,
                name: name
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
                    selectedWorkspace = workspace
                    return true
                }
                modelContext.rollback()
                return false
            }

            if !didPersist {
                cleanupWorkspaceDirectoryAfterFailedPersistence(info.path)
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to create workspace: \(error.localizedDescription)"
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
        // Extract value type before crossing actor boundary
        let workspaceURL = workspace.workspaceURL

        Task {
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

    @MainActor
    private func openInNewWindow(_ workspace: Workspace) {
        // Multi-window support not yet implemented
    }

    @MainActor
    private func handleNewWorkspaceShortcut() {
        if let preferredRepo = selectedWorkspace?.sourceRepo ?? repos.first {
            repoForNewWorkspace = preferredRepo
            return
        }

        errorMessage = "Add a repository first, then create a workspace."
        showingError = true
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
        let discovered = RepositoryDiscovery.discoverGitRepositories(in: codeHome)
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

        await MainActor.run {
            var currentPaths = Set(repos.map { normalizePath($0.localURL) })
            var insertedAny = false

            for repo in importedRepos {
                let repoPath = normalizePath(repo.localURL)
                guard !currentPaths.contains(repoPath) else { continue }
                modelContext.insert(repo)
                currentPaths.insert(repoPath)
                insertedAny = true
            }

            guard insertedAny else { return }

            if !saveModelContext(action: "auto-import repositories from ~/code") {
                modelContext.rollback()
            }
        }
    }

    private func normalizePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

}
