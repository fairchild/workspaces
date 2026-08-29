//
//  SidebarRows.swift
//  WorkspaceManager
//
//  Row views for the sidebar list
//

import SwiftUI
import WorkspaceManagerCore

/// The sidebar's activity type is the Core `SessionActivity` (the single encoding of the
/// attention ladder, shared with the session-switcher read model — #680). This layer only
/// adds the SwiftUI styling.
typealias SidebarSessionActivity = SessionActivity

extension SessionActivity {
    var indicatorColor: Color {
        indicatorTone.color
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
}

private struct WorkspaceCountBadge: View {
    let count: Int
    let isCollapsed: Bool

    var body: some View {
        Text("\(count)")
            .font(SidebarChrome.TypeStyle.countBadge)
            .fontWeight(.medium)
            .foregroundStyle(
                isCollapsed
                    ? SidebarChrome.Foreground.emphasizedSecondary
                    : SidebarChrome.Foreground.quietSecondary
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(
                        isCollapsed
                            ? SidebarChrome.Fill.workspaceCountBadgeCollapsed
                            : SidebarChrome.Fill.workspaceCountBadgeExpanded
                    )
            )
            .accessibilityLabel("\(count) workspace\(count == 1 ? "" : "s")")
    }
}

private struct PaneCountBadge: View {
    let count: Int
    let sessionActivity: SidebarSessionActivity

    var body: some View {
        Text("\(count)")
            .font(SidebarChrome.TypeStyle.countBadge)
            .fontWeight(.medium)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(sessionActivity.badgeColor)
            .background(
                Capsule()
                    .fill(
                        sessionActivity.isActive
                            ? SidebarChrome.Fill.paneCountBadgeActive
                            : SidebarChrome.Fill.paneCountBadgeIdle
                    )
            )
            .accessibilityLabel("\(count) pane\(count == 1 ? "" : "s")")
    }
}

private struct SessionActivityIndicator: View {
    let sessionActivity: SidebarSessionActivity
    var tooltip: String? = nil

    var body: some View {
        if sessionActivity.hasLiveSession {
            indicator
        }
    }

    @ViewBuilder
    private var indicator: some View {
        let circle = Circle()
            .fill(sessionActivity.indicatorColor)
            .frame(width: SidebarChrome.Metrics.activityDot, height: SidebarChrome.Metrics.activityDot)
            .accessibilityHidden(true)
        if let tooltip, !tooltip.isEmpty {
            circle.help(tooltip)
        } else {
            circle
        }
    }
}

struct RepoRow: View {
    let repo: Repo
    /// Non-archived workspace count; archived workspaces live in a separate collapsed
    /// section, so the badge counts only the rows shown when the repo is expanded.
    let activeWorkspaceCount: Int
    let sessionActivity: SidebarSessionActivity
    let paneCount: Int
    let isSelected: Bool
    let isExpanded: Bool
    /// False for a flat repo root that has no subtree to show: the folder glyph opens the
    /// repo, and neither the expansion state nor the child count is worth announcing.
    var showsExpansion: Bool = true
    var sessionActivityTooltip: String? = nil
    let onToggleExpansion: () -> Void
    let onSelectRepo: () -> Void
    let onNewWorkspace: (() -> Void)?
    let onNewWebView: (() -> Void)?
    /// Resolved lazily only when the hover card opens (the repo root's tabs).
    var tabsProvider: (() -> [SidebarTabSummary])? = nil

    @State private var isHovering = false

    private var showsQuickActions: Bool {
        onNewWorkspace != nil || onNewWebView != nil
    }

    private var accessibilityDescription: String {
        let workspaceCount = activeWorkspaceCount
        var description = "\(repo.name), \(workspaceCount) workspace\(workspaceCount == 1 ? "" : "s")"
        description += ", \(sessionActivity.accessibilityDescription)"
        if SidebarSessionActivity.showsPaneCountBadge(for: paneCount) {
            description += ", \(paneCount) panes"
        }
        if showsExpansion {
            description += ", \(isExpanded ? "expanded" : "collapsed")"
        }
        return description
    }

