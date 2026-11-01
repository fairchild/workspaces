//
//  WorkspaceOrphanReconciliationBanner.swift
//  WorkspaceManager
//
//  Quiet main-window affordance for confirmed cleanup of workspace resources
//  that no longer match persisted workspace records.
//

import SwiftUI
import WorkspaceManagerCore

struct WorkspaceOrphanReconciliationBanner: View {
    let items: [WorkspaceOrphanItem]
    let cleaningItemIDs: Set<String>
    let adoptingItemIDs: Set<String>
    /// Whether this item can be adopted rather than only cleaned (#1390) — a decision, not a
    /// property of the item alone, so the banner does not duplicate the controller's rule for
    /// which orphan kinds are live enough to adopt.
    let canAdopt: (WorkspaceOrphanItem) -> Bool
    let onClean: (WorkspaceOrphanItem) -> Void
    let onAdopt: (WorkspaceOrphanItem) -> Void
    let onDismiss: () -> Void

    /// Starting disclosure state. Defaults closed, matching every existing call site; a render
    /// test forces it open to capture the row-level rendering (the Adopt/Clean buttons) that a
    /// collapsed banner never shows.
    var initiallyExpanded = false

    @State private var isExpanded: Bool
    /// Natural height of the expanded rows, measured inside the scroll view; nil until the
    /// first layout reports it.
    @State private var measuredRowsHeight: CGFloat?

    init(
        items: [WorkspaceOrphanItem],
        cleaningItemIDs: Set<String>,
        adoptingItemIDs: Set<String>,
        canAdopt: @escaping (WorkspaceOrphanItem) -> Bool,
        onClean: @escaping (WorkspaceOrphanItem) -> Void,
        onAdopt: @escaping (WorkspaceOrphanItem) -> Void,
        onDismiss: @escaping () -> Void,
        initiallyExpanded: Bool = false
    ) {
        self.items = items
        self.cleaningItemIDs = cleaningItemIDs
        self.adoptingItemIDs = adoptingItemIDs
        self.canAdopt = canAdopt
        self.onClean = onClean
        self.onAdopt = onAdopt
        self.onDismiss = onDismiss
        self.initiallyExpanded = initiallyExpanded
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide Cleanup Items" : "Show Cleanup Items")

                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Workspace cleanup available")
                        .font(.callout.weight(.semibold))
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded = true
                    }
                } label: {
                    Label("Review", systemImage: "list.bullet")
                }
                .buttonStyle(.bordered)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Dismiss Workspace Cleanup")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if isExpanded {
                Divider()
                // A long leftover list (a dozen stale worktrees is common) must not outgrow the
                // window, or it pushes this banner's header (chevron, dismiss) under the title
                // bar. A fixed-height frame, sized to the measured rows up to the cap, bounds it
                // whatever the parent proposes; `.frame(maxHeight:)` would pass an ideal-size
                // (nil) proposal straight through and let the full list render.
                ScrollView(.vertical) {
                    cleanupRows
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: CleanupRowsHeightKey.self, value: proxy.size.height)
                            }
                        )
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: expandedListHeight)
                .onPreferenceChange(CleanupRowsHeightKey.self) { measuredRowsHeight = $0 }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("workspace-orphan-reconciliation.banner")
    }

    /// Tallest the expanded list may grow before it scrolls — about six rows, leaving the
    /// terminal visible beneath the banner even in a short window.
    static let expandedListMaxHeight: CGFloat = 260

    private var expandedListHeight: CGFloat {
        min(measuredRowsHeight ?? Self.expandedListMaxHeight, Self.expandedListMaxHeight)
    }

    private var cleanupRows: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                cleanupRow(for: item)
                if item.id != items.last?.id {
                    Divider()
                        .padding(.leading, 42)
                }
            }
        }
    }

    private var summaryText: String {
        let count = items.count
        return "\(count) leftover \(count == 1 ? "item" : "items") found. Nothing will be deleted without confirmation."
    }

    private func cleanupRow(for item: WorkspaceOrphanItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: item.kind))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle(for: item))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let detail = rowDetail(for: item) {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if canAdopt(item) {
                Button {
                    onAdopt(item)
                } label: {
                    if adoptingItemIDs.contains(item.id) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Adopt", systemImage: "plus.circle")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(adoptingItemIDs.contains(item.id) || cleaningItemIDs.contains(item.id))
                .help("Add '\(item.resourceName)' as a workspace instead of removing it")
            }

            Button {
                onClean(item)
            } label: {
                if cleaningItemIDs.contains(item.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Clean", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
            .disabled(cleaningItemIDs.contains(item.id) || adoptingItemIDs.contains(item.id))
            .help("Clean \(item.resourceName)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityIdentifier("workspace-orphan-reconciliation.item.\(item.id)")
    }

    private func iconName(for kind: WorkspaceOrphanKind) -> String {
        switch kind {
        case .gitWorktreeWithoutRecord:
            return "arrow.triangle.branch"
        case .workspaceRecordMissingDirectory:
            return "folder.badge.questionmark"
        case .lumeVMWithoutWorkspace:
            return "desktopcomputer"
        }
    }

    private func rowTitle(for item: WorkspaceOrphanItem) -> String {
        switch item.kind {
        case .gitWorktreeWithoutRecord:
            return "\(item.resourceName) has no workspace record"
        case .workspaceRecordMissingDirectory:
            return "\(item.resourceName) is missing its directory"
        case .lumeVMWithoutWorkspace:
            return "\(item.resourceName) has no workspace"
        }
    }

    private func rowDetail(for item: WorkspaceOrphanItem) -> String? {
        switch item.kind {
        case .gitWorktreeWithoutRecord, .workspaceRecordMissingDirectory:
            return item.path
        case .lumeVMWithoutWorkspace:
            return item.storagePath
        }
    }
}

/// Carries the expanded rows' natural height out of the scroll view so the banner can size the
/// list to its content until it reaches the cap.
private struct CleanupRowsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
