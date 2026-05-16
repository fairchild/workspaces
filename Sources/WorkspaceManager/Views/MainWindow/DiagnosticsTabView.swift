//
//  DiagnosticsTabView.swift
//  WorkspaceManager
//
//  Live runtime diagnostics for the Detail Pane.
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
                    value: DiagnosticsValueFormatting.percent(viewModel.snapshot?.appTreeTotals.cpuPercent ?? 0)
                )
                DiagnosticsMetricCard(
                    label: "App Tree Memory",
                    value: DiagnosticsValueFormatting.bytes(viewModel.snapshot?.appTreeTotals.residentMemoryBytes ?? 0)
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
                Text("App tree resources over time")
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
                    value: DiagnosticsValueFormatting.percent(viewModel.history.appCPUAverage)
                )
                DiagnosticsMetricCard(
                    label: "App Peak CPU",
                    value: DiagnosticsValueFormatting.percent(viewModel.history.appCPUPeak)
                )
                DiagnosticsMetricCard(
                    label: "App Max Memory",
                    value: DiagnosticsValueFormatting.bytes(viewModel.history.appMemoryPeakBytes)
                )
            }

            RuntimeResourceChart(history: viewModel.history)
                .frame(height: 170)
                .help(
                    "Charts WorkSpaces app tree CPU or memory over the selected range. Hover for sample time, CPU, memory, and process count."
                )
                .accessibilityIdentifier("inspector.diagnostics.resource-chart")
        }
    }

    private var agentProcessesSection: some View {
        DiagnosticsPanel(title: "Workspace & Agent Processes", accessibilityID: "inspector.diagnostics.agent-processes")
        {
            DiagnosticsConceptNote(
                icon: "terminal",
                tint: .mint,
                title: "Workspace scope",
                text:
                    "Rows here are host processes whose current directory is inside the selected Workspace or Repository.",
                helpText:
                    "This is intentionally different from the app tree: it finds commands by Repository or Workspace directory, including agent tools and Terminal Sessions that WorkSpaces did not directly launch."
            )

            MetricsGrid {
                DiagnosticsMetricCard(
                    label: "Scoped Processes",
                    value: "\(viewModel.snapshot?.workspaceTotals.processCount ?? 0)"
                )
                DiagnosticsMetricCard(
                    label: "Scoped CPU",
                    value: DiagnosticsValueFormatting.percent(viewModel.snapshot?.workspaceTotals.cpuPercent ?? 0)
                )
                DiagnosticsMetricCard(
                    label: "Scoped Memory",
                    value: DiagnosticsValueFormatting.bytes(
                        viewModel.snapshot?.workspaceTotals.residentMemoryBytes ?? 0)
                )
                DiagnosticsMetricCard(
                    label: "Agent Runs",
                    value: "\(viewModel.summary.activeAgentSessionCount)"
                )
            }

            RuntimeProcessTable(
                rows: viewModel.snapshot?.workspaceProcesses ?? [],
                emptyText: "No active Repository or Workspace processes found.",
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
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("About Diagnostics")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("Samples local processes while open; trace counts use existing telemetry.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Diagnostics samples the local process list while this tab is open and shows it beside existing trace telemetry for the selected Repository or Workspace."
                    )
                    Text(
                        "Sampling starts when this tab appears, runs every five seconds, and keeps a one-hour in-memory history."
                    )
                    Text("Process samples are not persisted; export uses the existing diagnostic report bundle.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.48), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .help("Open for details about process sampling, existing trace telemetry, and runtime overhead.")
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

private struct AgentSessionStatusList: View {
    let statuses: [AgentSessionStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ACTIVE AGENT RUNS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            if sortedStatuses.isEmpty {
                Text("No active agent runs registered.")
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