    private var folderIconHelp: String {
        guard showsExpansion else { return "Open \(repo.name)" }
        return isExpanded ? "Collapse \(repo.name)" : "Expand \(repo.name)"
    }

    var body: some View {
        let repoName = repo.name
        let workspaceCount = activeWorkspaceCount
        let showsVisibleQuickActions = showsQuickActions && isHovering

        HStack(spacing: SidebarChrome.Metrics.rowSpacing) {
            Button(action: onToggleExpansion) {
                repoFolderIcon
            }
            .buttonStyle(.plain)
            .help(folderIconHelp)

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
        .padding(.vertical, SidebarChrome.Metrics.repoRowVerticalPadding)
        .padding(.horizontal, SidebarChrome.Metrics.rowHorizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: SidebarChrome.Radius.row)
                .fill(isSelected ? SidebarChrome.Fill.rowSelection : .clear)
        )
        .sidebarHoverCard(
            onHoverChange: { isHovering = $0 },
            shouldShow: {
                SidebarInfoCard.hasContent(
                    name: repo.name, branch: nil, tabs: tabsProvider?() ?? [])
            },
            card: {
                SidebarInfoCard(name: repo.name, tabs: tabsProvider?() ?? [])
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    private var repoFolderIcon: some View {
        Image(systemName: isExpanded ? "folder.fill" : "folder")
            .foregroundStyle(
                isSelected
                    ? Color.primary
                    : sessionActivity.iconColor(inactiveColor: SidebarChrome.Foreground.quietSecondary)
            )
            .frame(width: SidebarChrome.Metrics.iconColumn, alignment: .center)
            .contentTransition(.symbolEffect(.replace))
    }

    private func repoLabelContent(repoName: String, workspaceCount: Int) -> some View {
        HStack(spacing: SidebarChrome.Metrics.rowSpacing) {
            Text(repoName)
                .font(
                    SidebarChrome.TypeStyle.rowTitle(
                        emphasized: isSelected || sessionActivity.isActive)
                )
                .lineLimit(1)

            Spacer(minLength: 8)

            SessionActivityIndicator(
                sessionActivity: sessionActivity,
                tooltip: sessionActivityTooltip
            )

            if showsExpansion, workspaceCount > 1, !isExpanded {
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
            .frame(width: SidebarChrome.Metrics.hoverActionSide, height: SidebarChrome.Metrics.hoverActionSide)
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
                .font(SidebarChrome.TypeStyle.hoverActionGlyph)
                .foregroundStyle(.secondary)
                .frame(width: SidebarChrome.Metrics.hoverActionSide, height: SidebarChrome.Metrics.hoverActionSide)
                .background(
                    RoundedRectangle(cornerRadius: SidebarChrome.Radius.hoverAction, style: .continuous)
                        .fill(SidebarChrome.Fill.hoverAction)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: SidebarChrome.Radius.hoverAction, style: .continuous)
                        .stroke(SidebarChrome.Stroke.hoverAction, lineWidth: SidebarChrome.Stroke.hoverActionWidth)
                }
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .frame(width: SidebarChrome.Metrics.hoverActionSide, height: SidebarChrome.Metrics.hoverActionSide)
    }
}

struct WorkspaceRow: View {
    let workspace: Workspace
    var isSelected: Bool = false
    var statusMessage: String? = nil
    var sessionActivity: SidebarSessionActivity = .inactive
    var paneCount: Int = 0
    /// Owning repo name, rendered as a `repo /` breadcrumb where the row is flat and its
    /// place in the tree is not otherwise visible. Nil inside a repo's subtree.
    var repoContext: String? = nil
    var isNested: Bool = false
    var isExpanded: Bool = false
    var showsDisclosure: Bool = false
    var isPinned: Bool = false
    /// Resolved lazily only when the hover card opens, so frequent agent-status
    /// updates never re-render idle rows.
    var tabsProvider: (() -> [SidebarTabSummary])? = nil
    var onToggleExpansion: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil
    /// Nil where pinning does not apply. Non-nil rows carry a hover-visible star —
    /// quiet discoverability, the same compromise `RepoRow`'s "+" makes.
    var onTogglePin: (() -> Void)? = nil
    /// Reveals the hover actions with no pointer involved. False in the app, where real
    /// hover drives them; a still render has no pointer, so the evidence PNG sets it.
    var revealsHoverActions: Bool = false

    @State private var isHovering = false

    private var showsPinAction: Bool {
        isHovering || revealsHoverActions
    }

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
            return SidebarChrome.Fill.statusBadgeProvisioning
        case .stopped:
            return SidebarChrome.Fill.statusBadgeStopped
        case .archived:
            return SidebarChrome.Fill.statusBadgeArchived
        case .active:
            return .clear
        }
    }

    var body: some View {
        HStack(spacing: SidebarChrome.Metrics.rowSpacing) {
            if showsDisclosure, let onToggleExpansion {
                Button(action: onToggleExpansion) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .frame(
                            width: SidebarChrome.Metrics.disclosureWidth,
                            height: SidebarChrome.Metrics.disclosureHeight
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

            if let onTogglePin {
                if showsPinAction {
                    pinButton(onTogglePin)
                } else {
                    pinButtonPlaceholder
                }
            }
        }
        .padding(.leading, isNested ? SidebarChrome.Indent.nestedRow : 0)
        .padding(.vertical, SidebarChrome.Metrics.rowVerticalPadding)
        .padding(.horizontal, SidebarChrome.Metrics.rowHorizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: SidebarChrome.Radius.row)
                .fill(isSelected ? SidebarChrome.Fill.rowSelection : .clear)
        )
        .accessibilityLabel(accessibilityDescription)
        .sidebarHoverCard(
            onHoverChange: { isHovering = $0 },
            shouldShow: {
                SidebarInfoCard.hasContent(
                    name: workspace.name, branch: workspace.gitBranch,
                    tabs: tabsProvider?() ?? [])
            },
            card: {
                SidebarInfoCard(
                    name: workspace.name,
                    branch: workspace.gitBranch,
                    tabs: tabsProvider?() ?? []
                )
            }
        )
    }

    private var accessibilityDescription: String {
        var description = repoContext.map { "\($0), " } ?? ""
        description += "\(workspace.name), \(sessionActivity.accessibilityDescription)"
        if SidebarSessionActivity.showsPaneCountBadge(for: paneCount) {
            description += ", \(paneCount) panes"
        }
        if workspace.status == .archived {
            description += ", archived"
        }
        if isPinned {
            description += ", pinned"
        }
        if let statusMessage {
            description += ", \(statusMessage)"
        }
        if let note = workspace.note {
            description += ", note: \(note)"
        }
        return description
    }

    private func pinButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isPinned ? "star.fill" : "star")
                .font(SidebarChrome.TypeStyle.hoverActionGlyph)
                .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                .frame(width: SidebarChrome.Metrics.hoverActionSide, height: SidebarChrome.Metrics.hoverActionSide)
                .background(
                    RoundedRectangle(cornerRadius: SidebarChrome.Radius.hoverAction, style: .continuous)
                        .fill(SidebarChrome.Fill.hoverAction)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: SidebarChrome.Radius.hoverAction, style: .continuous)
                        .stroke(SidebarChrome.Stroke.hoverAction, lineWidth: SidebarChrome.Stroke.hoverActionWidth)
                }
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Unpin \(workspace.name)" : "Pin \(workspace.name)")
    }

