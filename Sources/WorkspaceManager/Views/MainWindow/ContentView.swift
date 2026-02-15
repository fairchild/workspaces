//
//  ContentView.swift
//  WorkspaceManager
//
//  Main three-column layout: Sidebar | Terminal | Right Pane
//

import AppKit
import SwiftData
import SwiftUI
import WorkspaceManagerCore

struct ContentView: View {
    @Binding var deepLinkState: WorkspaceDeepLinkState
    @ObservedObject var hostTerminalState: HostTerminalStateStore
    @Query(sort: \Repo.addedAt, order: .reverse) private var repos: [Repo]

    @State private var selectedWorkspace: Workspace?
    @State private var isRightPaneVisible = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                repos: repos,
                selectedWorkspace: $selectedWorkspace,
                onRepoSelected: handleRepoSelection
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 350)
        } detail: {
            MainTerminalDetailView(
                selectedWorkspace: selectedWorkspace,
                hostTerminalSessions: hostTerminalState.sessions,
                activeHostTerminalSessionID: hostTerminalState.activeSessionID,
                hostSurfaceStore: hostTerminalState.surfaceStore,
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
        .onAppear {
            ensureInitialHostSession()
            processPendingDeepLink()
        }
        .onChange(of: deepLinkState.pendingRequest) { _, _ in
            processPendingDeepLink()
        }
        .onChange(of: repos.count) { _, _ in
            processPendingDeepLink()
        }
    }

    private func processPendingDeepLink() {
        guard let request = deepLinkState.pendingRequest else { return }

        guard let workspace = bestWorkspaceMatch(for: request.cwd) else {
            // On cold launch, wait for SwiftData to load before deciding this is a no-match.
            if repos.isEmpty { return }
            NSLog("[DeepLink] No workspace match for cwd: %@", request.cwd)
            deepLinkState.clearPendingRequest()
            return
        }

        NSLog(
            "[DeepLink] Matched workspace '%@' for cwd '%@' (session_id=%@ source=%@)",
            workspace.name,
            request.cwd,
            request.sessionID ?? "",
            request.source ?? ""
        )

        selectedWorkspace = workspace
        columnVisibility = .all
        deepLinkState.clearPendingRequest()
        focusWorkspaceWindow()
    }

    @MainActor
    private func handleRepoSelection(_ repo: Repo) {
        let repoDirectory = repo.localURL.standardizedFileURL.resolvingSymlinksInPath()

        selectedWorkspace = nil
        activateHostSession(
            key: .repoPath(repoDirectory.path),
            directory: repoDirectory
        )
        columnVisibility = .all

        requestMainTerminalFocus(targetPath: repoDirectory.path)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Task { @MainActor in
                requestMainTerminalFocus(targetPath: repoDirectory.path)
            }
        }
    }

    @MainActor
    private func ensureInitialHostSession() {
        guard hostTerminalState.sessions.isEmpty else { return }
        activateHostSession(
            key: .defaultHome,
            directory: HostTerminalDefaults.defaultWorkingDirectory()
        )
    }

    @MainActor
    private func activateHostSession(key: HostTerminalSessionKey, directory: URL) {
        let normalizedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedPath = normalizedDirectory.path

        if let existing = hostTerminalState.sessions.first(where: { $0.key == key }) {
            hostTerminalState.activeSessionID = existing.id
            NSLog(
                "[HostSession] Reusing session %@ key=%@ path=%@",
                existing.id.uuidString,
                key.debugDescription,
                existing.path
            )
            return
        }

        if let existing = hostTerminalState.sessions.first(where: { $0.path == normalizedPath }) {
            hostTerminalState.activeSessionID = existing.id
            NSLog(
                "[HostSession] Reusing session by path %@ key=%@ path=%@",
                existing.id.uuidString,
                key.debugDescription,
                existing.path
            )
            return
        }

        let session = HostTerminalSession(
            id: UUID(),
            key: key,
            directory: normalizedDirectory,
            path: normalizedPath
        )

        hostTerminalState.sessions.append(session)
        hostTerminalState.activeSessionID = session.id
        NSLog(
            "[HostSession] Created session %@ key=%@ path=%@ (total sessions=%ld)",
            session.id.uuidString,
            key.debugDescription,
            normalizedPath,
            hostTerminalState.sessions.count
        )
    }

    private func bestWorkspaceMatch(for cwd: String) -> Workspace? {
        let normalizedCWD = normalizePath(cwd)

        let matches = repos
            .flatMap(\.workspaces)
            .compactMap { workspace -> (workspace: Workspace, matchLength: Int)? in
                let workspacePath = normalizePath(workspace.path)
                guard path(normalizedCWD, isInside: workspacePath) else { return nil }
                return (workspace, workspacePath.count)
            }

        return matches
            .sorted { lhs, rhs in
                if lhs.matchLength == rhs.matchLength {
                    return lhs.workspace.lastAccessedAt > rhs.workspace.lastAccessedAt
                }
                return lhs.matchLength > rhs.matchLength
            }
            .first?
            .workspace
    }

    private func focusWorkspaceWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first(where: \.isVisible) ?? NSApp.windows.first
        window?.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let terminal = TerminalFocusManager.shared.focusedTerminal else { return }
            TerminalFocusManager.shared.requestFocus(for: terminal)
        }
    }

    @MainActor
    private func requestMainTerminalFocus(targetPath: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first(where: \.isVisible) ?? NSApp.windows.first
        window?.makeKeyAndOrderFront(nil)

        if let rootView = window?.contentView {
            if let targetPath,
                let terminal = findTerminalView(in: rootView, targetPath: targetPath)
            {
                TerminalFocusManager.shared.requestFocus(for: terminal)
                return
            }

            if let terminal = findTerminalView(in: rootView, targetPath: nil) {
                TerminalFocusManager.shared.requestFocus(for: terminal)
                return
            }
        }

        if let terminal = TerminalFocusManager.shared.focusedTerminal {
            TerminalFocusManager.shared.requestFocus(for: terminal)
        }
    }

    private func findTerminalView(in view: NSView, targetPath: String?) -> NSView? {
        if let terminal = view as? GhosttySurfaceView {
            if let targetPath {
                if terminal.workingDirectoryPath == targetPath {
                    return terminal
                }
            } else {
                return terminal
            }
        }

        for child in view.subviews {
            if let terminal = findTerminalView(in: child, targetPath: targetPath) {
                return terminal
            }
        }

        return nil
    }

    private func path(_ path: String, isInside root: String) -> Bool {
        if path == root { return true }
        guard root != "/" else { return true }
        return path.hasPrefix(root + "/")
    }

    private func normalizePath(_ rawPath: String) -> String {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

// MARK: - Main Terminal (Host-pinned)

struct MainTerminalDetailView: View {
    let selectedWorkspace: Workspace?
    let hostTerminalSessions: [HostTerminalSession]
    let activeHostTerminalSessionID: UUID?
    let hostSurfaceStore: HostTerminalSurfaceStore
    @Binding var isRightPaneVisible: Bool

    private var activeHostSession: HostTerminalSession? {
        guard let activeHostTerminalSessionID else { return hostTerminalSessions.last }
        return hostTerminalSessions.first(where: { $0.id == activeHostTerminalSessionID }) ?? hostTerminalSessions.last
    }

    var body: some View {
        HSplitView {
            // Main terminal panel
            HostTerminalSessionStack(
                sessions: hostTerminalSessions,
                activeSessionID: activeHostTerminalSessionID,
                surfaceStore: hostSurfaceStore
            )
            .frame(minWidth: 400)

            // Collapsible right pane
            if isRightPaneVisible, let selectedWorkspace {
                RightPaneView(workspace: selectedWorkspace)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
            }
        }
        .navigationTitle(selectedWorkspace?.name ?? "Host")
        .navigationSubtitle(selectedWorkspace?.sourceRepo?.name ?? (activeHostSession?.directory.path ?? ""))
    }
}

struct HostTerminalSessionStack: View {
    let sessions: [HostTerminalSession]
    let activeSessionID: UUID?
    let surfaceStore: HostTerminalSurfaceStore

    private var resolvedActiveSessionID: UUID? {
        activeSessionID ?? sessions.last?.id
    }

    var body: some View {
        ZStack {
            ForEach(sessions) { session in
                let isActive = session.id == resolvedActiveSessionID
                PersistentHostTerminalContainerView(
                    session: session,
                    surfaceStore: surfaceStore
                )
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                    .accessibilityHidden(!isActive)
            }
        }
    }
}

struct HostTerminalSession: Identifiable, Hashable {
    let id: UUID
    let key: HostTerminalSessionKey
    let directory: URL
    let path: String
}

@MainActor
final class HostTerminalStateStore: ObservableObject {
    static let shared = HostTerminalStateStore()

    @Published var sessions: [HostTerminalSession] = []
    @Published var activeSessionID: UUID?
    let surfaceStore = HostTerminalSurfaceStore()
}

enum HostTerminalSessionKey: Hashable, CustomDebugStringConvertible {
    case defaultHome
    case repoPath(String)

    var debugDescription: String {
        switch self {
        case .defaultHome:
            return "defaultHome"
        case .repoPath(let path):
            return "repoPath(\(path))"
        }
    }
}

#Preview {
    ContentViewPreviewHost()
        .modelContainer(for: [Repo.self, Workspace.self], inMemory: true)
}

private struct ContentViewPreviewHost: View {
    @State private var deepLinkState = WorkspaceDeepLinkState()
    @StateObject private var hostTerminalState = HostTerminalStateStore.shared

    var body: some View {
        ContentView(
            deepLinkState: $deepLinkState,
            hostTerminalState: hostTerminalState
        )
    }
}
