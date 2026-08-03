import Foundation
import WorkspaceManagerCore
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "TerminalReadinessDiagnostics")

final class TerminalReadinessDiagnostics {
    enum Signal: String {
        case setTitle = "set_title"
        case pwd

        var indicatesPromptReady: Bool {
            switch self {
            case .setTitle, .pwd:
                return true
            }
        }
    }

    typealias InvestigationEmitter = (_ phase: String, _ fields: [String: String]) -> Void
    typealias MetricEmitter = (_ metric: String, _ durationMs: Double, _ labels: [String: String]) -> Void
    typealias Clock = () -> Date

    private let workingDirectoryName: String
    private let shellProfileMode: String
    private let emitInvestigation: InvestigationEmitter
    private let emitMetric: MetricEmitter
    private let now: Clock

    private var surfaceCreateStartedAt: Date?
    private var didEmitFirstOutput = false
    private var didEmitPromptReady = false

    init(
        workingDirectoryName: String,
        shellProfileMode: String,
        emitInvestigation: @escaping InvestigationEmitter = InvestigationDiagnostics.emitTerminal,
        emitMetric: @escaping MetricEmitter = TerminalReadinessDiagnostics.defaultEmitMetric,
        now: @escaping Clock = Date.init
    ) {
        self.workingDirectoryName = workingDirectoryName
        self.shellProfileMode = shellProfileMode
        self.emitInvestigation = emitInvestigation
        self.emitMetric = emitMetric
        self.now = now
    }

    func markSurfaceCreateStarted() {
        surfaceCreateStartedAt = now()
        didEmitFirstOutput = false
        didEmitPromptReady = false
        emitInvestigation(
            "surface_create_started",
            [
                "shell_profile_mode": shellProfileMode,
                "working_directory": workingDirectoryName,
            ]
        )
    }

    func markSurfaceCreateFailed(reason: String) {
        emitInvestigation(
            "surface_create_failed",
            [
                "duration_ms": formattedDurationSinceStart(),
                "reason": reason,
                "shell_profile_mode": shellProfileMode,
            ]
        )
    }

    func markSurfaceCreateSucceeded() {
        emitInvestigation(
            "surface_create_succeeded",
            [
                "duration_ms": formattedDurationSinceStart(),
                "shell_profile_mode": shellProfileMode,
                "working_directory": workingDirectoryName,
            ]
        )
    }

    func observeShellSignal(_ signal: Signal) {
        let durationMs = durationSinceStart()
        let fields = [
            "shell_profile_mode": shellProfileMode,
            "signal": signal.rawValue,
            "working_directory": workingDirectoryName,
        ]

        if !didEmitFirstOutput {
            didEmitFirstOutput = true
            emitMetric("terminal_first_output", durationMs, fields)
            emitInvestigation(
                "first_output_observed",
                fields.merging(["duration_ms": String(format: "%.2f", durationMs)]) { _, new in new }
            )
        }

        guard signal.indicatesPromptReady, !didEmitPromptReady else { return }
        didEmitPromptReady = true
        emitMetric("first_prompt_ready", durationMs, fields)
        emitInvestigation(
            "prompt_ready_observed",
            fields.merging(["duration_ms": String(format: "%.2f", durationMs)]) { _, new in new }
        )
    }

    private func durationSinceStart() -> Double {
        guard let surfaceCreateStartedAt else { return 0 }
        return max(0, now().timeIntervalSince(surfaceCreateStartedAt) * 1000)
    }

    private func formattedDurationSinceStart() -> String {
        String(format: "%.2f", durationSinceStart())
    }

    private static func defaultEmitMetric(metric: String, durationMs: Double, labels: [String: String]) {
        var components = [
            "[Perf]",
            "metric=\(sanitize(metric))",
            "duration_ms=\(String(format: "%.2f", durationMs))",
        ]

        for key in labels.keys.sorted() {
            guard let value = labels[key] else { continue }
            components.append("\(sanitize(key))=\(sanitize(value))")
        }

        log.info("\(components.joined(separator: " "), privacy: .public)")

        Task.detached {
            await StartupDiagnosticsStore.shared.record(
                metric: metric,
                durationMs: durationMs,
                labels: labels
            )
        }
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\t", with: "_")
    }
}
