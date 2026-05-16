//
//  RuntimeResourceChart.swift
//  WorkspaceManager
//
//  CPU and memory history chart for the Diagnostics Detail Pane tab.
//

import SwiftUI
import WorkspaceManagerCore

private enum RuntimeResourceChartMetric: String, CaseIterable, Identifiable {
    case cpu
    case memory

    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: "WorkSpaces app tree CPU"
        case .memory: "WorkSpaces app tree Memory"
        }
    }

    var optionTitle: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        }
    }

    var systemImage: String {
        switch self {
        case .cpu: "waveform.path.ecg"
        case .memory: "memorychip"
        }
    }

    var next: RuntimeResourceChartMetric {
        switch self {
        case .cpu: .memory
        case .memory: .cpu
        }
    }

    func value(in snapshot: RuntimeDiagnosticsSnapshot) -> Double {
        switch self {
        case .cpu:
            snapshot.appTreeTotals.cpuPercent
        case .memory:
            Double(snapshot.appTreeTotals.residentMemoryBytes)
        }
    }

    func peak(in history: RuntimeProcessHistory) -> Double {
        switch self {
        case .cpu:
            max(history.appCPUPeak, 1)
        case .memory:
            max(Double(history.appMemoryPeakBytes), 1)
        }
    }

    func formattedValue(in snapshot: RuntimeDiagnosticsSnapshot) -> String {
        switch self {
        case .cpu:
            DiagnosticsValueFormatting.percent(snapshot.appTreeTotals.cpuPercent)
        case .memory:
            DiagnosticsValueFormatting.bytes(snapshot.appTreeTotals.residentMemoryBytes)
        }
    }

    func chartColor(for value: Double, isHovered: Bool) -> Color {
        let opacity = isHovered ? 1.0 : 0.78
        switch self {
        case .cpu:
            if value >= 80 { return .red.opacity(opacity) }
            if value >= 40 { return .yellow.opacity(opacity) }
            return .secondary.opacity(opacity)
        case .memory:
            return .teal.opacity(opacity)
        }
    }
}

struct RuntimeResourceChart: View {
    let history: RuntimeProcessHistory

    @State private var hoveredIndex: Int?
    @State private var selectedMetric: RuntimeResourceChartMetric = .cpu
    @State private var isMetricSelectorHovered = false
    @State private var isMetricDropdownVisible = false
    @State private var metricHoverGeneration = 0

    private var hoveredSnapshot: RuntimeDiagnosticsSnapshot? {
        guard let hoveredIndex, history.snapshots.indices.contains(hoveredIndex) else {
            return nil
        }
        return history.snapshots[hoveredIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                chartMetricSelector

                Spacer()

                Text(hoveredSnapshot.map(sampleDescription) ?? "Hover for sample details")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            GeometryReader { proxy in
                let snapshots = history.snapshots
                let peakValue = selectedMetric.peak(in: history)
                ZStack(alignment: .topTrailing) {
                    HStack(alignment: .bottom, spacing: 3) {
                        if snapshots.isEmpty {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.15))
                                .frame(height: 2)
                        } else {
                            ForEach(Array(snapshots.enumerated()), id: \.element.sampledAt) { index, snapshot in
                                let value = selectedMetric.value(in: snapshot)
                                let heightRatio = min(max(value / peakValue, 0), 1)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(
                                        selectedMetric.chartColor(
                                            for: value,
                                            isHovered: index == hoveredIndex
                                        )
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

    private var chartMetricSelector: some View {
        Button {
            selectedMetric = selectedMetric.next
            showMetricDropdown()
        } label: {
            Label(selectedMetric.title, systemImage: selectedMetric.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                updateMetricSelectorHover(true)
            case .ended:
                updateMetricSelectorHover(false)
            }
        }
        .help("Click to switch between CPU and memory. Hover to choose a metric.")
        .accessibilityIdentifier("inspector.diagnostics.resource-chart.metric-selector")
        .overlay(alignment: .topLeading) {
            if isMetricDropdownVisible {
                metricDropdown
                    .offset(y: 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.14), value: isMetricDropdownVisible)
        .animation(.snappy(duration: 0.14), value: selectedMetric)
    }

    private var metricDropdown: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(RuntimeResourceChartMetric.allCases) { metric in
                Button {
                    selectedMetric = metric
                    showMetricDropdown()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: metric.systemImage)
                            .font(.caption2)
                            .frame(width: 12)
                        Text(metric.optionTitle)
                            .font(.caption.weight(.medium))
                        if metric == selectedMetric {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(metric == selectedMetric ? .primary : .secondary)
                    .frame(minWidth: 92, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.97), in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                updateMetricSelectorHover(true)
            case .ended:
                updateMetricSelectorHover(false)
            }
        }
        .accessibilityIdentifier("inspector.diagnostics.resource-chart.metric-menu")
    }

    private func chartCallout(_ snapshot: RuntimeDiagnosticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.sampledAt.formatted(date: .omitted, time: .standard))
                .font(.caption.weight(.semibold))
            Text("\(selectedMetric.optionTitle) \(selectedMetric.formattedValue(in: snapshot))")
                .font(.caption2.weight(.semibold).monospacedDigit())
            if selectedMetric != .cpu {
                Text("CPU \(DiagnosticsValueFormatting.percent(snapshot.appTreeTotals.cpuPercent))")
            }
            if selectedMetric != .memory {
                Text("Memory \(DiagnosticsValueFormatting.bytes(snapshot.appTreeTotals.residentMemoryBytes))")
            }
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

    private func hoveredIndex(for x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0, width > 0 else { return nil }
        let clampedX = min(max(x, 0), width)
        let rawIndex = Int((clampedX / width) * CGFloat(count))
        return min(max(rawIndex, 0), count - 1)
    }

    private func sampleDescription(_ snapshot: RuntimeDiagnosticsSnapshot) -> String {
        "\(snapshot.sampledAt.formatted(date: .omitted, time: .shortened))  \(selectedMetric.optionTitle) \(selectedMetric.formattedValue(in: snapshot))"
    }

    private func showMetricDropdown() {
        metricHoverGeneration += 1
        isMetricDropdownVisible = true
    }

    private func updateMetricSelectorHover(_ isHovered: Bool) {
        metricHoverGeneration += 1
        let generation = metricHoverGeneration
        isMetricSelectorHovered = isHovered

        if isHovered {
            isMetricDropdownVisible = true
        } else {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(240))
                guard generation == metricHoverGeneration, !isMetricSelectorHovered else { return }
                isMetricDropdownVisible = false
            }
        }
    }
}
