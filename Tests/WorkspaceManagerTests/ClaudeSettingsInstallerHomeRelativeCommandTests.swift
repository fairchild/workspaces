//
//  ClaudeSettingsInstallerHomeRelativeCommandTests.swift
//  WorkspaceManagerTests
//
//  Verifies the installer emits machine-agnostic, tilde-relative, unquoted hook
//  and status-line commands, and migrates opted-in users off the older
//  machine-specific absolute paths. Keeping committed-form == runtime-form is what
//  stops `~/.claude` from going dirty and silently skipping the auto-deploy.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("ClaudeSettingsInstaller home-relative command")
struct ClaudeSettingsInstallerHomeRelativeCommandTests {
    private static let eventForwarderRelative =
        ".local/share/workspaces/hook-forwarders/event-forwarder.sh"
    private static let statusLineRelative =
        ".local/share/workspaces/hook-forwarders/statusline.sh"
    private static let expectedEventCommand =
        "~/.local/share/workspaces/hook-forwarders/event-forwarder.sh"
    private static let expectedStatusCommand =
        "~/.local/share/workspaces/hook-forwarders/statusline.sh"

    private func makeTempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-tilde-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func installer(home: URL) -> ClaudeSettingsInstaller {
        ClaudeSettingsInstaller(
            homeDirectory: home,
            eventForwarderScriptPath:
                home.appendingPathComponent(Self.eventForwarderRelative).path,
            statusLineForwarderPath:
                home.appendingPathComponent(Self.statusLineRelative).path
        )
    }

    private func settingsURL(home: URL) -> URL {
        home.appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private func seedSettings(_ object: [String: Any], home: URL) throws {
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
            .write(to: settingsURL(home: home))
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func eventHandlers(in updated: [String: Any], event: String) -> [[String: Any]] {
        let hooks = updated["hooks"] as? [String: Any] ?? [:]
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    }

    private func eventCommands(in updated: [String: Any], event: String) -> [String] {
        eventHandlers(in: updated, event: event).compactMap { $0["command"] as? String }
    }

    @Test("Emitted event-forwarder command is the tilde path with no leading /Users and no quotes")
    func emitsTildeEventCommand() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = installer(home: home)
        try await installer.install()

        let updated = try readJSON(settingsURL(home: home))
        let commands = eventCommands(in: updated, event: "Stop")
        #expect(commands.contains(Self.expectedEventCommand))
        #expect(commands.allSatisfy { !$0.hasPrefix("/Users/") })
        #expect(commands.allSatisfy { !$0.hasPrefix("'") })
    }

    @Test("Emitted statusLine command is the tilde path, unquoted")
    func emitsTildeStatusLineCommand() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = installer(home: home)
        try await installer.install()

        let block = try readJSON(settingsURL(home: home))["statusLine"] as? [String: Any] ?? [:]
        #expect(block["command"] as? String == Self.expectedStatusCommand)
    }

    @Test("Installing twice is byte-identical and reports isInstalled")
    func idempotentNoDrift() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = installer(home: home)
        try await installer.install()
        let first = try Data(contentsOf: settingsURL(home: home))
        try await installer.install()
        let second = try Data(contentsOf: settingsURL(home: home))

        #expect(first == second)
        #expect(await installer.isInstalled())
    }

    @Test("Settings already carrying the generic command report isInstalled without a write")
    func preinstalledGenericCommandIsClean() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Produce the canonical file once, then assert a fresh installer sees it
        // as already-installed (the property that keeps the dotclaude tree clean).
        try await installer(home: home).install()
        let canonical = try Data(contentsOf: settingsURL(home: home))

        let fresh = installer(home: home)
        #expect(await fresh.isInstalled())
        #expect(try Data(contentsOf: settingsURL(home: home)) == canonical)
    }

    @Test("Migrates quoted and unquoted Application Support event-forwarder paths to the tilde command")
    func migratesLegacyApplicationSupportPaths() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let unquoted =
            "/Users/test/Library/Application Support/com.cloudcompute.workspaces/HookForwarders/event-forwarder.sh"
        let quoted = "'\(unquoted)'"
        try seedSettings(
            [
                "hooks": [
                    "PreToolUse": [
                        ["hooks": [["type": "command", "command": quoted, "async": true]]]
                    ],
                    "Stop": [
                        ["hooks": [["type": "command", "command": unquoted, "async": true]]]
                    ],
                ]
            ],
            home: home
        )

        let installer = installer(home: home)
        try await installer.install()

        let updated = try readJSON(settingsURL(home: home))
        for event in ["PreToolUse", "Stop"] {
            let commands = eventCommands(in: updated, event: event)
            #expect(commands.contains(Self.expectedEventCommand))
            #expect(commands.contains(quoted) == false)
            #expect(commands.contains(unquoted) == false)
        }
        #expect(await installer.isInstalled())
    }

    @Test("Migrates a stale .build bundle statusline path to the tilde command")
    func migratesLegacyBuildStatusLinePath() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let buildStatusLine =
            "/Users/fairchild/.codex/worktrees/6954/.build/arm64-apple-macosx/debug/WorkspaceManager_WorkspaceManager.bundle/HookForwarders/statusline.sh"
        try seedSettings(
            ["statusLine": ["type": "command", "command": buildStatusLine, "refreshInterval": 5000]],
            home: home
        )

        let installer = installer(home: home)
        try await installer.install()

        let block = try readJSON(settingsURL(home: home))["statusLine"] as? [String: Any] ?? [:]
        #expect(block["command"] as? String == Self.expectedStatusCommand)
        #expect(await installer.isInstalled())
    }

    @Test("Preserves a user-owned event-forwarder.sh outside the HookForwarders convention")
    func preservesUnrelatedUserForwarder() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let userHook = "/Users/test/bin/event-forwarder.sh"
        try seedSettings(
            [
                "hooks": [
                    "Stop": [
                        ["hooks": [["type": "command", "command": userHook, "async": true]]]
                    ]
                ]
            ],
            home: home
        )

        let installer = installer(home: home)
        try await installer.install()

        let commands = eventCommands(in: try readJSON(settingsURL(home: home)), event: "Stop")
        #expect(commands.contains(userHook))
        #expect(commands.contains(Self.expectedEventCommand))
    }
}
