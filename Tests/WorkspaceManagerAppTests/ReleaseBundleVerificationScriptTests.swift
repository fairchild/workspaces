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

    // MARK: - Structure-only mode
    //
    // The assertions above need no signature, but until #1305 they only ran after
    // signing — so a resource-layout break passed CI's unsigned build and failed the
    // release minutes later. These cover the mode that lets CI run them, and the guard
    // that adding it did not weaken the release path.

    /// The case the CI step depends on: a complete but entirely unsigned bundle passes.
    /// The fixture carries no signature at all, so this also proves signing is skipped
    /// rather than merely tolerated.
    @Test("Structure-only accepts a complete unsigned bundle")
    func structureOnlyAcceptsCompleteUnsignedBundle() throws {
        let fixture = try makeFixture(
            bundleName: "WorkSpaces.app",
            includeRuntimeResources: true,
            includeHookForwarders: true
        )
        defer { fixture.cleanup() }

        let result = runVerifier(appBundle: fixture.appBundle, structureOnly: true)

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("Verified release bundle structure"))
    }

    /// The issue's literal acceptance criterion: dropping `Contents/Resources/terminfo`
    /// from the bundle layout has to fail the unsigned lane.
    @Test("Structure-only rejects a bundle missing terminfo")
    func structureOnlyRejectsMissingTerminfo() throws {
        let fixture = try makeFixture(
            bundleName: "WorkSpaces.app",
            includeRuntimeResources: true,
            includeHookForwarders: true,
            omitTerminfo: true
        )
        defer { fixture.cleanup() }

        let result = runVerifier(appBundle: fixture.appBundle, structureOnly: true)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Missing bundled terminfo directory"))
    }

    @Test("Structure-only rejects a bundle missing Ghostty resources")
    func structureOnlyRejectsMissingGhosttyResources() throws {
        let fixture = try makeFixture(
            bundleName: "WorkSpaces.app",
            includeRuntimeResources: true,
            includeHookForwarders: true,
            omitGhostty: true
        )
        defer { fixture.cleanup() }

        let result = runVerifier(appBundle: fixture.appBundle, structureOnly: true)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Missing Ghostty resources directory"))
    }

    @Test("Structure-only rejects a bundle missing a hook forwarder")
    func structureOnlyRejectsMissingHookForwarder() throws {
        let fixture = try makeFixture(bundleName: "WorkSpaces.app", includeRuntimeResources: true)
        defer { fixture.cleanup() }

        let result = runVerifier(appBundle: fixture.appBundle, structureOnly: true)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Missing Claude hook event forwarder"))
    }

    /// Identity is structure, so it is still enforced without a signature — the mode
    /// drops signing, not everything that happens to be cheap to drop.
    @Test("Structure-only still enforces bundle identity")
    func structureOnlyStillEnforcesBundleIdentity() throws {
        let fixture = try makeFixture(
            bundleName: "WorkSpaces.app",
            displayName: "WorkspaceManager",
            includeRuntimeResources: true,
            includeHookForwarders: true
        )
        defer { fixture.cleanup() }

        let result = runVerifier(appBundle: fixture.appBundle, structureOnly: true)

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("CFBundleName must be WorkSpaces"))
    }

    /// The guard that matters for the release path: the same complete-but-unsigned
    /// bundle structure-only accepts must still be rejected by the default mode.
    /// Without this, adding the flag could not be told apart from relaxing the default.
    @Test("The default mode still rejects the unsigned bundle structure-only accepts")
    func defaultModeStillRejectsAnUnsignedBundle() throws {
        let fixture = try makeFixture(
            bundleName: "WorkSpaces.app",
            includeRuntimeResources: true,
            includeHookForwarders: true
        )
        defer { fixture.cleanup() }

        #expect(runVerifier(appBundle: fixture.appBundle, structureOnly: true).exitCode == 0)

        let result = runVerifier(appBundle: fixture.appBundle)

        #expect(result.exitCode == 1)
    }

    private func makeFixture(
        bundleName: String,
        displayName: String = "WorkSpaces",
        bundleDisplayName: String = "WorkSpaces",
        executableName: String = "WorkspaceManager",
        includeRuntimeResources: Bool = false,
        includeHookForwarders: Bool = false,
        omitGhostty: Bool = false,
        omitTerminfo: Bool = false
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

            if !omitGhostty {
                try FileManager.default.createDirectory(
                    at: resources.appendingPathComponent("ghostty", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            if !omitTerminfo {
                try FileManager.default.createDirectory(
                    at: resources.appendingPathComponent("terminfo", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        }

        if includeHookForwarders {
            let forwarders = resources.appendingPathComponent("HookForwarders", isDirectory: true)
            try FileManager.default.createDirectory(at: forwarders, withIntermediateDirectories: true)
            for name in ["event-forwarder.sh", "statusline.sh"] {
                try Data().write(to: forwarders.appendingPathComponent(name))
            }
        }

        return Fixture(root: root, appBundle: appBundle)
    }

    private func runVerifier(
        appBundle: URL,
        structureOnly: Bool = false
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let process = Process()
        process.currentDirectoryURL = repoRoot
        process.executableURL = repoRoot.appendingPathComponent("scripts/verify-release-bundle.sh")
        process.arguments = structureOnly ? ["--structure-only", appBundle.path] : [appBundle.path]

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
