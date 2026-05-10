//
//  ClaudeSettingsInstallingProtocolTests.swift
//  WorkspaceManagerTests
//
//  Verifies the protocol surface the Settings → Agents view depends on. We can't
//  drive @AppStorage-backed SwiftUI views in a unit test target without a
//  snapshot framework, so we test the contract the view consumes: install()
//  is called exactly once per accept, isInstalled() reflects the new state,
//  and errors propagate cleanly.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("ClaudeSettingsInstalling")
struct ClaudeSettingsInstallingProtocolTests {

    actor StubInstaller: ClaudeSettingsInstalling {
        private(set) var installCallCount = 0
        private(set) var previewCallCount = 0
        var installed = false
        var failNextInstall = false
        let url = URL(fileURLWithPath: "/tmp/.claude/settings.json")

        func renderPreview() async throws -> String {
            previewCallCount += 1
            return "stub: would add 4 hooks"
        }

        func install() async throws {
            installCallCount += 1
            if failNextInstall {
                failNextInstall = false
                struct StubError: Error {}
                throw StubError()
            }
            installed = true
        }

        func isInstalled() async -> Bool { installed }
        func userSettingsURL() async -> URL { url }
        func mostRecentBackupPath() async -> String? {
            installed ? "\(url.path).workspaces-backup-stub" : nil
        }
        func userSettingsModificationDate() async -> Date? { nil }
    }

    @Test("Successful install calls install() exactly once and reflects installed state")
    func successfulInstall() async throws {
        let stub = StubInstaller()
        let preview = try await stub.renderPreview()
        #expect(preview.contains("stub:"))
        let installedBefore = await stub.isInstalled()
        #expect(installedBefore == false)

        try await stub.install()
        let count = await stub.installCallCount
        let installedAfter = await stub.isInstalled()
        #expect(count == 1)
        #expect(installedAfter == true)

        let backup = await stub.mostRecentBackupPath()
        #expect(backup?.contains("workspaces-backup-") == true)
    }

    @Test("Failure during install does not flip installed state")
    func installFailure() async throws {
        let stub = StubInstaller()
        await stub.setFailNextInstall(true)
        await #expect(throws: (any Error).self) {
            try await stub.install()
        }
        let installed = await stub.isInstalled()
        #expect(installed == false)
        let count = await stub.installCallCount
        #expect(count == 1)
    }

    @Test("Live installer round-trips against a tmp home")
    func liveInstallerRoundTrip() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-live-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = ClaudeSettingsInstaller(homeDirectory: home)
        await installer.register(workspacesHooksContribution(eventForwarderScriptPath: "/tmp/event-forwarder.sh"))
        let beforeInstall = await installer.isInstalled()
        #expect(beforeInstall == false)
        let backupBefore = await installer.mostRecentBackupPath()
        #expect(backupBefore == nil)

        try await installer.install()
        let afterInstall = await installer.isInstalled()
        #expect(afterInstall == true)

        let installedData = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        let installedJSON = try JSONSerialization.jsonObject(with: installedData) as? [String: Any] ?? [:]
        let hooks = installedJSON["hooks"] as? [String: Any] ?? [:]
        let notification = hooks["Notification"] as? [[String: Any]] ?? []
        #expect(notification.count == 1)
        let notificationHandlers = notification.first?["hooks"] as? [[String: Any]] ?? []
        #expect(notificationHandlers.count == 1)
        #expect(notificationHandlers.first?["type"] as? String == "command")
        #expect(notificationHandlers.first?["command"] as? String == "/tmp/event-forwarder.sh")

        // No backup is recorded for a freshly created file (nothing to back up).
        // Pre-seed an existing settings file and re-install to exercise the backup path.
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        try Data("{\"theme\":\"dark\"}".utf8).write(to: settingsURL)

        let installer2 = ClaudeSettingsInstaller(homeDirectory: home)
        await installer2.register(workspacesHooksContribution(eventForwarderScriptPath: "/tmp/event-forwarder.sh"))
        try await installer2.install()
        let backupAfter = await installer2.mostRecentBackupPath()
        #expect(backupAfter?.contains("workspaces-backup-") == true)
    }
}

extension ClaudeSettingsInstallingProtocolTests.StubInstaller {
    func setFailNextInstall(_ value: Bool) {
        self.failNextInstall = value
    }
}
