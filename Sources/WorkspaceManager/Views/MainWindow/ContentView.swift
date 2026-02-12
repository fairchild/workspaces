//
//  ContentView.swift
//  WorkspaceManager
//
//  Main three-column layout: Sidebar | Terminal | Right Pane
//

import SwiftData
import SwiftUI
import WorkspaceManagerCore

struct ContentView: View {
    @Query(sort: \Repo.addedAt, order: .reverse) private var repos: [Repo]

    @State private var selectedWorkspace: Workspace?
    @State private var isRightPaneVisible = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                repos: repos,
                selectedWorkspace: $selectedWorkspace
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 350)
        } detail: {
            if let workspace = selectedWorkspace {
                WorkspaceDetailView(
                    workspace: workspace,
                    isRightPaneVisible: $isRightPaneVisible
                )
            } else {
                EmptyStateView()
            }
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
    }
}

// MARK: - Workspace Detail (Terminal + Right Pane)

struct WorkspaceDetailView: View {
    let workspace: Workspace
    @Binding var isRightPaneVisible: Bool

    var body: some View {
        HSplitView {
            // Main terminal panel
            TerminalContainerView(workspace: workspace)
                .id(workspace.id)
                .frame(minWidth: 400)

            // Collapsible right pane
            if isRightPaneVisible {
                RightPaneView(workspace: workspace)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
            }
        }
        .navigationTitle(workspace.name)
        .navigationSubtitle(workspace.sourceRepo?.name ?? "")
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Workspace Selected")
                .font(.title2)
                .fontWeight(.medium)

            Text("Add a repository and create a workspace to get started.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Label("Add a git repository from your Mac", systemImage: "1.circle.fill")
                Label("Fork it to create an isolated workspace", systemImage: "2.circle.fill")
                Label("Run Claude Code in the embedded terminal", systemImage: "3.circle.fill")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Repo.self, Workspace.self], inMemory: true)
}
