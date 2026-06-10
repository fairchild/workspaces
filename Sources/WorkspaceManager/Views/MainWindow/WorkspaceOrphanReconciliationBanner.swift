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
    let onClean: (WorkspaceOrphanItem) -> Void
    let onDismiss: () -> Void

    @State private var isExpanded = false

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
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("workspace-orphan-reconciliation.banner")
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
            .disabled(cleaningItemIDs.contains(item.id))
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