    private var pinButtonPlaceholder: some View {
        Color.clear
            .frame(width: SidebarChrome.Metrics.hoverActionSide, height: SidebarChrome.Metrics.hoverActionSide)
            .accessibilityHidden(true)
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: SidebarChrome.Metrics.rowContentSpacing) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: SidebarChrome.Metrics.iconColumn, height: 16)
                } else {
                    Image(systemName: providerIconName)
                        .foregroundStyle(providerIconColor)
                        .frame(width: SidebarChrome.Metrics.iconColumn, alignment: .center)
                }

                if let repoContext {
                    HStack(spacing: 3) {
                        Text(repoContext)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("/")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.callout)
                }

                Text(workspace.name)
                    .font(
                        SidebarChrome.TypeStyle.rowTitle(
                            emphasized: isSelected || sessionActivity.isActive)
                    )
                    .lineLimit(1)
                    .layoutPriority(repoContext == nil ? 0 : 1)

                if !isBusy, workspace.status != .active {
                    Text(workspace.status.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(statusBadgeColor)
                        .clipShape(RoundedRectangle(cornerRadius: SidebarChrome.Radius.statusBadge))
                }

                Spacer(minLength: 8)

                SessionActivityIndicator(sessionActivity: sessionActivity)

                if SidebarSessionActivity.showsPaneCountBadge(for: paneCount) {
                    PaneCountBadge(count: paneCount, sessionActivity: sessionActivity)
                        .help("\(paneCount) open panes")
                }
            }

            // The transient action message wins the line while it is showing: it is about
            // this moment, and the note is about the work stream. A note rendered a shade
            // quieter is what keeps a line written hours ago from reading as live status.
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, SidebarChrome.Indent.rowSecondLine)
                    .lineLimit(1)
            } else if let note = workspace.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, SidebarChrome.Indent.rowSecondLine)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Shows an info card popover after a short hover delay. The show delay avoids
