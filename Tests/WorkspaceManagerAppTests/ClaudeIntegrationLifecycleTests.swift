//
//  ClaudeIntegrationLifecycleTests.swift
//  WorkspaceManagerAppTests
//
//  Verifies the silent-reinstall behaviour the lifecycle uses to keep
//  ~/.claude/settings.json pointed at the live (pid-scoped) socket on every
//  cold start once the user has opted in. Defect 1 from the round-2 review.
//

import Combine
import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("ClaudeIntegrationLifecycle silent reinstall", .serialized)
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
            installerFactory: { _ in stub }
        )

        let registry = AgentSessionRegistry()
        ClaudeIntegrationLifecycle.shared.start(registry: registry)

        // Wait for the lifecycle's startup Task chain to complete. The chain awaits
        // `listener.socketPath`, then calls install(), then starts the listener.
        // Polling for installCallCount or a timeout is sufficient.
        let deadline = Date().addingTimeInterval(2.0)
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
            installerFactory: { _ in stub }
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

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if didPublishInstaller { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        await ClaudeIntegrationLifecycle.shared.stop()
        UserDefaults().removePersistentDomain(forName: suiteName)
        _ = cancellable

        #expect(didPublishInstaller)
    }
}
