//
//  DiagnosticsTabView.swift
//  WorkspaceManager
//
//  Live runtime diagnostics for the right inspector.
//

import Foundation
import SwiftUI
import WorkspaceManagerCore

struct DiagnosticsTabView: View {
    let workspaceDirectories: [URL]
    let agentStatuses: [AgentSessionStatus]

    @StateObject private var viewModel = RuntimeDiagnosticsViewModel()
    @State private var selectedRange: RuntimeDiagnosticsRange = .fifteenMinutes
    @State private var isAboutExpanded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                diagnosticsHeader
                DiagnosticsAboutDisclosure(isExpanded: $isAboutExpanded)

                if let errorMessage = viewModel.snapshot?.errorMessage {
                    DiagnosticsInlineError(message: errorMessage)
                }

                liveProcessesSection
                resourceHistorySection
                agentProcessesSection
                traceDiagnosticsSection
                latestFailuresSection
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("inspector.diagnostics.root")
        .onAppear {
            viewModel.start(
                workspaceDirectories: workspaceDirectories,
                agentStatuses: agentStatuses,
                selectedRange: selectedRange
            )
        }
        .onDisappear {
            viewModel.stop()
        }
        .onChange(of: selectedRange) { _, range in
            viewModel.updateContext(
                workspaceDirectories: workspaceDirectories,
                agentStatuses: agentStatuses,
                selectedRange: range
            )
        }
        .onChange(of: workspaceDirectories) { _, directories in
            viewModel.updateContext(
                workspaceDirectories: directories,
                agentStatuses: agentStatuses,
                selectedRange: selectedRange
            )
        }
        .onChange(of: agentStatuses) { _, statuses in
            viewModel.updateContext(
                workspaceDirectories: workspaceDirectories,
                agentStatuses: statuses,
                selectedRange: selectedRange
            )
        }
    }

    private var diagnosticsHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Diagnostics")
                    .font(.headline)
                Text(checkedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await DiagnosticReportExporter.exportWithSavePanel()
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help(
                "Export Diagnostic Report: save a zip with app diagnostics, system profile, recent logs, and startup telemetry."
            )
            .accessibilityLabel("Export Diagnostic Report")
            .accessibilityIdentifier("inspector.diagnostics.export")

            Button {
                viewModel.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isRefreshing)
            .help("Refresh Diagnostics")
            .accessibilityIdentifier("inspector.diagnostics.refresh")
        }
    }

    private var liveProcessesSection: some View {
        DiagnosticsPanel(title: "WorkSpaces App Tree", accessibilityID: "inspector.diagnostics.app-processes") {
            DiagnosticsConceptNote(
                icon: "scope",
                tint: .orange,
                title: "Headline process",
                text: "The root is this running WorkSpaces app; child rows are processes it launched.",
                helpText:
                    "This separates WorkSpaces runtime overhead from commands that happen inside workspace directories."
            )

            MetricsGrid {
                DiagnosticsMetricCard(
                    label: "Descendants",
                    value: "\(max((viewModel.snapshot?.appTreeTotals.processCount ?? 0) - 1, 0))"
                )
                DiagnosticsMetricCard(
                    label: "App Tree CPU",
                    value: percentString(viewModel.snapshot?.appTreeTotals.cpuPercent ?? 0)
                )
                DiagnosticsMetricCard(
                    label: "App Tree Memory",
                    value: byteString(viewModel.snapshot?.appTreeTotals.residentMemoryBytes ?? 0)
                )
                DiagnosticsMetricCard(
                    label: "WorkSpaces PID",
                    value: "\(viewModel.snapshot?.appPID ?? 0)"
                )
            }

            RuntimeProcessTable(
                rows: viewModel.snapshot?.appTreeProcesses ?? [],
                emptyText: "No live descendant processes found.",
                accessibilityID: "inspector.diagnostics.app-process-table"
            )
        }
    }

    private var resourceHistorySection: some View {
        DiagnosticsPanel(title: "Resource History", accessibilityID: "inspector.diagnostics.resource-history") {
            HStack(alignment: .firstTextBaseline) {
                Text("App tree CPU over time")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Picker("History Range", selection: $selectedRange) {
                    ForEach(RuntimeDiagnosticsRange.allCases) { range in
                        Text(range.rawValue)
                            .tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)

                Text(sampleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("inspector.diagnostics.range")

            MetricsGrid {
                DiagnosticsMetricCard(
                    label: "Samples",
                    value: "\(viewModel.history.sampleCount)"
                )
                DiagnosticsMetricCard(
                    label: "App Avg CPU",
                    value: percentString(viewModel.history.appCPUAverage)
                )
                DiagnosticsMetricCard(
                    label: "App Peak CPU",
                    value: percentString(viewModel.history.appCPUPeak)
                )
                DiagnosticsMetricCard(
                    label: "App Max Memory",
                    value: byteString(viewModel.history.appMemoryPeakBytes)
                )
            }

            RuntimeResourceChart(history: viewModel.history)
                .frame(height: 170)
                .help(
                    "Charts WorkSpaces app tree CPU percentage over the selected range. Hover for sample time, CPU, memory, and process count."
                )
                .accessibilityIdentifier("inspector.diagnostics.resource-chart")
        }
    }

    private var agentProcessesSection: some View {
        DiagnosticsPanel(title: "Workspace / Agent Processes", accessibilityID: "inspector.diagnostics.agent-processes")
        {
            DiagnosticsConceptNote(
                icon: "terminal",
                tint: .mint,
                title: "Workspace scope",
                text: "Rows here are host processes whose current directory is inside the selected workspace or repo.",
                helpText:
                    "This is intentionally different from the app tree: it finds commands by workspace directory, including agent tools and terminals that WorkSpaces did not directly launch."
            )

            MetricsGrid {
                DiagnosticsMetricCard(
                    label: "Workspace Processes",
                    value: "\(viewModel.snapshot?.workspaceTotals.processCount ?? 0)"
                )
                DiagnosticsMetricCard(
                    label: "Workspace CPU",
                    value: percentString(viewModel.snapshot?.workspaceTotals.cpuPercent ?? 0)
                )
                DiagnosticsMetricCard(
                    label: "Workspace Memory",
                    value: byteString(viewModel.snapshot?.workspaceTotals.residentMemoryBytes ?? 0)
                )
                DiagnosticsMetricCard(
                    label: "Agent Sessions",
                    value: "\(viewModel.summary.activeAgentSessionCount)"
                )
            }

            RuntimeProcessTable(
                rows: viewModel.snapshot?.workspaceProcesses ?? [],
                emptyText: "No active workspace processes found.",
                accessibilityID: "inspector.diagnostics.agent-process-table"
            )

            AgentSessionStatusList(statuses: agentStatuses)
                .accessibilityIdentifier("inspector.diagnostics.agent-sessions")
        }
    }

    private var traceDiagnosticsSection: some View {
        DiagnosticsPanel(title: "Trace Diagnostics", accessibilityID: "inspector.diagnostics.trace-summary") {
            MetricsGrid {
                DiagnosticsMetricCard(label: "Spans", value: "\(viewModel.summary.spanCount)")
                DiagnosticsMetricCard(
                    label: "Failures",
                    value: "\(viewModel.summary.failureCount)",
                    prominence: viewModel.summary.failureCount > 0 ? .critical : .normal
                )
                DiagnosticsMetricCard(
                    label: "Slow Spans",
                    value: "\(viewModel.summary.slowSpanCount)",
                    prominence: viewModel.summary.slowSpanCount > 0 ? .warning : .normal
                )
                DiagnosticsMetricCard(label: "Parse Errors", value: "\(viewModel.summary.parseErrorCount)")
            }
        }
    }

    @ViewBuilder
    private var latestFailuresSection: some View {
        DiagnosticsPanel(title: "Latest Failures", accessibilityID: "inspector.diagnostics.latest-failures") {
            if viewModel.summary.latestFailures.isEmpty {
                Text("No recent diagnostic failures.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.summary.latestFailures) { failure in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(failure.title)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text(failure.timestamp.formatted(.relative(presentation: .named)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(failure.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 8)

                        if failure.id != viewModel.summary.latestFailures.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var checkedText: String {
        guard let lastCheckedAt = viewModel.lastCheckedAt else { return "Waiting for first sample" }
        return "Checked \(lastCheckedAt.formatted(.relative(presentation: .named)))"
    }

    private var sampleText: String {
        let count = viewModel.history.sampleCount
        return count == 1 ? "1 sample" : "\(count) samples"
    }
}

private struct DiagnosticsAboutDisclosure: View {
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Sampling starts when this tab appears, runs every five seconds, and keeps a one-hour in-memory history."
                )
                Text("Process samples are not persisted; export uses the existing diagnostic report bundle.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        } label: {
            Label("Samples local process and trace telemetry while this tab is open.", systemImage: "info.circle")
                .font(.callout.weight(.medium))
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
        .help("Open for details about what Diagnostics samples and whether the tab adds runtime overhead.")
        .accessibilityIdentifier("inspector.diagnostics.about")
    }
}

private struct DiagnosticsPanel<Content: View>: View {
    let title: String
    let accessibilityID: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 14, height: 1)
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.78))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: 8))
        }
        .accessibilityIdentifier(accessibilityID)
    }
}

