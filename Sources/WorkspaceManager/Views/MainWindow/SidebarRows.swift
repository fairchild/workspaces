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

    private var liveStatusColor: Color {
        switch self {
        case .inactive:
            return .secondary
        case .live:
            return .mint
        case .active:
            return .green
        }
    }

    func iconColor(inactiveColor: Color) -> Color {
        hasLiveSession ? liveStatusColor : inactiveColor
    }

    var badgeColor: Color {
        hasLiveSession ? liveStatusColor : .secondary
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
            .fontWeight(.semibold)
            .foregroundStyle(Color.primary.opacity(isCollapsed ? 0.96 : 0.9))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(
                        isCollapsed
                            ? Color.accentColor.opacity(0.26)
                            : Color.secondary.opacity(0.18)
                    )
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isCollapsed ? 0.12 : 0.08), lineWidth: 0.5)
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
            .fontWeight(.semibold)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(sessionActivity.badgeColor)
            .background(
                Capsule()
                    .fill(sessionActivity.badgeColor.opacity(sessionActivity.isActive ? 0.14 : 0.12))
            )
            .overlay(
                Capsule()
                    .stroke(sessionActivity.badgeColor.opacity(0.22), lineWidth: 0.5)
            )
            .accessibilityLabel("\(count) pane\(count == 1 ? "" : "s")")
    }
}

struct HostTerminalRow: View {
    let defaultHostPath: String
    let sessionActivity: SidebarSessionActivity
    let paneCount: Int

    private var displayHostPath: String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if defaultHostPath == homePath {
            return "~"
        }
        if defaultHostPath.hasPrefix(homePath + "/") {
            return "~" + defaultHostPath.dropFirst(homePath.count)
        }
        return defaultHostPath
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: sessionActivity.isActive ? "house.fill" : "house")
                .foregroundStyle(sessionActivity.iconColor(inactiveColor: .orange))

            Text(displayHostPath)
                .font(.system(size: 16, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if SidebarSessionActivity.showsPaneCountBadge(for: paneCount) {
                PaneCountBadge(count: paneCount, sessionActivity: sessionActivity)
                    .help("\(paneCount) open panes")
            }
        }
        .accessibilityLabel(
            "Code home \(displayHostPath), \(sessionActivity.accessibilityDescription)"
                + (SidebarSessionActivity.showsPaneCountBadge(for: paneCount) ? ", \(paneCount) panes" : "")
        )
    }
}

struct RepoRow: View {
    let repo: Repo
    let sessionActivity: SidebarSessionActivity
    let paneCount: Int
    let isExpanded: Bool
    let onToggleExpansion: () -> Void
    let onSelectRepo: () -> Void

    var body: some View {
        let workspaceCount = repo.workspaces.count

        HStack(spacing: 10) {
            Button(action: onToggleExpansion) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(repo.workspaces.isEmpty ? .tertiary : .secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(repo.workspaces.isEmpty)

            Button(action: onSelectRepo) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(sessionActivity.iconColor(inactiveColor: .blue))
                        .frame(width: 18, alignment: .leading)

                    Text(repo.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if workspaceCount > 0 {
                        WorkspaceCountBadge(
                            count: workspaceCount,
                            isCollapsed: !isExpanded
                        )
                    }

                    if SidebarSessionActivity.showsPaneCountBadge(for: paneCount) {
                        PaneCountBadge(count: paneCount, sessionActivity: sessionActivity)
                            .help("\(paneCount) open panes")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(repo.name), \(repo.workspaces.count) workspace\(repo.workspaces.count == 1 ? "" : "s"), \(sessionActivity.accessibilityDescription)"
                + (SidebarSessionActivity.showsPaneCountBadge(for: paneCount) ? ", \(paneCount) panes" : "")
                + ", \(isExpanded ? "expanded" : "collapsed")"
        )
    }
}

struct WorkspaceRow: View {
    let workspace: Workspace
    var isSelected: Bool = false
    var statusMessage: String? = nil
    var sessionActivity: SidebarSessionActivity = .inactive
    var paneCount: Int = 0
    var isNested: Bool = false

    private var isBusy: Bool { statusMessage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
                            ? (workspace.status == .active ? .blue : .secondary)
                            : sessionActivity.iconColor(inactiveColor: .secondary)
                    )
                }

                Text(workspace.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)

                if !isBusy, workspace.status != .active {
                    Text(workspace.status.label)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            workspace.status == .stopped
                                ? Color.orange.opacity(0.2)
                                : Color.secondary.opacity(0.2)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                Spacer(minLength: 8)

                if SidebarSessionActivity.showsPaneCountBadge(for: paneCount) {
                    PaneCountBadge(count: paneCount, sessionActivity: sessionActivity)
                        .help("\(paneCount) open panes")
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, isNested ? 24 : 24)
            }
        }
        .padding(.leading, isNested ? 20 : 0)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : .clear)
        )
        .accessibilityLabel(
            "\(workspace.name), \(sessionActivity.accessibilityDescription)"
                + (SidebarSessionActivity.showsPaneCountBadge(for: paneCount) ? ", \(paneCount) panes" : "")
                + (workspace.status == .archived ? ", archived" : "")
                + (statusMessage.map { ", \($0)" } ?? "")
        )
    }
}
