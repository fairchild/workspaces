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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                diagnosticsHeader

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
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Export Diagnostic Report")
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
        DiagnosticsPanel(title: "Live Processes", accessibilityID: "inspector.diagnostics.app-processes") {
            MetricsGrid {
                DiagnosticsMetricCard(
                    label: "Child Processes",
                    value: "\(max((viewModel.snapshot?.appTreeTotals.processCount ?? 0) - 1, 0))"
                )
                DiagnosticsMetricCard(
                    label: "CPU",
                    value: percentString(viewModel.snapshot?.appTreeTotals.cpuPercent ?? 0)
                )
                DiagnosticsMetricCard(
                    label: "Memory",
                    value: byteString(viewModel.snapshot?.appTreeTotals.residentMemoryBytes ?? 0)
                )
                DiagnosticsMetricCard(
                    label: "App PID",
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
                Picker("History Range", selection: $selectedRange) {
                    ForEach(RuntimeDiagnosticsRange.allCases) { range in
                        Text(range.rawValue)
                            .tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)

                Spacer()

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
                    label: "Avg CPU",
                    value: percentString(viewModel.history.appCPUAverage)
                )
                DiagnosticsMetricCard(
                    label: "Peak CPU",
                    value: percentString(viewModel.history.appCPUPeak)
                )
                DiagnosticsMetricCard(
                    label: "Max Memory",
                    value: byteString(viewModel.history.appMemoryPeakBytes)
                )
            }

            RuntimeResourceChart(history: viewModel.history)
                .frame(height: 130)
                .accessibilityIdentifier("inspector.diagnostics.resource-chart")
        }
    }

    private var agentProcessesSection: some View {
        DiagnosticsPanel(title: "Agent / Workspace Processes", accessibilityID: "inspector.diagnostics.agent-processes")
        {
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

private struct RuntimeProcessTable: View {
    let rows: [RuntimeProcessSample]
    let emptyText: String
    let accessibilityID: String

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
                ForEach(rows.prefix(10)) { row in
                    processRow(row)
                    if row.pid != rows.prefix(10).last?.pid {
                        Divider()
                    }
                }
            }
        }
        .accessibilityIdentifier(accessibilityID)
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("Name")
                .frame(minWidth: 110, alignment: .leading)
            Text("CPU")
                .frame(width: 58, alignment: .trailing)
            Text("Memory")
                .frame(width: 82, alignment: .trailing)
            Text("PID")
                .frame(width: 54, alignment: .trailing)
            Text("Command")
                .frame(minWidth: 160, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.bottom, 8)
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

    var body: some View {
        GeometryReader { proxy in
            let snapshots = history.snapshots
            let maxCPU = max(history.appCPUPeak, 1)
            HStack(alignment: .bottom, spacing: 3) {
                if snapshots.isEmpty {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 2)
                } else {
                    ForEach(Array(snapshots.enumerated()), id: \.element.sampledAt) { _, snapshot in
                        let heightRatio = min(max(snapshot.appTreeTotals.cpuPercent / maxCPU, 0), 1)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(chartColor(for: snapshot.appTreeTotals.cpuPercent))
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
        }
    }

    private func barWidth(totalWidth: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return totalWidth }
        return max(3, min(18, (totalWidth / CGFloat(count)) - 3))
    }

    private func chartColor(for cpu: Double) -> Color {
        if cpu >= 80 { return .red.opacity(0.85) }
        if cpu >= 40 { return .yellow.opacity(0.85) }
        return .secondary.opacity(0.75)
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
