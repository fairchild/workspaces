//
//  DiffReviewView.swift
//  WorkspaceManager
//
//  Native, read-only diff render: turns a parsed `UnifiedDiff` into coloured addition /
//  removal / context rows with old|new line-number gutters. This view stays a pure renderer;
//  the stage / unstage / discard controls live in the presenting `DiffReviewSheet` beside the
//  review, not in the diff body (see #704 Phase 3).
//
//  The view lays out header + all rows in a plain stack; the presenting container provides
//  scrolling (a `ScrollView`), which keeps this renderable under `ImageRenderer` for evidence.
//

import SwiftUI
import WorkspaceManagerCore

struct DiffReviewView: View {
    let diff: UnifiedDiff

    private var rows: [DiffReviewRow] { DiffReviewRowBuilder.rows(from: diff) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        DiffReviewRowView(row: row)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "plusminus.circle")
                .foregroundStyle(.secondary)
            Text(diff.path)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("+\(diff.addedLines)")
                .foregroundStyle(.green)
            Text("-\(diff.removedLines)")
                .foregroundStyle(.red)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No changes to review")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct DiffReviewRowView: View {
    let row: DiffReviewRow

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(row.oldLineNumber)
            gutter(row.newLineNumber)
            Text(marker)
                .frame(width: 14, alignment: .center)
                .foregroundStyle(markerColor)
            Text(row.content.isEmpty ? " " : row.content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
        .foregroundStyle(row.kind == .hunkHeader ? Color.secondary : Color.primary)
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var marker: String {
        switch row.kind {
        case .addition: return "+"
        case .removal: return "-"
        case .context: return " "
        case .hunkHeader: return ""
        }
    }

    private var markerColor: Color {
        switch row.kind {
        case .addition: return .green
        case .removal: return .red
        default: return .secondary
        }
    }

    private var background: Color {
        switch row.kind {
        case .addition: return Color.green.opacity(0.14)
        case .removal: return Color.red.opacity(0.14)
        case .hunkHeader: return Color.secondary.opacity(0.10)
        case .context: return .clear
        }
    }
}
