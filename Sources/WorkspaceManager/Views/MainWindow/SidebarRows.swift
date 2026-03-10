//
//  SidebarRows.swift
//  WorkspaceManager
//
//  Row views for the sidebar list
//

import SwiftUI
import WorkspaceManagerCore

enum SidebarSessionActivity: Equatable {
    case inactive
    case live
    case active

    init(hasLiveSession: Bool, isActiveSession: Bool) {
        if isActiveSession {
            self = .active
        } else if hasLiveSession {
            self = .live
        } else {
            self = .inactive
        }
    }

    var isActive: Bool {
        self == .active
    }

    var hasLiveSession: Bool {
        self != .inactive
    }

    var indicatorColor: Color {
        switch self {
        case .inactive:
            return .clear
        case .live:
            return Color.accentColor.opacity(0.75)
        case .active:
            return .accentColor
        }
    }

    func iconColor(inactiveColor: Color) -> Color {
        if isActive {
            return .primary
        }
        if hasLiveSession {
            return .secondary
        }
        return inactiveColor
    }

    var badgeColor: Color {
        isActive ? .primary : .secondary
    }

    var accessibilityDescription: String {
        switch self {
        case .inactive:
            return "no live session"
        case .live:
            return "live session"
        case .active:
            return "active session"
        }
    }

    static func showsPaneCountBadge(for paneCount: Int) -> Bool {
        paneCount > 1
    }
}

private struct WorkspaceCountBadge: View {
    let count: Int
    let isCollapsed: Bool

    var body: some View {
        Text("\(count)")
            .font(.caption.monospacedDigit())
            .fontWeight(.medium)
            .foregroundStyle(Color.primary.opacity(isCollapsed ? 0.92 : 0.78))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(isCollapsed ? 0.14 : 0.08))
            )
            .accessibilityLabel("\(count) workspace\(count == 1 ? "" : "s")")
    }
}

private struct PaneCountBadge: View {
    let count: Int
    let sessionActivity: SidebarSessionActivity

    var body: some View {
        Text("\(count)")
            .font(.caption2.monospacedDigit())
            .fontWeight(.medium)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(sessionActivity.badgeColor)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(sessionActivity.isActive ? 0.16 : 0.1))
            )
            .accessibilityLabel("\(count) pane\(count == 1 ? "" : "s")")
    }
}

private struct SessionActivityIndicator: View {
    let sessionActivity: SidebarSessionActivity

    var body: some View {
        if sessionActivity.hasLiveSession {
            Circle()
                .fill(sessionActivity.indicatorColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        }
    }
}

struct RepoRow: View {
    let repo: Repo
    let sessionActivity: SidebarSessionActivity
    let paneCount: Int
    let isSelected: Bool
    let isExpanded: Bool
    let onToggleExpansion: () -> Void
    let onSelectRepo: () -> Void
    let onNewWorkspace: (() -> Void)?
    let onNewWebView: (() -> Void)?

    @State private var isHovering = false

    private var showsQuickActions: Bool {
        onNewWorkspace != nil || onNewWebView != nil
    }

    var body: some View {
        let workspaceCount = repo.workspaces.count

        HStack(spacing: 10) {
            Button(action: onToggleExpansion) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)

            Button(action: onSelectRepo) {
                rowContent(workspaceCount: workspaceCount)
            }
            .buttonStyle(.plain)

            if showsQuickActions {
                repoActionMenu
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .accessibilityHidden(!isHovering)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : .clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(repo.name), \(repo.workspaces.count) workspace\(repo.workspaces.count == 1 ? "" : "s"), \(sessionActivity.accessibilityDescription)"
                + (SidebarSessionActivity.showsPaneCountBadge(for: paneCount) ? ", \(paneCount) panes" : "")
                + ", \(isExpanded ? "expanded" : "collapsed")"
        )
    }

    private func rowContent(workspaceCount: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(
                    isSelected ? Color.primary : sessionActivity.iconColor(inactiveColor: .secondary)
                )
                .frame(width: 18, alignment: .leading)

            Text(repo.name)
                .font(.callout.weight(isSelected || sessionActivity.isActive ? .semibold : .regular))
                .lineLimit(1)

            Spacer(minLength: 8)

            SessionActivityIndicator(sessionActivity: sessionActivity)

            if workspaceCount > 0, !isExpanded {
                WorkspaceCountBadge(
                    count: workspaceCount,
                    isCollapsed: true
                )
            }

            if SidebarSessionActivity.showsPaneCountBadge(for: paneCount) {
                PaneCountBadge(count: paneCount, sessionActivity: sessionActivity)
                    .help("\(paneCount) open panes")
            }
        }
        .contentShape(Rectangle())
    }

    private var repoActionMenu: some View {
        Menu {
            if let onNewWorkspace {
                Button("New Workspace") {
                    onNewWorkspace()
                }
            }

            if let onNewWebView {
                Button("Add Web View") {
                    onNewWebView()
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 20, height: 20)
    }
}

struct WorkspaceRow: View {
    let workspace: Workspace
    var isSelected: Bool = false
    var statusMessage: String? = nil
    var sessionActivity: SidebarSessionActivity = .inactive
    var paneCount: Int = 0
    var isNested: Bool = false
    var isExpanded: Bool = false
    var showsDisclosure: Bool = false
    var onToggleExpansion: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil

    private var isBusy: Bool { statusMessage != nil }

    var body: some View {
        HStack(spacing: 10) {
            if showsDisclosure, let onToggleExpansion {
                Button(action: onToggleExpansion) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
            }

            if let onSelect {
                Button(action: onSelect) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .padding(.leading, isNested ? 18 : 0)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : .clear)
        )
        .accessibilityLabel(
            "\(workspace.name), \(sessionActivity.accessibilityDescription)"
                + (SidebarSessionActivity.showsPaneCountBadge(for: paneCount) ? ", \(paneCount) panes" : "")
                + (workspace.status == .archived ? ", archived" : "")
                + (statusMessage.map { ", \($0)" } ?? "")
        )
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(
                        systemName: workspace.isRemote
                            ? (workspace.status == .active ? "cloud.fill" : "cloud")
                            : (sessionActivity.isActive ? "terminal.fill" : "terminal")
                    )
                    .foregroundStyle(
                        workspace.isRemote
                            ? (workspace.status == .active ? .accentColor : .secondary)
                            : sessionActivity.iconColor(inactiveColor: .secondary)
                    )
                    .frame(width: 16, alignment: .center)
                }

                Text(workspace.name)
                    .font(.callout.weight(isSelected || sessionActivity.isActive ? .semibold : .regular))
                    .lineLimit(1)

                if !isBusy, workspace.status != .active {
                    Text(workspace.status.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            workspace.status == .stopped
                                ? Color.orange.opacity(0.14)
                                : Color.secondary.opacity(0.2)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                Spacer(minLength: 8)

                SessionActivityIndicator(sessionActivity: sessionActivity)

                if SidebarSessionActivity.showsPaneCountBadge(for: paneCount) {
                    PaneCountBadge(count: paneCount, sessionActivity: sessionActivity)
                        .help("\(paneCount) open panes")
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
