import AppKit
import SwiftUI
import WorkspaceManagerCore

struct HostTerminalSessionStack: View {
    let sessions: [HostTerminalSession]
    let activeSessionID: UUID?
    /// The active tab's arrangement, or `nil` for a single-pane tab (sparse model).
    let tree: TileTreeState?
    let resolveSession: (TileID) -> HostTerminalSession?
    let surfaceStore: HostTerminalSurfaceStore
    let tabTitleOverrides: [UUID: String]
    let onSetSplitRatio: (SplitID, CGFloat) -> Void
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onRenameTab: ((UUID, String?) -> Void)?
    var onCloseConfirmationRequired: ((UUID) -> Void)?
    var onTerminalProcessExit: ((UUID) -> Void)?
    var contextMenuProvider: ((HostTerminalSession) -> NSMenu?)?

    private var activeSession: HostTerminalSession? {
        guard let activeSessionID else { return sessions.last }
        return sessions.first(where: { $0.id == activeSessionID }) ?? sessions.last
    }

    var body: some View {
        if let activeSession {
            VStack(spacing: 0) {
                if sessions.count > 1 {
                    TerminalTabStrip(
                        sessions: sessions,
                        activeSessionID: activeSession.id,
                        titleForSession: tabTitle(for:),
                        onSelectTab: onSelectTab,
                        onCloseTab: onCloseTab,
                        onRenameTab: onRenameTab
                    )
                }

                if let tree {
                    TileTreeView(
                        tree: tree,
                        resolveSession: resolveSession,
                        surfaceStore: surfaceStore,
                        onSetSplitRatio: onSetSplitRatio,
                        onCloseConfirmationRequired: onCloseConfirmationRequired,
                        onTerminalProcessExit: onTerminalProcessExit,
                        contextMenuProvider: contextMenuProvider
                    )
                } else {
                    HostTerminalPaneView(
                        session: activeSession,
                        minAxis: nil,
                        surfaceStore: surfaceStore,
                        onCloseConfirmationRequired: onCloseConfirmationRequired,
                        onTerminalProcessExit: onTerminalProcessExit,
                        contextMenuProvider: contextMenuProvider
                    )
                }
            }
        }
    }

    private func tabTitle(for session: HostTerminalSession) -> String {
        tabTitleOverrides[session.id] ?? surfaceStore.displayTitle(for: session)
    }
}

private struct TerminalTabStrip: View {
    private static let titleWidth: CGFloat = 160

    let sessions: [HostTerminalSession]
    let activeSessionID: UUID
    let titleForSession: (HostTerminalSession) -> String
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onRenameTab: ((UUID, String?) -> Void)?

    @State private var editingSessionID: UUID?
    @State private var editingTitle = ""
    @State private var editingOriginalTitle = ""
    @FocusState private var isEditingTitleFocused: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(sessions) { session in
                    tabButton(for: session)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onChange(of: sessions.map(\.id)) { _, sessionIDs in
            guard let editingSessionID, !sessionIDs.contains(editingSessionID) else { return }
            cancelRename()
        }
    }

    private func tabButton(for session: HostTerminalSession) -> some View {
        let isActive = session.id == activeSessionID
        let title = titleForSession(session)
        let isEditing = editingSessionID == session.id
        return HStack(spacing: 6) {
            Group {
                if isEditing {
                    TextField("", text: $editingTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .frame(width: Self.titleWidth, alignment: .leading)
                        .focused($isEditingTitleFocused)
                        .onSubmit {
                            commitRename(for: session)
                        }
                        .onExitCommand {
                            cancelRename()
                        }
                        .onAppear {
                            isEditingTitleFocused = true
                        }
                        .onChange(of: isEditingTitleFocused) { _, isFocused in
                            guard !isFocused else { return }
                            commitRename(for: session)
                        }
                } else {
                    Button {
                        handleTabTap(session, isActive: isActive, title: title)
                    } label: {
                        Text(title)
                            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: Self.titleWidth, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .help(isActive ? "Rename Tab" : title)
            .accessibilityLabel(
                isEditing ? "Tab Title" : (isActive ? "Rename \(title)" : title)
            )

            Button {
                onCloseTab?(session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Close Tab")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Color(nsColor: .selectedControlColor).opacity(0.26) : Color.clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(isActive ? Color(nsColor: .separatorColor) : Color.clear, lineWidth: 1)
        }
    }

    private func handleTabTap(_ session: HostTerminalSession, isActive: Bool, title: String) {
        guard isActive else {
            onSelectTab?(session.id)
            return
        }

        beginRename(sessionID: session.id, title: title)
    }

    private func beginRename(sessionID: UUID, title: String) {
        editingSessionID = sessionID
        editingTitle = title
        editingOriginalTitle = title
        isEditingTitleFocused = true
    }

    private func commitRename(for session: HostTerminalSession) {
        guard editingSessionID == session.id else { return }

        let renameAction = TerminalTabRenameAction.resolve(
            originalTitle: editingOriginalTitle,
            editedTitle: editingTitle
        )
        editingSessionID = nil
        editingTitle = ""
        editingOriginalTitle = ""
        isEditingTitleFocused = false

        switch renameAction {
        case .unchanged:
            break
        case .clearOverride:
            onRenameTab?(session.id, nil)
        case .setOverride(let title):
            onRenameTab?(session.id, title)
        }
    }

    private func cancelRename() {
        editingSessionID = nil
        editingTitle = ""
        editingOriginalTitle = ""
        isEditingTitleFocused = false
    }
}

enum TerminalTabRenameAction: Equatable {
    case unchanged
    case clearOverride
    case setOverride(String)

    static func resolve(originalTitle: String, editedTitle: String) -> Self {
        let original = normalized(originalTitle)
        let edited = normalized(editedTitle)

        guard original != edited else { return .unchanged }
        guard !edited.isEmpty else { return .clearOverride }
        return .setOverride(edited)
    }

    private static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