/// flashing cards while the pointer crosses the list; a dismiss grace period lets
/// the pointer travel onto the card to read it (the card's own hover cancels the
/// dismiss). The card closure is evaluated only while presented, so its agent
/// lookup stays lazy.
private struct SidebarHoverCardModifier<Card: View>: ViewModifier {
    private static var showDelay: UInt64 { 400_000_000 }
    private static var dismissDelay: UInt64 { 250_000_000 }

    var onHoverChange: ((Bool) -> Void)? = nil
    /// Evaluated lazily when the show delay fires; when it returns false the
    /// popover is suppressed (e.g. a row whose card would only repeat the name).
    var shouldShow: () -> Bool = { true }
    @ViewBuilder var card: () -> Card

    @State private var showCard = false
    @State private var showTask: Task<Void, Never>?
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                onHoverChange?(hovering)
                if hovering { scheduleShow() } else { scheduleDismiss() }
            }
            .popover(isPresented: $showCard, arrowEdge: .trailing) {
                card()
                    .onHover { hovering in
                        if hovering { dismissTask?.cancel() } else { scheduleDismiss() }
                    }
            }
    }

    private func scheduleShow() {
        dismissTask?.cancel()
        guard !showCard else { return }
        showTask?.cancel()
        showTask = Task {
            try? await Task.sleep(nanoseconds: Self.showDelay)
            guard !Task.isCancelled, shouldShow() else { return }
            showCard = true
        }
    }

    private func scheduleDismiss() {
        showTask?.cancel()
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: Self.dismissDelay)
            guard !Task.isCancelled else { return }
            showCard = false
        }
    }
}

extension View {
    func sidebarHoverCard(
        onHoverChange: ((Bool) -> Void)? = nil,
        shouldShow: @escaping () -> Bool = { true },
        @ViewBuilder card: @escaping () -> some View
    ) -> some View {
        modifier(
            SidebarHoverCardModifier(
                onHoverChange: onHoverChange, shouldShow: shouldShow, card: card))
    }
}
