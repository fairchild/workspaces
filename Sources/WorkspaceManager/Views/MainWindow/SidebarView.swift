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

    @State private var isAddingRepo = false
    @State private var repoForNewWorkspace: Repo?

    // Error alert state
    @State private var errorMessage: String?
    @State private var showingError = false

    // Delete confirmation state
    @State private var workspaceToDelete: Workspace?
    @State private var showingDeleteConfirmation = false

    var allWorkspaces: [Workspace] {
        repos.flatMap(\.workspaces).sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    var body: some View {
        List(selection: $selectedWorkspace) {
            // Repositories Section
            Section("Repositories") {
                if repos.isEmpty {
                    Text("No repositories")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(repos) { repo in
                        RepoRow(repo: repo)
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

            // Create model on main actor side from Sendable info
            let workspace = Workspace(
                name: info.name,
                path: info.path,
                sourceRepo: repo,
                gitBranch: info.gitBranch
            )

            var didPersist = false
            await MainActor.run {
                modelContext.insert(workspace)
                if saveModelContext(action: "save workspace") {
                    didPersist = true
                    selectedWorkspace = workspace
                } else {
                    modelContext.rollback()
                }
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

}
