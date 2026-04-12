import Foundation
import Testing

@Suite("PrepareReleaseScript", .serialized)
struct PrepareReleaseScriptTests {
    @Test("dry-run classifies breaking conventional commits")
    func dryRunClassifiesBreakingConventionalCommits() throws {
        let fixture = try ReleasePreparationFixture.create()
        defer { fixture.cleanup() }

        try fixture.commitSeed(message: "chore: bootstrap fixture")
        try fixture.createTag("v0.1.0")

        try fixture.commitChange(
            path: "feature.txt", content: "feature\n", message: "feat!: remove legacy configuration")
        try fixture.commitChange(path: "fix.txt", content: "fix\n", message: "fix(api)!: remove unstable fallback")
        try fixture.commitChange(path: "docs.txt", content: "docs\n", message: "docs: explain release helper")
        try fixture.configureOrigin()

        let result = try fixture.runPrepareRelease(version: "0.2.0", dryRun: true)

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("### Added"))
        #expect(result.stdout.contains("- remove legacy configuration"))
        #expect(result.stdout.contains("### Fixed"))
        #expect(result.stdout.contains("- remove unstable fallback"))
        #expect(result.stdout.contains("### Other"))
        #expect(result.stdout.contains("- explain release helper"))
    }

    @Test("first release dry-run excludes the root commit from generated notes")
    func firstReleaseDryRunExcludesRootCommit() throws {
        let fixture = try ReleasePreparationFixture.create()
        defer { fixture.cleanup() }

        try fixture.commitSeed(message: "chore: bootstrap fixture")
        try fixture.commitChange(path: "feature.txt", content: "feature\n", message: "feat: ship first feature")
        try fixture.configureOrigin()

        let result = try fixture.runPrepareRelease(version: "0.1.0", dryRun: true)

        #expect(result.exitCode == 0)
        #expect(!result.stdout.contains("bootstrap fixture"))
        #expect(result.stdout.contains("- ship first feature"))
    }
}

private struct ReleasePreparationFixture {
    let rootURL: URL
    let remoteURL: URL
    let scriptURL: URL

    static func create() throws -> ReleasePreparationFixture {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrepareReleaseScriptTests-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fixtureRoot.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fixtureRoot.appendingPathComponent("Sources/WorkspaceManager/Resources"),
            withIntermediateDirectories: true
        )

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        try FileManager.default.copyItem(
            at: projectRoot.appendingPathComponent("scripts/prepare-release.sh"),
            to: fixtureRoot.appendingPathComponent("scripts/prepare-release.sh")
        )
        try FileManager.default.copyItem(
            at: projectRoot.appendingPathComponent("scripts/release-version.sh"),
            to: fixtureRoot.appendingPathComponent("scripts/release-version.sh")
        )

        try setExecutable(fixtureRoot.appendingPathComponent("scripts/prepare-release.sh"))
        try setExecutable(fixtureRoot.appendingPathComponent("scripts/release-version.sh"))

        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleShortVersionString</key>
                <string>0.1.0</string>
                <key>CFBundleVersion</key>
                <string>6</string>
            </dict>
            </plist>
            """
        try plist.write(
            to: fixtureRoot.appendingPathComponent("Sources/WorkspaceManager/Resources/Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        try "# Changelog\n\n".write(
            to: fixtureRoot.appendingPathComponent("CHANGELOG.md"),
            atomically: true,
            encoding: .utf8
        )

        let remoteURL = fixtureRoot.deletingLastPathComponent()
            .appendingPathComponent("PrepareReleaseScriptRemote-\(UUID().uuidString).git")

        try run(["git", "init"], in: fixtureRoot)
        try run(["git", "branch", "-M", "main"], in: fixtureRoot)
        try run(["git", "config", "user.email", "test@example.com"], in: fixtureRoot)
        try run(["git", "config", "user.name", "Test User"], in: fixtureRoot)

        return ReleasePreparationFixture(
            rootURL: fixtureRoot,
            remoteURL: remoteURL,
            scriptURL: fixtureRoot.appendingPathComponent("scripts/prepare-release.sh")
        )
    }

    func commitSeed(message: String) throws {
        try Self.run(["git", "add", "-A"], in: rootURL)
        try Self.run(["git", "commit", "-m", message], in: rootURL)
    }

    func commitChange(path: String, content: String, message: String) throws {
        let fileURL = rootURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        try Self.run(["git", "add", "-A"], in: rootURL)
        try Self.run(["git", "commit", "-m", message], in: rootURL)
    }

    func createTag(_ tag: String) throws {
        try Self.run(["git", "tag", tag], in: rootURL)
    }

    func configureOrigin() throws {
        try Self.run(["git", "clone", "--bare", rootURL.path, remoteURL.path], in: rootURL.deletingLastPathComponent())
        try Self.run(["git", "remote", "add", "origin", remoteURL.path], in: rootURL)
    }

    func runPrepareRelease(version: String, dryRun: Bool) throws -> ProcessResult {
        var arguments = [scriptURL.path, "--version", version]
        if dryRun {
            arguments.append("--dry-run")
        }
        return try Self.run(["/bin/bash"] + arguments, in: rootURL, expectedStatus: 0)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
        try? FileManager.default.removeItem(at: remoteURL)
    }

    private static func setExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @discardableResult
    private static func run(_ args: [String], in directory: URL, expectedStatus: Int32 = 0) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = directory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if process.terminationStatus != expectedStatus {
            throw FixtureError.commandFailed(
                command: args.joined(separator: " "),
                status: process.terminationStatus,
                stdout: stdout,
                stderr: stderr
            )
        }

        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    enum FixtureError: Error, CustomStringConvertible {
        case commandFailed(command: String, status: Int32, stdout: String, stderr: String)

        var description: String {
            switch self {
            case .commandFailed(let command, let status, let stdout, let stderr):
                return """
                    Command failed (\(status)): \(command)
                    stdout:
                    \(stdout)
                    stderr:
                    \(stderr)
                    """
            }
        }
    }
}
