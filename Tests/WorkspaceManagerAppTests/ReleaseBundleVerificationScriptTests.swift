import Foundation
import Testing

@Suite("ReleaseBundleVerificationScript", .serialized)
struct ReleaseBundleVerificationScriptTests {
    @Test("WorkspaceManager public bundle name fails release verification")
    func workspaceManagerPublicBundleNameFailsReleaseVerification() throws {
        let fixture = try makeFixture(bundleName: "WorkspaceManager.app")
        defer { fixture.cleanup() }

        let result = runVerifier(appBundle: fixture.appBundle)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Release app bundle must be named WorkSpaces.app"))
    }

    @Test("Wrong bundle display name fails release verification")
    func wrongBundleDisplayNameFailsReleaseVerification() throws {
        let fixture = try makeFixture(
            bundleName: "WorkSpaces.app",
            bundleDisplayName: "WorkspaceManager"
        )
        defer { fixture.cleanup() }

        let result = runVerifier(appBundle: fixture.appBundle)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("CFBundleDisplayName must be WorkSpaces"))
    }

    @Test("Wrong bundle name metadata fails release verification")
    func wrongBundleNameMetadataFailsReleaseVerification() throws {
        let fixture = try makeFixture(
            bundleName: "WorkSpaces.app",
            displayName: "WorkspaceManager"
        )
        defer { fixture.cleanup() }

        let result = runVerifier(appBundle: fixture.appBundle)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("CFBundleName must be WorkSpaces"))
    }

    @Test("Wrong executable metadata fails release verification")
    func wrongExecutableMetadataFailsReleaseVerification() throws {
        let fixture = try makeFixture(
            bundleName: "WorkSpaces.app",
            executableName: "WorkSpaces"
        )
        defer { fixture.cleanup() }

        let result = runVerifier(appBundle: fixture.appBundle)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("CFBundleExecutable must be WorkspaceManager"))
    }

    @Test("Missing hook forwarder resources fail release verification")
    func missingHookForwarderResourcesFailReleaseVerification() throws {
        let fixture = try makeFixture(bundleName: "WorkSpaces.app", includeRuntimeResources: true)
        defer { fixture.cleanup() }

        let result = runVerifier(appBundle: fixture.appBundle)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Missing Claude hook event forwarder"))
    }

    private func makeFixture(
        bundleName: String,
        displayName: String = "WorkSpaces",
        bundleDisplayName: String = "WorkSpaces",
        executableName: String = "WorkspaceManager",
        includeRuntimeResources: Bool = false
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReleaseBundleVerificationScriptTests-\(UUID().uuidString)", isDirectory: true)
        let appBundle = root.appendingPathComponent(bundleName, isDirectory: true)
        let contents = appBundle.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)

        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleDisplayName": bundleDisplayName,
            "CFBundleName": displayName,
            "CFBundleExecutable": executableName,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        if includeRuntimeResources {
            let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            let executable = macOS.appendingPathComponent("WorkspaceManager")
            try Data().write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

            try FileManager.default.createDirectory(
                at: resources.appendingPathComponent("ghostty", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: resources.appendingPathComponent("terminfo", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        return Fixture(root: root, appBundle: appBundle)
    }

    private func runVerifier(appBundle: URL) -> (exitCode: Int32, stdout: String, stderr: String) {
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let process = Process()
        process.currentDirectoryURL = repoRoot
        process.executableURL = repoRoot.appendingPathComponent("scripts/verify-release-bundle.sh")
        process.arguments = [appBundle.path]

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

    private struct Fixture {
        let root: URL
        let appBundle: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
