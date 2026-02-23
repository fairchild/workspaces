//
//  SidebarRows.swift
//  WorkspaceManager
//
//  Row views for the sidebar list
//

import SwiftUI
import WorkspaceManagerCore

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

private struct LiveSessionBadge: View {
    let isActiveSession: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isActiveSession ? "terminal.fill" : "terminal")
                .font(.caption2)

            if isActiveSession {
                Text("LIVE")
                    .font(.caption2)
                    .fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .foregroundStyle(isActiveSession ? .green : .secondary)
        .background(
            Capsule()
                .fill(isActiveSession ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15))
        )
        .accessibilityLabel(isActiveSession ? "Active live terminal session" : "Live terminal session")
    }
}

struct HostTerminalRow: View {
    let defaultHostPath: String
    let hasLiveSession: Bool
    let isActiveSession: Bool

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
            Image(systemName: isActiveSession ? "house.fill" : "house")
                .foregroundStyle(.orange)

            Text(displayHostPath)
                .font(.system(size: 16, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if hasLiveSession {
                LiveSessionBadge(isActiveSession: isActiveSession)
                    .help(isActiveSession ? "Active live terminal session" : "Live terminal session")
            }
        }
        .accessibilityLabel("Code home \(displayHostPath)")
    }
}

struct RepoRow: View {
    let repo: Repo
    let hasLiveSession: Bool
    let isActiveSession: Bool
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
                        .foregroundStyle(.blue)
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

                    if hasLiveSession {
                        LiveSessionBadge(isActiveSession: isActiveSession)
                            .help(isActiveSession ? "Active live terminal session" : "Live terminal session")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(repo.name), \(repo.workspaces.count) workspace\(repo.workspaces.count == 1 ? "" : "s"), \(isExpanded ? "expanded" : "collapsed")"
        )
    }
}

struct WorkspaceRow: View {
    let workspace: Workspace
    var isSelected: Bool = false
    var isNested: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Label {
                HStack {
                    Text(workspace.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)

                    if workspace.status == .archived {
                        Text("Archived")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            } icon: {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(workspace.status == .active ? .green : .secondary)
            }
        }
        .padding(.leading, isNested ? 20 : 0)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : .clear)
        )
    }
}
