//
//  ClaudeSettingsInstallerConversationObserverTests.swift
//  WorkspaceManagerTests
//
//  The conversation observer joins every Claude session's SessionStart beside the event
//  forwarder, so these pin that the installer adds exactly one, async, leaves the
//  forwarder and the person's own hooks alone, and replaces an observer from elsewhere.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("ClaudeSettingsInstaller conversation observer")
struct ClaudeSettingsInstallerConversationObserverTests {
    private let eventForwarder = "/tmp/event-forwarder.sh"
    private let observer = "/tmp/hook-forwarders/conversation-observer.sh"

    private func withHome(_ body: (URL) async throws -> Void) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-observer-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try await body(home)
    }

    private func installer(home: URL) -> ClaudeSettingsInstaller {
        ClaudeSettingsInstaller(
            homeDirectory: home,
            eventForwarderScriptPath: eventForwarder,
            conversationObserverScriptPath: observer
        )
    }

    private func sessionStartHandlers(home: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        let settings = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = (settings["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    }

    @Test("Install adds one async SessionStart observer beside the forwarder and the person's own hook")
    func addsOneAsyncObserver() async throws {
        try await withHome { home in
            let mine: [String: Any] = [
                "hooks": ["SessionStart": [["hooks": [["type": "command", "command": "/usr/local/bin/mine"]]]]]
            ]
            try JSONSerialization.data(withJSONObject: mine).write(
                to: home.appendingPathComponent(".claude/settings.json"))

            let installer = installer(home: home)
            try await installer.install()
            try await installer.install()

            let handlers = try sessionStartHandlers(home: home)
            let observers = handlers.filter { $0["command"] as? String == observer }
            #expect(observers.count == 1)
            #expect(observers.first?["async"] as? Bool == true)
            #expect(handlers.contains { $0["command"] as? String == eventForwarder })
            #expect(handlers.contains { $0["command"] as? String == "/usr/local/bin/mine" })
            #expect(await installer.isInstalled())
        }
    }

    @Test("An observer extracted somewhere else is replaced, not run twice")
    func staleObserverIsReplaced() async throws {
        try await withHome { home in
            let stale: [String: Any] = [
                "hooks": [
                    "SessionStart": [
                        [
                            "hooks": [
                                ["type": "command", "command": "'/old place/conversation-observer.sh'", "async": true]
                            ]
                        ]
                    ]
                ]
            ]
            try JSONSerialization.data(withJSONObject: stale).write(
                to: home.appendingPathComponent(".claude/settings.json"))

            let installer = installer(home: home)
            #expect(try await installer.renderPreview().contains("replace an earlier conversation observer command"))
            try await installer.install()

            let commands = try sessionStartHandlers(home: home).compactMap { $0["command"] as? String }
            #expect(
                commands.filter {
                    $0.hasSuffix("conversation-observer.sh") || $0.hasSuffix("conversation-observer.sh'")
                } == [observer])
        }
    }

    @Test("The observer's command without async is not installed until it runs async")
    func synchronousObserverIsMadeAsync() async throws {
        try await withHome { home in
            let synchronous: [String: Any] = [
                "hooks": [
                    "SessionStart": [
                        ["hooks": [["type": "command", "command": observer, "async": false, "timeout": 5]]],
                        ["hooks": [["type": "command", "command": observer]]],
                    ]
                ]
            ]
            try JSONSerialization.data(withJSONObject: synchronous).write(
                to: home.appendingPathComponent(".claude/settings.json"))

            let installer = installer(home: home)
            #expect(await !installer.isInstalled())
            try await installer.install()

            let observers = try sessionStartHandlers(home: home).filter { $0["command"] as? String == observer }
            #expect(observers.count == 1)
            #expect(observers.first?["async"] as? Bool == true)
            #expect(await installer.isInstalled())
        }
    }

    @Test("Without an observer path the installer writes no observer")
    func noObserverPathWritesNone() async throws {
        try await withHome { home in
            try await ClaudeSettingsInstaller(homeDirectory: home, eventForwarderScriptPath: eventForwarder).install()
            let commands = try sessionStartHandlers(home: home).compactMap { $0["command"] as? String }
            #expect(commands == [eventForwarder])
        }
    }
}
