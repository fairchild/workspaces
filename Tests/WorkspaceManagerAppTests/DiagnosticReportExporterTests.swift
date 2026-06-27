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
        let localStateSnapshot = LocalStateStoreStatusSnapshot(
            mode: .persistent(path: "/tmp/local-state.sqlite"),
            bootstrapErrors: []
        )
        let localStateSummary = LocalStateStoreSummary(
            schemaVersion: 1,
            databasePath: "/tmp/local-state.sqlite",
            generatedAt: Date(),
            tableCounts: ["terminal_sessions": 1]
        )

        let report = DiagnosticReportExporter.makeReport(
            diagnosticsBundle: diagnostics,
            systemInfo: systemInfo,
            modelStoreSnapshot: snapshot,
            localStateSnapshot: localStateSnapshot,
            localStateSummary: localStateSummary
        )

        #expect(report.modelStore == snapshot)
        #expect(report.localStateStore == localStateSnapshot)
        #expect(report.localStateSummary == localStateSummary)
        #expect(report.schemaVersion == 3)
    }

    @Test("report assembly completes after resuming away from the main actor")
    func reportAssemblyCompletesOffMainActor() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.cleanup() }

        let zipURL = fixture.url.appendingPathComponent("workspaces-report.zip")
        try await Task.detached {
            await Task.yield()
            try await DiagnosticReportExporter.assembleReport(to: zipURL)
        }.value

        #expect(FileManager.default.fileExists(atPath: zipURL.path))

        let extractedURL = fixture.url.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractedURL, withIntermediateDirectories: true)
        try extractZip(zipURL, to: extractedURL)

        let reportFiles = Set(try FileManager.default.contentsOfDirectory(atPath: extractedURL.path))
        #expect(reportFiles.contains("report.json"))
        #expect(reportFiles.contains("system-profile.txt"))
        #expect(reportFiles.contains("recent-logs.txt"))

        let profile = try String(
            contentsOf: extractedURL.appendingPathComponent("system-profile.txt"),
            encoding: .utf8
        )
        #expect(profile.contains("Model Store:"))
        #expect(profile.contains("Local State Store:"))
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticReportExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

private func extractZip(_ zipURL: URL, to destinationURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", zipURL.path, destinationURL.path]
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw NSError(
            domain: "DiagnosticReportExporterTests",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: message ?? "Failed to extract diagnostic report zip"]
        )
    }
}