private struct DiagnosticsConceptNote: View {
    let icon: String
    let tint: Color
    let title: String
    let text: String
    let helpText: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(tint)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 7))
        .help(helpText)
    }
}

private struct MetricsGrid<Content: View>: View {
    @ViewBuilder let content: Content

    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 0)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            content
        }
    }
}

private enum DiagnosticsMetricProminence {
    case normal
    case warning
    case critical
}

private struct DiagnosticsMetricCard: View {
    let label: String
    let value: String
    var prominence: DiagnosticsMetricProminence = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .semibold))
                .foregroundStyle(valueStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.10))
                .frame(width: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.10))
                .frame(height: 1)
        }
    }

    private var valueStyle: Color {
        switch prominence {
        case .normal:
            return .primary
        case .warning:
            return .yellow
        case .critical:
            return .red
        }
    }
}

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

private struct RuntimeProcessTable: View {
    let rows: [RuntimeProcessSample]
    let emptyText: String
    let accessibilityID: String

    @State private var sortState = RuntimeProcessTableSortState()

    private var displayedRows: [RuntimeProcessSample] {
        sortState.sorted(rows)
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
                ForEach(displayedRows.prefix(10)) { row in
                    processRow(row)
                    if row.pid != displayedRows.prefix(10).last?.pid {
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

            Text(percentString(row.cpuPercent))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 58, alignment: .trailing)

            Text(byteString(row.residentMemoryBytes))
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

private struct RuntimeResourceChart: View {
    let history: RuntimeProcessHistory

    @State private var hoveredIndex: Int?

    private var hoveredSnapshot: RuntimeDiagnosticsSnapshot? {
        guard let hoveredIndex, history.snapshots.indices.contains(hoveredIndex) else {
            return nil
        }
        return history.snapshots[hoveredIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("WorkSpaces app tree CPU", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(hoveredSnapshot.map(sampleDescription) ?? "Hover for sample details")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            GeometryReader { proxy in
                let snapshots = history.snapshots
                let maxCPU = max(history.appCPUPeak, 1)
                ZStack(alignment: .topTrailing) {
                    HStack(alignment: .bottom, spacing: 3) {
                        if snapshots.isEmpty {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.15))
                                .frame(height: 2)
                        } else {
                            ForEach(Array(snapshots.enumerated()), id: \.element.sampledAt) { index, snapshot in
                                let heightRatio = min(max(snapshot.appTreeTotals.cpuPercent / maxCPU, 0), 1)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(
                                        chartColor(
                                            for: snapshot.appTreeTotals.cpuPercent, isHovered: index == hoveredIndex)
                                    )
                                    .frame(
                                        width: barWidth(totalWidth: proxy.size.width, count: snapshots.count),
                                        height: max(2, proxy.size.height * heightRatio)
                                    )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.30))
                            .frame(height: 1)
                    }

                    if let hoveredSnapshot {
                        chartCallout(hoveredSnapshot)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        hoveredIndex = hoveredIndex(
                            for: location.x,
                            width: proxy.size.width,
                            count: snapshots.count
                        )
                    case .ended:
                        hoveredIndex = nil
                    }
                }
            }
        }
    }

    private func chartCallout(_ snapshot: RuntimeDiagnosticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.sampledAt.formatted(date: .omitted, time: .standard))
                .font(.caption.weight(.semibold))
            Text("CPU \(percentString(snapshot.appTreeTotals.cpuPercent))")
            Text("Memory \(byteString(snapshot.appTreeTotals.residentMemoryBytes))")
            Text("\(snapshot.appTreeTotals.processCount) processes")
        }
        .font(.caption2.monospacedDigit())
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92), in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        }
    }

    private func barWidth(totalWidth: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return totalWidth }
        return max(3, min(18, (totalWidth / CGFloat(count)) - 3))
    }

    private func chartColor(for cpu: Double, isHovered: Bool) -> Color {
        let opacity = isHovered ? 1.0 : 0.78
        if cpu >= 80 { return .red.opacity(opacity) }
        if cpu >= 40 { return .yellow.opacity(opacity) }
        return .secondary.opacity(opacity)
    }

    private func hoveredIndex(for x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0, width > 0 else { return nil }
        let clampedX = min(max(x, 0), width)
        let rawIndex = Int((clampedX / width) * CGFloat(count))
        return min(max(rawIndex, 0), count - 1)
    }

    private func sampleDescription(_ snapshot: RuntimeDiagnosticsSnapshot) -> String {
        "\(snapshot.sampledAt.formatted(date: .omitted, time: .shortened))  CPU \(percentString(snapshot.appTreeTotals.cpuPercent))  Mem \(byteString(snapshot.appTreeTotals.residentMemoryBytes))"
    }
}

