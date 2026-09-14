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

    actor RefusingInstaller: ClaudeSettingsInstalling {
        struct WriteRefused: LocalizedError {
            var errorDescription: String? {
                "You don’t have permission to save the file “settings.json” in the folder “.claude”."
            }
        }

        func renderPreview() async throws -> String { "stub" }
        func install() async throws { throw WriteRefused() }
        func isInstalled() async -> Bool { false }
        func userSettingsURL() async -> URL { URL(fileURLWithPath: "/tmp/stub/.claude/settings.json") }
        func mostRecentBackupPath() async -> String? { nil }
        func userSettingsModificationDate() async -> Date? { nil }
    }

    /// An installer whose `install()` waits, mid-attempt, until the test lets it finish, so a
    /// test can act while an install that will succeed is still running.
    actor SuspendingInstaller: ClaudeSettingsInstalling {
        private var installStarted: CheckedContinuation<Void, Never>?
        private var installRelease: CheckedContinuation<Void, Never>?
        private var hasStartedInstall = false
        private var installed = false

        func renderPreview() async throws -> String { "stub" }
        func install() async throws {
            hasStartedInstall = true
            installStarted?.resume()
            installStarted = nil
            await withCheckedContinuation { installRelease = $0 }
            installed = true
        }
        func isInstalled() async -> Bool { installed }
        func userSettingsURL() async -> URL { URL(fileURLWithPath: "/tmp/stub/.claude/settings.json") }
        func mostRecentBackupPath() async -> String? { nil }
        func userSettingsModificationDate() async -> Date? { nil }

        func waitUntilInstallStarts() async {
            guard !hasStartedInstall else { return }
            await withCheckedContinuation { installStarted = $0 }
        }

        func finishInstall() {
            installRelease?.resume()
            installRelease = nil
        }
    }

    /// A per-call socket path so the hook listener never binds the real, machine-wide
    /// `~/Library/Application Support/<bundleID>/hooks.sock` — that path is `flock`-guarded
    /// against any real running app instance on the same machine, which the install-once
    /// assertions below have nothing to do with. Built under `/tmp` directly (not
    /// `FileManager.default.temporaryDirectory`, whose per-user `/var/folders/.../T/` prefix
    /// plus a full UUID overflows Darwin's 104-byte `sockaddr_un.sun_path`, so the listener
    /// would silently fail to bind and every isolation guarantee here would be a no-op).
    private static func ephemeralSocketURL() -> URL {
        URL(fileURLWithPath: "/tmp/wm-\(UUID().uuidString.prefix(8)).sock")
    }

    /// Helper: configures the singleton with a fresh ephemeral defaults suite and a
    /// stub installer, then waits for the lifecycle's startup Task to finish so the
    /// (a)synchronous install() invocation has been observed.
    private func runStart(optedIn: Bool) async throws -> StubInstaller {
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

        // Await the lifecycle's own startup chain rather than a deadline over its side
        // effects. The chain resolves the socket path, constructs the installer, starts
        // the listener and performs the opted-in repair; when its task completes, the
        // install has either happened or been skipped, and there is nothing left to
        // wait for. Polling with a 15s ceiling read `count → 0` on a loaded runner —
        // not a second install, the first one simply had not happened yet (#1306).
        // Required, not optional-chained: `startupTask?.value` on a nil task awaits
        // nothing and would let the not-opted-in case assert `count == 0` against a
        // lifecycle that never started.
        let startup = try #require(ClaudeIntegrationLifecycle.shared.startupTask)
        await startup.value

        // Tear the listener down so its actor doesn't keep the socket file around.
        await ClaudeIntegrationLifecycle.shared.stop()
        UserDefaults().removePersistentDomain(forName: suiteName)
        return stub
    }

    @Test("install() is called exactly once on launch when the user has opted in")
    func optedInLaunchTriggersSilentInstall() async throws {
        let stub = try await runStart(optedIn: true)
        let count = await stub.installCallCount
        #expect(count == 1)
    }

    /// The guard behind retaining the startup task at all: a reconfigured lifecycle must
    /// not hand a caller the previous run's chain to await. Every test here reconfigures
    /// before starting, so a stale task would make each one await the run before it —
    /// exercised implicitly across the suite, asserted directly here because the PR body
    /// claims it (raised in review by @april-clearwater).
    @Test("reconfiguring for a fresh start clears the retained startup task")
    func reconfiguringClearsTheRetainedStartupTask() async throws {
        _ = try await runStart(optedIn: false)
        #expect(ClaudeIntegrationLifecycle.shared.startupTask != nil)

        ClaudeIntegrationLifecycle.shared._configureForTesting(
            defaults: UserDefaults(suiteName: "wm-lifecycle-test-\(UUID().uuidString)")!,
            installerFactory: { _ in StubInstaller() },
            socketURLOverride: Self.ephemeralSocketURL()
        )
        #expect(ClaudeIntegrationLifecycle.shared.startupTask == nil)
    }

    @Test("install() is not called when the user has not opted in")
    func notOptedInLaunchDoesNotInstall() async throws {
        let stub = try await runStart(optedIn: false)
        let count = await stub.installCallCount
        #expect(count == 0)
    }

    /// Starts the singleton opted in with `installer` and waits for the startup chain, the
    /// launch repair included. `beforeStart` runs after reconfiguring, which clears state.
    private func runOptedInStart(
        installer: any ClaudeSettingsInstalling,
        beforeStart: () -> Void = {}
    ) async throws {
        let suiteName = "wm-lifecycle-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: ClaudeIntegrationDefaults.optedInKey)
        ClaudeIntegrationLifecycle.shared._configureForTesting(
            defaults: defaults,
            installerFactory: { _ in installer },
            socketURLOverride: Self.ephemeralSocketURL()
        )
        beforeStart()

        ClaudeIntegrationLifecycle.shared.start(registry: AgentSessionRegistry())
        let startup = try #require(ClaudeIntegrationLifecycle.shared.startupTask)
        await startup.value

        await ClaudeIntegrationLifecycle.shared.stop()
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    /// The failure the Agents status row shows as failed when nobody was looking: the silent
    /// repair at launch could not write the settings file.
    @Test("a launch repair that throws leaves its error text for the Agents status row")
    func failedLaunchRepairRecordsItsError() async throws {
        try await runOptedInStart(installer: RefusingInstaller())
        #expect(
            ClaudeIntegrationLifecycle.shared.lastInstallFailure
                == RefusingInstaller.WriteRefused().errorDescription
        )
    }

    @Test("a launch repair that succeeds clears an earlier install failure")
    func succeededLaunchRepairClearsTheFailure() async throws {
        try await runOptedInStart(installer: StubInstaller()) {
            ClaudeIntegrationLifecycle.shared.recordInstallFailure("an earlier attempt threw")
        }
        #expect(ClaudeIntegrationLifecycle.shared.lastInstallFailure == nil)
    }

    /// The ordering #1673's second review found: a refresh starts and reads the hooks as
    /// installed, a Try again fails while it is still reading, and the refresh lands last. The
    /// failure is newer than anything that refresh saw, so it stays; a refresh that starts after
    /// the failure can settle it.
    @Test("a refresh that started before an install failure cannot clear it")
    func staleRefreshCannotClearANewerFailure() throws {
        let suiteName = "wm-lifecycle-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let lifecycle = ClaudeIntegrationLifecycle.shared
        lifecycle._configureForTesting(defaults: defaults, installerFactory: { _ in StubInstaller() })

        let staleRefreshStart = lifecycle.installFailureCount
        lifecycle.recordInstallFailure("Try again threw")
        lifecycle.clearInstallFailure(ifRecordedBefore: staleRefreshStart)
        #expect(lifecycle.lastInstallFailure == "Try again threw")

        lifecycle.clearInstallFailure(ifRecordedBefore: lifecycle.installFailureCount)
        #expect(lifecycle.lastInstallFailure == nil)
    }

    /// The ordering #1673's third review found: the launch repair's install is still running when
    /// a Try again in Settings fails, and then the repair succeeds. The failure is newer than the
    /// install that started before it, so that success must not clear it. The time limit turns a
    /// startup chain that never reaches the install into a failure instead of a hang.
    @Test(
        "an install that started before a newer failure cannot clear it by succeeding",
        .timeLimit(.minutes(1))
    )
    func staleSuccessfulInstallCannotClearANewerFailure() async throws {
        let suiteName = "wm-lifecycle-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: ClaudeIntegrationDefaults.optedInKey)
        let installer = SuspendingInstaller()
        let lifecycle = ClaudeIntegrationLifecycle.shared
        lifecycle._configureForTesting(
            defaults: defaults,
            installerFactory: { _ in installer },
            socketURLOverride: Self.ephemeralSocketURL()
        )

        lifecycle.start(registry: AgentSessionRegistry())
        let startup = try #require(lifecycle.startupTask)
        await installer.waitUntilInstallStarts()
        lifecycle.recordInstallFailure("Try again threw")
        await installer.finishInstall()
        await startup.value
        await lifecycle.stop()

        #expect(await installer.isInstalled())
        #expect(lifecycle.lastInstallFailure == "Try again threw")
    }

    @Test("settings installer publishes after startup for Settings scene injection")
    func settingsInstallerPublishesAfterStartup() async throws {
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

        // The same signal the install-once tests await, for the same reason: publication
        // happens inside the startup chain, so the chain finishing is when there is
        // something to assert. The 15s poll this replaces was the last fixed deadline
        // left in the file and would flake the same way under starvation.
        let startup = try #require(ClaudeIntegrationLifecycle.shared.startupTask)
        await startup.value

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
