import AppKit
import Foundation
import WorkspaceManagerCore

enum DiagnosticReportExporter {
    static let recentLogsPredicate =
        "subsystem == \"com.cloudcompute.workspaces\" OR process == \"WorkspaceManager\" OR eventMessage CONTAINS \"[Perf]\""

    struct Report: Codable {
        let schemaVersion: Int
        let generatedAt: Date
        let system: SystemInfo
        let modelStore: ModelStoreStatusSnapshot
        let startupDiagnostics: StartupDiagnosticsStore.DiagnosticsBundle
    }

    struct SystemInfo: Codable {
        let osVersion: String
        let osBuild: String
        let architecture: String
        let hardwareModel: String
        let physicalMemoryGB: Double
        let processorCount: Int
        let uptimeSeconds: Double
    }

    @MainActor
    static func exportWithSavePanel() async {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostic Report"
        panel.nameFieldStringValue = defaultFilename()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try await assembleReport(to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    static func assembleReport(to zipURL: URL) async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspaces-report-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // report.json
        let (appVersion, buildNumber) = resolvedVersionInfo()
        let diagnosticsBundle = await StartupDiagnosticsStore.shared.export(
            appVersion: appVersion,
            buildNumber: buildNumber
        )
        let systemInfo = gatherSystemInfo()
        let modelStoreSnapshot = await MainActor.run {
            ModelStoreStatusController.shared.snapshot
        }
        let report = makeReport(
            diagnosticsBundle: diagnosticsBundle,
            systemInfo: systemInfo,
            modelStoreSnapshot: modelStoreSnapshot
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: tempDir.appendingPathComponent("report.json"))

        // system-profile.txt
        let profile = gatherSystemProfile(systemInfo)
        try profile.write(to: tempDir.appendingPathComponent("system-profile.txt"), atomically: true, encoding: .utf8)

        // recent-logs.txt (unified log, last 5 minutes)
        let recentLogs = captureRecentUnifiedLogs()
        try recentLogs.write(to: tempDir.appendingPathComponent("recent-logs.txt"), atomically: true, encoding: .utf8)

        // lume-daemon.log (tail)
        appendLogTail(from: "/tmp/lume_daemon.log", to: tempDir, as: "lume-daemon.log")
        appendLogTail(from: "/tmp/lume_daemon.error.log", to: tempDir, as: "lume-daemon-error.log")

        // zip
        try createZip(from: tempDir, to: zipURL)
    }

    static func makeReport(
        diagnosticsBundle: StartupDiagnosticsStore.DiagnosticsBundle,
        systemInfo: SystemInfo,
        modelStoreSnapshot: ModelStoreStatusSnapshot
    ) -> Report {
        Report(
            schemaVersion: 2,
            generatedAt: Date(),
            system: systemInfo,
            modelStore: modelStoreSnapshot,
            startupDiagnostics: diagnosticsBundle
        )
    }

    // MARK: - System Info

    private static func gatherSystemInfo() -> SystemInfo {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osBuild = shellOutput("/usr/bin/sw_vers", ["-buildVersion"]) ?? "unknown"
        let model = sysctlString("hw.model") ?? "unknown"
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)

        return SystemInfo(
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            osBuild: osBuild,
            architecture: currentArchitecture(),
            hardwareModel: model,
            physicalMemoryGB: (memoryGB * 10).rounded() / 10,
            processorCount: ProcessInfo.processInfo.processorCount,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime
        )
    }

    private static func gatherSystemProfile(_ info: SystemInfo) -> String {
        var lines: [String] = []
        lines.append("WorkSpaces Diagnostic Report")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("System:")
        lines.append("  macOS \(info.osVersion) (build \(info.osBuild))")
        lines.append("  Architecture: \(info.architecture)")
        lines.append("  Hardware: \(info.hardwareModel)")
        lines.append("  Memory: \(info.physicalMemoryGB) GB")
        lines.append("  Processors: \(info.processorCount)")
        lines.append("  Uptime: \(Int(info.uptimeSeconds))s")
        lines.append("")

        let (version, build) = resolvedVersionInfo()
        lines.append("App:")
        lines.append("  Version: \(version) (\(build))")
        lines.append("  Channel: \(AppBuildIdentity.current.channel.rawValue)")
        lines.append("  Path: \(AppBuildIdentity.current.fullPath)")
        lines.append("")
        lines.append("Model Store:")
        let modelStore = MainActor.assumeIsolated {
            ModelStoreStatusController.shared.snapshot
        }
        lines.append("  Mode: \(modelStore.mode.label)")
        lines.append("  Path: \(modelStore.mode.path ?? "In-memory only")")
        if modelStore.bootstrapErrors.isEmpty {
            lines.append("  Bootstrap Errors: none")
        } else {
            lines.append("  Bootstrap Errors:")
            for error in modelStore.bootstrapErrors {
                lines.append("    - \(error)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Logs

    private static func captureRecentUnifiedLogs() -> String {
        let output = shellOutput(
            "/usr/bin/log",
            [
                "show", "--last", "5m",
                "--predicate",
                recentLogsPredicate,
                "--style", "compact",
            ]
        )
        return output ?? "(no log entries or log command failed)\n"
    }

    private static func appendLogTail(
        from path: String,
        to directory: URL,
        as filename: String,
        maxBytes: Int = 100_000
    ) {
        let fileURL = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        let offset = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0
        handle.seek(toFileOffset: offset)

        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        try? data.write(to: directory.appendingPathComponent(filename))
    }

    // MARK: - Zip

    private static func createZip(from sourceDir: URL, to zipURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", sourceDir.path, zipURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "DiagnosticReportExporter",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create zip archive"]
            )
        }
    }

    // MARK: - Helpers

    private static func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "workspaces-report-\(formatter.string(from: Date())).zip"
    }

    private static func currentArchitecture() -> String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private static func resolvedVersionInfo() -> (appVersion: String, buildNumber: String) {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let bundleBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

        if let bundleVersion, let bundleBuild {
            return (bundleVersion, bundleBuild)
        }

        // Debug builds lack Info.plist values — use git SHA from the source root.
        let identity = AppBuildIdentity.current
        let gitSHA: String? = {
            guard identity.isDevelopment,
                let root = AppBuildIdentity.inferredSourceRoot(from: Bundle.main.executableURL ?? Bundle.main.bundleURL)
            else { return nil }
            return shellOutput("/usr/bin/git", ["-C", root.path, "rev-parse", "--short", "HEAD"])
        }()

        return (
            bundleVersion ?? "dev",
            bundleBuild ?? gitSHA ?? "unknown"
        )
    }

    private static func shellOutput(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
