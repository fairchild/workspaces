import Foundation
import Testing

@testable import WorkspaceManager

@Suite("TerminalReadinessDiagnostics")
struct TerminalReadinessDiagnosticsTests {
    @Test("first shell signal records both first output and prompt ready")
    func firstShellSignalRecordsOutputAndPromptReady() {
        final class ClockBox {
            var now: Date

            init(now: Date) {
                self.now = now
            }
        }

        struct MetricRecord: Equatable {
            let metric: String
            let durationMs: Double
            let labels: [String: String]
        }

        let clock = ClockBox(now: Date(timeIntervalSinceReferenceDate: 700_000_000))
        var investigationEvents: [(String, [String: String])] = []
        var metricEvents: [MetricRecord] = []

        let diagnostics = TerminalReadinessDiagnostics(
            workingDirectoryName: "repo-a",
            shellProfileMode: "clean",
            emitInvestigation: { phase, fields in
                investigationEvents.append((phase, fields))
            },
            emitMetric: { metric, durationMs, labels in
                metricEvents.append(MetricRecord(metric: metric, durationMs: durationMs, labels: labels))
            },
            now: { clock.now }
        )

        diagnostics.markSurfaceCreateStarted()
        clock.now = clock.now.addingTimeInterval(0.150)
        diagnostics.observeShellSignal(.pwd)

        #expect(metricEvents.count == 2)
        #expect(metricEvents[0].metric == "terminal_first_output")
        #expect(metricEvents[1].metric == "first_prompt_ready")
        #expect(abs(metricEvents[0].durationMs - 150.0) < 0.001)
        #expect(metricEvents[0].labels["signal"] == "pwd")
        #expect(metricEvents[1].labels["shell_profile_mode"] == "clean")
        #expect(
            investigationEvents.map { $0.0 } == [
                "surface_create_started",
                "first_output_observed",
                "prompt_ready_observed",
            ]
        )
    }

    @Test("repeated shell signals do not duplicate readiness metrics")
    func repeatedSignalsDoNotDuplicateMetrics() {
        final class ClockBox {
            var now: Date

            init(now: Date) {
                self.now = now
            }
        }

        let clock = ClockBox(now: Date(timeIntervalSinceReferenceDate: 700_000_100))
        var metricNames: [String] = []

        let diagnostics = TerminalReadinessDiagnostics(
            workingDirectoryName: "repo-a",
            shellProfileMode: "login",
            emitInvestigation: { _, _ in },
            emitMetric: { metric, _, _ in
                metricNames.append(metric)
            },
            now: { clock.now }
        )

        diagnostics.markSurfaceCreateStarted()
        clock.now = clock.now.addingTimeInterval(0.200)
        diagnostics.observeShellSignal(.setTitle)
        clock.now = clock.now.addingTimeInterval(0.100)
        diagnostics.observeShellSignal(.pwd)

        #expect(metricNames == ["terminal_first_output", "first_prompt_ready"])
    }
}
