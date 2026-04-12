import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("DiagnosticReportExporter")
struct DiagnosticReportExporterTests {
    @Test("recent log predicate includes perf lines and app process logs")
    func recentLogPredicateIncludesPerfAndProcessLogs() {
        #expect(DiagnosticReportExporter.recentLogsPredicate.contains("eventMessage CONTAINS \"[Perf]\""))
        #expect(DiagnosticReportExporter.recentLogsPredicate.contains("process == \"WorkspaceManager\""))
        #expect(DiagnosticReportExporter.recentLogsPredicate.contains("subsystem == \"com.cloudcompute.workspaces\""))
    }

    @Test("report payload includes model-store mode and bootstrap errors")
    func reportIncludesModelStoreDetails() {
        let diagnostics = StartupDiagnosticsStore.DiagnosticsBundle(
            appVersion: "1.0",
            buildNumber: "123",
            osVersion: "macOS",
            architecture: "arm64",
            capturedAt: Date(),
            events: []
        )
        let systemInfo = DiagnosticReportExporter.SystemInfo(
            osVersion: "14.0",
            osBuild: "23A",
            architecture: "arm64",
            hardwareModel: "Mac",
            physicalMemoryGB: 16,
            processorCount: 8,
            uptimeSeconds: 42
        )
        let snapshot = ModelStoreStatusSnapshot(
            mode: .inMemoryDegraded,
            bootstrapErrors: ["primary failed", "fallback failed"]
        )

        let report = DiagnosticReportExporter.makeReport(
            diagnosticsBundle: diagnostics,
            systemInfo: systemInfo,
            modelStoreSnapshot: snapshot
        )

        #expect(report.modelStore == snapshot)
        #expect(report.schemaVersion == 2)
    }
}
