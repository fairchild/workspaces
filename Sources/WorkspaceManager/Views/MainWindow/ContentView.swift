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
    @State private var hostTerminalDirectory = HostTerminalDefaults.defaultWorkingDirectory()
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
            MainTerminalDetailView(
                selectedWorkspace: selectedWorkspace,
                hostTerminalDirectory: hostTerminalDirectory,
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
    }
}

// MARK: - Main Terminal (Host-pinned)

struct MainTerminalDetailView: View {
    let selectedWorkspace: Workspace?
    let hostTerminalDirectory: URL
    @Binding var isRightPaneVisible: Bool

    var body: some View {
        HSplitView {
            // Main terminal panel
            TerminalContainerView(hostDirectory: hostTerminalDirectory)
                .id(hostTerminalDirectory.path)
                .frame(minWidth: 400)

            // Collapsible right pane
            if isRightPaneVisible, let selectedWorkspace {
                RightPaneView(workspace: selectedWorkspace)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
            }
        }
        .navigationTitle(selectedWorkspace?.name ?? "Host")
        .navigationSubtitle(selectedWorkspace?.sourceRepo?.name ?? hostTerminalDirectory.path)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Repo.self, Workspace.self], inMemory: true)
}
