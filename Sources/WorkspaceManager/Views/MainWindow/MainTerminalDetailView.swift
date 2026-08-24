//
//  MainTerminalDetailView.swift
//  WorkspaceManager
//
//  The detail column's terminal surface: the tile tree, its tab bar, the code preview, and the
//  right pane. Lifted out of ContentView.swift unchanged — it was always its own view type, only
//  its file was shared.
//

import AppKit
import SwiftUI
import WorkspaceManagerCore

struct MainTerminalDetailView: View {
    @ObservedObject var appCommandState: AppCommandState
    let selectedWorkspace: Workspace?
    let selectedRepo: Repo?
    let activeHostSession: HostTerminalSession?
    let hostTerminalSessions: [HostTerminalSession]
    let visibleHostTerminalSessions: [HostTerminalSession]
    let activeHostTerminalSessionID: UUID?
    let activeTabTree: TileTreeState?
    let resolveTileSession: (TileID) -> HostTerminalSession?
    let resolveTileID: (HostTerminalSession) -> TileID
    let hostSurfaceStore: SurfaceStore
    let tabTitleOverrides: [UUID: String]
    let agentSessionRegistry: AgentSessionRegistry
    let terminalContextMenuProvider: (HostTerminalSession) -> NSMenu?
    let onSetSplitRatio: (SplitID, CGFloat) -> Void
    var onSelectTerminalTab: ((UUID) -> Void)?
    var onCloseTerminalTab: ((UUID) -> Void)?
    var onRenameTerminalTab: ((UUID, String?) -> Void)?
    var onTerminalCloseConfirmationRequired: ((UUID) -> Void)?
    var onTerminalProcessExit: ((UUID) -> Void)?
    @Binding var selectedCodePreview: CodePreviewSelection?
    @Binding var isTerminalPanelVisible: Bool
    let onFileSelected: (CodePreviewSelection) -> Void
    let availableEditors: [ExternalEditorDescriptor]
    let defaultEditor: ExternalEditorDescriptor?
    let onOpenInDefaultEditor: () -> Void
    let onOpenInEditor: (ExternalEditorID) -> Void
    let onCodePreviewSaved: () -> Void
    /// Close the preview, routed through the dirty-navigation guard so unsaved edits prompt first.
    let onCloseCodePreview: () -> Void
    let rightPaneStateStore: RightPaneStateStore
    @Binding var isRightPaneVisible: Bool

    var body: some View {
        HSplitView {
            previewAndTerminalPanel
                .frame(minWidth: 400)

            // Collapsible right pane
            if isRightPaneVisible {
                if let selectedWorkspace {
                    let state = rightPaneStateStore.state(for: selectedWorkspace)
                    RightPaneView(
                        workspace: selectedWorkspace,
                        state: state,
                        diagnosticWorkspaceDirectories: diagnosticWorkspaceDirectories,
                        agentSessionRegistry: agentSessionRegistry,
                        timelineHostSessionID: timelineHostSessionID(for: selectedWorkspace),
                        onFileSelected: onFileSelected
                    )
                    .rightPaneWidth(for: state)
                } else if let selectedRepo {
                    let state = rightPaneStateStore.state(for: selectedRepo)
                    RightPaneView(
                        repo: selectedRepo,
                        state: state,
                        diagnosticWorkspaceDirectories: diagnosticWorkspaceDirectories,
                        agentSessionRegistry: agentSessionRegistry,
                        onFileSelected: onFileSelected
                    )
                    .rightPaneWidth(for: state)
                }
            }
        }
        .navigationTitle(navigationTitle)
    }

    private var diagnosticWorkspaceDirectories: [URL] {
        var seen = Set<String>()
        var directories: [URL] = []

        // Split panes share their primary's directory, which is already in `hostTerminalSessions`, so
        // the tab tree contributes no new diagnostic directories.
        var candidateDirectories = hostTerminalSessions.map(\.directoryURL)
        if let selectedWorkspaceDirectory = selectedWorkspace?.localDirectoryURL {
            candidateDirectories.append(selectedWorkspaceDirectory)
        }
        if let selectedRepo {
            candidateDirectories.append(selectedRepo.localURL)
        }

        for directory in candidateDirectories {
            let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
            if seen.insert(path).inserted {
                directories.append(URL(fileURLWithPath: path, isDirectory: true))
            }
        }

        return directories
    }

    private func timelineHostSessionID(for workspace: Workspace) -> UUID? {
        guard let workspaceDirectory = workspace.localDirectoryURL else { return nil }
        let workspacePath = normalizedPath(workspaceDirectory)

        if let activeHostTerminalSessionID,
            let activeVisibleSession = visibleHostTerminalSessions.first(where: {
                $0.id == activeHostTerminalSessionID && normalizedPath($0.directoryURL) == workspacePath
            })
        {
            return activeVisibleSession.id
        }

        if let visibleSession = visibleHostTerminalSessions.first(where: {
            normalizedPath($0.directoryURL) == workspacePath
        }) {
            return visibleSession.id
        }

        return hostTerminalSessions.first {
            normalizedPath($0.directoryURL) == workspacePath
        }?.id
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    @ViewBuilder
    private var previewAndTerminalPanel: some View {
        VStack(spacing: 0) {
            previewAndTerminalPanelContent
        }
    }

    @ViewBuilder
    private var previewAndTerminalPanelContent: some View {
        if let selectedCodePreview {
            if isTerminalPanelVisible {
                VSplitView {
                    CodeFilePreviewView(
                        appCommandState: appCommandState,
                        selection: selectedCodePreview,
                        editorOptions: availableEditors,
                        defaultEditor: defaultEditor,
                        onOpenInDefaultEditor: onOpenInDefaultEditor,
                        onOpenInEditor: onOpenInEditor,
                        onSaved: onCodePreviewSaved,
                        onClose: onCloseCodePreview
                    )
                    .frame(minHeight: 220)

                    hostTerminalPanel
                        .frame(minHeight: 160)
                }
            } else {
                CodeFilePreviewView(
                    appCommandState: appCommandState,
                    selection: selectedCodePreview,
                    editorOptions: availableEditors,
                    defaultEditor: defaultEditor,
                    onOpenInDefaultEditor: onOpenInDefaultEditor,
                    onOpenInEditor: onOpenInEditor,
                    onSaved: onCodePreviewSaved,
                    onClose: onCloseCodePreview
                )
            }
        } else {
            hostTerminalPanel
        }
    }

    private var hostTerminalPanel: some View {
        HostTerminalSessionStack(
            sessions: visibleHostTerminalSessions,
            activeSessionID: activeHostTerminalSessionID,
            tree: activeTabTree,
            resolveSession: resolveTileSession,
            resolveTileID: resolveTileID,
            surfaceStore: hostSurfaceStore,
            tabTitleOverrides: tabTitleOverrides,
            onSetSplitRatio: onSetSplitRatio,
            onSelectTab: onSelectTerminalTab,
            onCloseTab: onCloseTerminalTab,
            onRenameTab: onRenameTerminalTab,
            onCloseConfirmationRequired: onTerminalCloseConfirmationRequired,
            onTerminalProcessExit: onTerminalProcessExit,
            contextMenuProvider: terminalContextMenuProvider
        )
    }

    private var navigationTitle: String {
        MainWindowPresentationController().toolbarTitle(
            selectedWorkspace: selectedWorkspace,
            selectedRepo: selectedWorkspace?.sourceRepo ?? selectedRepo,
            activeHostSession: activeHostSession
        )?.windowTitle ?? "WorkSpaces"
    }
}
