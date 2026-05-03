import Foundation
import Testing

@Suite("SparkleAppcastScript", .serialized)
struct SparkleAppcastScriptTests {
    private let testPrivateKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    @Test("Missing private key fails clearly")
    func missingPrivateKeyFailsClearly() throws {
        let fixture = try makeFixture()
        let result = runAppcastScript(
            arguments: [
                "--dmg", fixture.dmg.path,
                "--app", fixture.app.path,
                "--tag", "v9.9.9",
                "--output", fixture.output.path,
            ],
            environment: [:]
        )

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("SPARKLE_PRIVATE_KEY is required"))
    }

    @Test("Generated appcast contains signed release metadata")
    func generatedAppcastContainsSignedReleaseMetadata() throws {
        let fixture = try makeFixture()
        let result = runAppcastScript(
            arguments: [
                "--dmg", fixture.dmg.path,
                "--app", fixture.app.path,
                "--tag", "v9.9.9",
                "--repo", "fairchild/workspaces",
                "--output", fixture.output.path,
            ],
            environment: ["SPARKLE_PRIVATE_KEY": testPrivateKey]
        )

        #expect(result.exitCode == 0)
        let xml = try String(contentsOf: fixture.output, encoding: .utf8)
        #expect(xml.contains("<sparkle:version>999</sparkle:version>"))
        #expect(xml.contains("<sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>"))
        #expect(xml.contains("<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>"))
        let dmgURL =
            "https://github.com/fairchild/workspaces/releases/download/v9.9.9/"
            + "WorkspaceManager-9.9.9.dmg"
        #expect(xml.contains(dmgURL))
        #expect(xml.contains("sparkle:edSignature="))
        #expect(xml.contains("length=\"4\""))
    }

    private func makeFixture() throws -> (app: URL, dmg: URL, output: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkleAppcastScriptTests-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("WorkspaceManager.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let dmg = root.appendingPathComponent("WorkspaceManager-9.9.9.dmg")
        let output = root.appendingPathComponent("appcast.xml")

        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleVersion": "999",
            "CFBundleShortVersionString": "9.9.9",
            "LSMinimumSystemVersion": "14.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("test".utf8).write(to: dmg)

        return (app, dmg, output)
    }

    private func runAppcastScript(
        arguments: [String],
        environment: [String: String]
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let process = Process()
        process.currentDirectoryURL = repoRoot
        process.executableURL = repoRoot.appendingPathComponent("scripts/generate-sparkle-appcast.sh")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (127, "", error.localizedDescription)
        }

        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdoutText, stderrText)
    }
}