private struct AgentSessionStatusList: View {
    let statuses: [AgentSessionStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ACTIVE AGENT SESSIONS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            if sortedStatuses.isEmpty {
                Text("No active agent sessions registered.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(sortedStatuses, id: \.hostSessionID) { status in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(color(for: status.run))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sessionTitle(status))
                                .font(.callout.weight(.medium))
                            Text(status.cwd)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(status.lastEventAt.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }

    private var sortedStatuses: [AgentSessionStatus] {
        statuses.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    private func sessionTitle(_ status: AgentSessionStatus) -> String {
        let model = status.modelDisplayName ?? status.kind.rawValue
        return "\(model) - \(runStateLabel(status.run))"
    }

    private func runStateLabel(_ state: AgentRunState) -> String {
        switch state {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .runningTool(let name, _): return "Running \(name)"
        case .awaitingInput(let reason): return "Awaiting \(reason.rawValue)"
        case .complete: return "Complete"
        case .errored(let category, _): return "Errored: \(category.rawValue)"
        }
    }

    private func color(for state: AgentRunState) -> Color {
        switch state {
        case .idle, .complete:
            return .secondary
        case .thinking, .runningTool:
            return .blue
        case .awaitingInput:
            return .yellow
        case .errored:
            return .red
        }
    }
}

private struct DiagnosticsInlineError: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.caption)
                .lineLimit(2)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.orange)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("inspector.diagnostics.error")
    }
}

private func percentString(_ value: Double) -> String {
    String(format: "%.1f%%", value)
}

private func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
}
