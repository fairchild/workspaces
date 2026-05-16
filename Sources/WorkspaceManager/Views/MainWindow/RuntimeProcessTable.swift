//
//  RuntimeProcessTable.swift
//  WorkspaceManager
//
//  Sortable process table used by the Diagnostics Detail Pane tab.
//

import SwiftUI
import WorkspaceManagerCore

enum RuntimeProcessTableColumn: CaseIterable {
    case name
    case cpu
    case memory
    case pid
    case command

    var title: String {
        switch self {
        case .name: return "Name"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .pid: return "PID"
        case .command: return "Command"
        }
    }
}

enum RuntimeProcessSortDirection {
    case ascending
    case descending
}

struct RuntimeProcessTableSortState: Equatable {
    var column: RuntimeProcessTableColumn?
    var direction: RuntimeProcessSortDirection?

    mutating func cycle(column nextColumn: RuntimeProcessTableColumn) {
        if column != nextColumn {
            column = nextColumn
            direction = .ascending
            return
        }

        switch direction {
        case .ascending:
            direction = .descending
        case .descending:
            column = nil
            direction = nil
        case nil:
            direction = .ascending
        }
    }

    func sorted(_ rows: [RuntimeProcessSample]) -> [RuntimeProcessSample] {
        guard let column, let direction else { return rows }

        return rows.enumerated().sorted { lhs, rhs in
            let comparison = compare(lhs.element, rhs.element, by: column)
            guard comparison != .orderedSame else {
                return lhs.offset < rhs.offset
            }

            switch direction {
            case .ascending:
                return comparison == .orderedAscending
            case .descending:
                return comparison == .orderedDescending
            }
        }
        .map(\.element)
    }

    private func compare(
        _ lhs: RuntimeProcessSample,
        _ rhs: RuntimeProcessSample,
        by column: RuntimeProcessTableColumn
    ) -> ComparisonResult {
        switch column {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .cpu:
            return compare(lhs.cpuPercent, rhs.cpuPercent)
        case .memory:
            return compare(lhs.residentMemoryBytes, rhs.residentMemoryBytes)
        case .pid:
            return compare(lhs.pid, rhs.pid)
        case .command:
            return lhs.command.localizedStandardCompare(rhs.command)
        }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

struct RuntimeProcessTable: View {
    let rows: [RuntimeProcessSample]
    let emptyText: String
    let accessibilityID: String

    @State private var sortState = RuntimeProcessTableSortState()

    private var displayedRows: [RuntimeProcessSample] {
        sortState.sorted(rows)
    }

    private var visibleRows: [RuntimeProcessSample] {
        Array(displayedRows.prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tableHeader

            if rows.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
            } else {
                ForEach(Array(visibleRows.enumerated()), id: \.offset) { index, row in
                    processRow(row)
                    if index < visibleRows.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .accessibilityIdentifier(accessibilityID)
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            sortableHeader(.name, minWidth: 110, alignment: .leading)
            sortableHeader(.cpu, width: 58, alignment: .trailing)
            sortableHeader(.memory, width: 82, alignment: .trailing)
            sortableHeader(.pid, width: 54, alignment: .trailing)
            sortableHeader(.command, minWidth: 160, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func sortableHeader(
        _ column: RuntimeProcessTableColumn,
        minWidth: CGFloat? = nil,
        width: CGFloat? = nil,
        alignment: Alignment
    ) -> some View {
        let header = Button {
            sortState.cycle(column: column)
        } label: {
            HStack(spacing: 3) {
                Text(column.title)
                    .lineLimit(1)
                sortIndicator(for: column)
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
        .buttonStyle(.plain)
        .help("Sort by \(column.title). Click again to reverse; click a third time to restore the default order.")

        if let width {
            header.frame(width: width, alignment: alignment)
        } else {
            header.frame(minWidth: minWidth ?? 0, alignment: alignment)
        }
    }

    @ViewBuilder
    private func sortIndicator(for column: RuntimeProcessTableColumn) -> some View {
        if sortState.column == column {
            Image(systemName: sortState.direction == .ascending ? "chevron.up" : "chevron.down")
                .font(.caption2.weight(.bold))
        } else {
            Image(systemName: "arrow.up.arrow.down")
                .font(.caption2)
                .opacity(0.22)
        }
    }

    private func processRow(_ row: RuntimeProcessSample) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(processColor(row))
                    .frame(width: 7, height: 7)
                Text(row.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .frame(minWidth: 110, alignment: .leading)

            Text(DiagnosticsValueFormatting.percent(row.cpuPercent))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 58, alignment: .trailing)

            Text(DiagnosticsValueFormatting.bytes(row.residentMemoryBytes))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 82, alignment: .trailing)

            Text("\(row.pid)")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)

            Text(row.command)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(minWidth: 160, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    private func processColor(_ row: RuntimeProcessSample) -> Color {
        if isKnownAgent(row) { return .mint }
        if row.parentPID == 1 { return .secondary }
        return .orange
    }

    private func isKnownAgent(_ row: RuntimeProcessSample) -> Bool {
        let haystack = "\(row.name) \(row.command)".lowercased()
        return ["claude", "codex", "aider", "cursor", "opencode", "pi"].contains { haystack.contains($0) }
    }
}
