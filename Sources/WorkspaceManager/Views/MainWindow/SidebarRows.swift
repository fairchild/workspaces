//
//  SidebarRows.swift
//  WorkspaceManager
//
//  Row views for the sidebar list
//

import SwiftUI
import WorkspaceManagerCore

private enum SidebarTreeMetrics {
    static let disclosureWidth: CGFloat = 12
    static let disclosureHeight: CGFloat = 14
    static let iconColumnWidth: CGFloat = 18
}

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
            .font(.caption2.monospacedDigit())
            .fontWeight(.medium)
            .foregroundStyle(Color.secondary.opacity(isCollapsed ? 0.95 : 0.82))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(isCollapsed ? 0.1 : 0.06))
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
        let repoName = repo.name
        let workspaceCount = repo.workspaces.count
        let showsVisibleQuickActions = showsQuickActions && isHovering
        let accessibilityDescription =
            "\(repoName), \(workspaceCount) workspace\(workspaceCount == 1 ? "" : "s"), \(sessionActivity.accessibilityDescription)"
            + (SidebarSessionActivity.showsPaneCountBadge(for: paneCount) ? ", \(paneCount) panes" : "")
            + ", \(isExpanded ? "expanded" : "collapsed")"

        HStack(spacing: 10) {
            Button(action: onToggleExpansion) {
                repoFolderIcon
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse \(repoName)" : "Expand \(repoName)")

            Button(action: onSelectRepo) {
                repoLabelContent(repoName: repoName, workspaceCount: workspaceCount)
            }
            .buttonStyle(.plain)

            if showsQuickActions {
                if showsVisibleQuickActions {
                    repoActionMenu
                } else {
                    repoActionMenuPlaceholder
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : .clear)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    private var repoFolderIcon: some View {
        Image(systemName: isExpanded ? "folder.fill" : "folder")
            .foregroundStyle(
                isSelected
                    ? Color.primary
                    : sessionActivity.iconColor(inactiveColor: Color.secondary.opacity(0.82))
            )
            .frame(width: SidebarTreeMetrics.iconColumnWidth, alignment: .center)
            .contentTransition(.symbolEffect(.replace))
    }

    private func repoLabelContent(repoName: String, workspaceCount: Int) -> some View {
        HStack(spacing: 10) {
            Text(repoName)
                .font(.callout.weight(isSelected || sessionActivity.isActive ? .semibold : .regular))
                .lineLimit(1)

            Spacer(minLength: 8)

            SessionActivityIndicator(sessionActivity: sessionActivity)

            if workspaceCount > 1, !isExpanded {
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

    private var repoActionMenuPlaceholder: some View {
        Color.clear
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
                }
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .frame(width: 22, height: 22)
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

    private var isBusy: Bool {
        statusMessage != nil || workspace.status == .provisioning
    }

    private var providerIconName: String {
        switch workspace.backend {
        case .lume:
            return "desktopcomputer"
        case .daytona:
            return workspace.status == .active ? "cloud.fill" : "cloud"
        case .local, .ssh, .unknown:
            return sessionActivity.isActive ? "terminal.fill" : "terminal"
        }
    }

    private var providerIconColor: Color {
        switch workspace.backend {
        case .lume:
            return workspace.status == .active ? .teal : .secondary
        case .daytona:
            return workspace.status == .active ? .blue : .secondary
        case .local, .ssh, .unknown:
            return sessionActivity.iconColor(inactiveColor: .secondary)
        }
    }

    private var statusBadgeColor: Color {
        switch workspace.status {
        case .provisioning:
            return .blue.opacity(0.2)
        case .stopped:
            return .orange.opacity(0.2)
        case .archived:
            return .secondary.opacity(0.2)
        case .active:
            return .clear
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if showsDisclosure, let onToggleExpansion {
                Button(action: onToggleExpansion) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .frame(
                            width: SidebarTreeMetrics.disclosureWidth,
                            height: SidebarTreeMetrics.disclosureHeight
                        )
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
                        .frame(width: SidebarTreeMetrics.iconColumnWidth, height: 16)
                } else {
                    Image(systemName: providerIconName)
                        .foregroundStyle(providerIconColor)
                        .frame(width: SidebarTreeMetrics.iconColumnWidth, alignment: .center)
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
                        .background(statusBadgeColor)
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
