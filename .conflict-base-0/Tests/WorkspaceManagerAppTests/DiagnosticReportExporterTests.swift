import Testing

@testable import WorkspaceManager

@Suite("DiagnosticReportExporter")
struct DiagnosticReportExporterTests {
    @Test("recent log predicate includes perf lines and app process logs")
    func recentLogPredicateIncludesPerfAndProcessLogs() {
        #expect(DiagnosticReportExporter.recentLogsPredicate.contains("eventMessage CONTAINS \"[Perf]\""))
        #expect(DiagnosticReportExporter.recentLogsPredicate.contains("process == \"WorkspaceManager\""))
        #expect(DiagnosticReportExporter.recentLogsPredicate.contains("subsystem == \"com.cloudcompute.workspaces\""))
    }
}
