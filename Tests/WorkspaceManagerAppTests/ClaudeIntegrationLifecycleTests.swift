// swift-format-ignore-file: NeverForceUnwrap
// Test fixtures/helpers force-unwrap known-good literals or generator output; a failure here is a loud test crash, not a user-facing risk.
//
//  ClaudeIntegrationLifecycleTests.swift
//  WorkspaceManagerAppTests
//
//  Verifies the settings-repair behaviour the lifecycle uses on cold start once
//  the user has opted in.
//

import Combine
import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("ClaudeIntegrationLifecycle settings repair", .serialized)
struct ClaudeIntegrationLifecycleTests {

    actor StubInstaller: ClaudeSettingsInstalling {
        private(set) var installCallCount = 0

        func renderPreview() async throws -> String { "stub" }
        func install() async throws {
            installCallCount += 1
        }
        func isInstalled() async -> Bool { installCallCount > 0 }
        func userSettingsURL() async -> URL { URL(fileURLWithPath: "/tmp/stub/.claude/settings.json") }
        func mostRecentBackupPath() async -> String? {
            installCallCount > 0 ? "/tmp/stub/.claude/settings.json.workspaces-backup-stub" : nil
        }
        func userSettingsModificationDate() async -> Date? { nil }
    }

    /// A per-call temp-dir socket path so the hook listener never binds the real,
    /// machine-wide `~/Library/Application Support/<bundleID>/hooks.sock` — that path
    /// is `flock`-guarded against any real running app instance on the same machine,
    /// which the install-once assertions below have nothing to do with.
    private static func ephemeralSocketURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-lifecycle-test-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("sock")
    }

    /// Helper: configures the singleton with a fresh ephemeral defaults suite and a
    /// stub installer, then waits for the lifecycle's startup Task to finish so the
    /// (a)synchronous install() invocation has been observed.
    private func runStart(optedIn: Bool) async -> StubInstaller {
        let suiteName = "wm-lifecycle-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(optedIn, forKey: ClaudeIntegrationDefaults.optedInKey)

        let stub = StubInstaller()
        ClaudeIntegrationLifecycle.shared._configureForTesting(
            defaults: defaults,
            installerFactory: { _ in stub },
            socketURLOverride: Self.ephemeralSocketURL()
        )

        let registry = AgentSessionRegistry()
        ClaudeIntegrationLifecycle.shared.start(registry: registry)

        // Wait for the lifecycle's startup Task chain to complete. The chain awaits
        // `listener.socketPath`, then calls install(), then starts the listener.
        // Polling for installCallCount or a timeout is sufficient.
        let deadline = Date().addingTimeInterval(15.0)
        while Date() < deadline {
            let count = await stub.installCallCount
            if !optedIn {
                // For the not-opted-in case, we still need to wait long enough that
                // the Task has had a chance to either call install() or skip it.
                try? await Task.sleep(nanoseconds: 200_000_000)
                break
            }
            if count > 0 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // Tear the listener down so its actor doesn't keep the socket file around.
        await ClaudeIntegrationLifecycle.shared.stop()
        UserDefaults().removePersistentDomain(forName: suiteName)
        return stub
    }

    @Test("install() is called exactly once on launch when the user has opted in")
    func optedInLaunchTriggersSilentInstall() async {
        let stub = await runStart(optedIn: true)
        let count = await stub.installCallCount
        #expect(count == 1)
    }

    @Test("install() is not called when the user has not opted in")
    func notOptedInLaunchDoesNotInstall() async {
        let stub = await runStart(optedIn: false)
        let count = await stub.installCallCount
        #expect(count == 0)
    }

    @Test("settings installer publishes after startup for Settings scene injection")
    func settingsInstallerPublishesAfterStartup() async {
        let suiteName = "wm-lifecycle-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let stub = StubInstaller()
        ClaudeIntegrationLifecycle.shared._configureForTesting(
            defaults: defaults,
            installerFactory: { _ in stub },
            socketURLOverride: Self.ephemeralSocketURL()
        )

        var didPublishInstaller = false
        let cancellable = ClaudeIntegrationLifecycle.shared.$settingsInstaller
            .sink { installer in
                if installer != nil {
                    didPublishInstaller = true
                }
            }

        let registry = AgentSessionRegistry()
        ClaudeIntegrationLifecycle.shared.start(registry: registry)

        let deadline = Date().addingTimeInterval(15.0)
        while Date() < deadline {
            if didPublishInstaller { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        await ClaudeIntegrationLifecycle.shared.stop()
        UserDefaults().removePersistentDomain(forName: suiteName)
        _ = cancellable

        #expect(didPublishInstaller)
    }

    @Test("bundled hook forwarder resources resolve in SwiftPM debug builds")
    func bundledHookForwarderResourcesResolve() throws {
        let eventForwarder = try #require(
            ClaudeIntegrationLifecycle.bundledHookForwarderURL(named: "event-forwarder"))
        let statusLine = try #require(
            ClaudeIntegrationLifecycle.bundledHookForwarderURL(named: "statusline"))
        let commandStatus = try #require(
            ClaudeIntegrationLifecycle.bundledHookForwarderURL(
                named: "command-status",
                fileExtension: "zsh"
            ))

        #expect(FileManager.default.fileExists(atPath: eventForwarder.path))
        #expect(FileManager.default.fileExists(atPath: statusLine.path))
        #expect(FileManager.default.fileExists(atPath: commandStatus.path))
        #expect(ClaudeIntegrationLifecycle.bundledCommandStatusHookPath() == commandStatus.path)
    }

    @Test("packaged app hook forwarder resources resolve from flattened app resources")
    func packagedAppHookForwarderResourcesResolveFromMainBundle() throws {
        let fixture = try makePackagedAppFixture(includeEventForwarder: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var didAskForSwiftPMBundle = false
        let resolvedURL = try #require(
            ClaudeIntegrationLifecycle.bundledHookForwarderURL(
                named: "event-forwarder",
                mainBundle: fixture.appBundle,
                swiftPMResourceBundle: {
                    didAskForSwiftPMBundle = true
                    return nil
                }
            ))

        #expect(resolvedURL.standardizedFileURL == fixture.eventForwarderURL?.standardizedFileURL)
        #expect(!didAskForSwiftPMBundle)
    }

    @Test("packaged app missing hook forwarder resources does not touch SwiftPM bundle")
    func packagedAppMissingHookForwarderResourcesDoNotTouchSwiftPMBundle() throws {
        let fixture = try makePackagedAppFixture(includeEventForwarder: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var didAskForSwiftPMBundle = false
        let resolvedURL = ClaudeIntegrationLifecycle.bundledHookForwarderURL(
            named: "event-forwarder",
            mainBundle: fixture.appBundle,
            swiftPMResourceBundle: {
                didAskForSwiftPMBundle = true
                return nil
            }
        )

        #expect(resolvedURL == nil)
        #expect(!didAskForSwiftPMBundle)
    }

    private func makePackagedAppFixture(includeEventForwarder: Bool) throws -> PackagedAppFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeIntegrationLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        let appBundleURL = root.appendingPathComponent("WorkSpaces.app", isDirectory: true)
        let contentsURL = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        let hookForwardersURL =
            contentsURL
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("HookForwarders", isDirectory: true)
        try FileManager.default.createDirectory(at: hookForwardersURL, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleExecutable": "WorkspaceManager",
            "CFBundleIdentifier": "com.cloudcompute.workspaces",
            "CFBundleName": "WorkSpaces",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let eventForwarderURL = hookForwardersURL.appendingPathComponent("event-forwarder.sh")
        if includeEventForwarder {
            try "#!/bin/sh\n".write(to: eventForwarderURL, atomically: true, encoding: .utf8)
        }

        let appBundle = try #require(Bundle(url: appBundleURL))
        return PackagedAppFixture(
            root: root,
            appBundle: appBundle,
            eventForwarderURL: includeEventForwarder ? eventForwarderURL : nil
        )
    }

    private struct PackagedAppFixture {
        let root: URL
        let appBundle: Bundle
        let eventForwarderURL: URL?
    }
}
