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
                        onCloseTab: onCloseTab
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
    let sessions: [HostTerminalSession]
    let activeSessionID: UUID
    let titleForSession: (HostTerminalSession) -> String
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?

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
    }

    private func tabButton(for session: HostTerminalSession) -> some View {
        let isActive = session.id == activeSessionID
        return HStack(spacing: 6) {
            Button {
                onSelectTab?(session.id)
            } label: {
                Text(titleForSession(session))
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(titleForSession(session))

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
}
