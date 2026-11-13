//
//  ClaudeSettingsInstallerConversationObserverTests.swift
//  WorkspaceManagerTests
//
//  The conversation observer joins every Claude session's SessionStart beside the event
//  forwarder, so these pin that the installer adds exactly one, async, while its script is
//  there, removes its own when the script is gone, and leaves the forwarder and every
//  handler a person wrote alone, including ones that run a script of the same name.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("ClaudeSettingsInstaller conversation observer")
struct ClaudeSettingsInstallerConversationObserverTests {
    private let eventForwarder = "/tmp/event-forwarder.sh"
    /// The command the installer writes for the extracted observer: home-relative.
    private let observerCommand = "~/.local/share/workspaces/hook-forwarders/conversation-observer.sh"

    private struct Home {
        let url: URL
        var observer: URL {
            url.appendingPathComponent(".local/share/workspaces/hook-forwarders/conversation-observer.sh")
        }

        func extractObserver() throws {
            try FileManager.default.createDirectory(
                at: observer.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: observer)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: observer.path)
        }

        func writeSettings(_ settings: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: settings).write(
                to: url.appendingPathComponent(".claude/settings.json"))
        }
    }

    private func withHome(extracted: Bool = true, _ body: (Home) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-observer-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let home = Home(url: url)
        if extracted { try home.extractObserver() }
        try await body(home)
    }

    private func installer(home: Home) -> ClaudeSettingsInstaller {
        ClaudeSettingsInstaller(
            homeDirectory: home.url,
            eventForwarderScriptPath: eventForwarder,
            conversationObserverScriptPath: home.observer.path
        )
    }

    private func sessionStartHandlers(home: Home) throws -> [[String: Any]] {
        let data = try Data(contentsOf: home.url.appendingPathComponent(".claude/settings.json"))
        let settings = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = (settings["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    }

    private static func sessionStart(_ commands: [String]) -> [String: Any] {
        ["hooks": ["SessionStart": commands.map { ["hooks": [["type": "command", "command": $0, "async": true]]] }]]
    }

    @Test("Install adds one async SessionStart observer beside the forwarder and the person's own hook")
    func addsOneAsyncObserver() async throws {
        try await withHome { home in
            try home.writeSettings(Self.sessionStart(["/usr/local/bin/mine"]))

            let installer = installer(home: home)
            try await installer.install()
            try await installer.install()

            let handlers = try sessionStartHandlers(home: home)
            let observers = handlers.filter { $0["command"] as? String == observerCommand }
            #expect(observers.count == 1)
            #expect(observers.first?["async"] as? Bool == true)
            #expect(handlers.contains { $0["command"] as? String == eventForwarder })
            #expect(handlers.contains { $0["command"] as? String == "/usr/local/bin/mine" })
            #expect(await installer.isInstalled())
        }
    }

    @Test("A person's handler that runs a script of the same name, plain or wrapped, is theirs")
    func sameNamedUserHandlersSurvive() async throws {
        for extracted in [true, false] {
            try await withHome(extracted: extracted) { home in
                let mine = home.url.appendingPathComponent("my-hooks/conversation-observer.sh")
                try FileManager.default.createDirectory(
                    at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("#!/bin/sh\n".utf8).write(to: mine)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mine.path)
                let theirs = [
                    mine.path, "/bin/bash \(mine.path)", "'/old place/conversation-observer.sh'",
                    "/nowhere/conversation-observer.sh",
                ]
                try home.writeSettings(Self.sessionStart(theirs))

                try await installer(home: home).install()

                let commands = try sessionStartHandlers(home: home).compactMap { $0["command"] as? String }
                #expect(theirs.allSatisfy(commands.contains))
                #expect(commands.contains(observerCommand) == extracted)
            }
        }
    }

    @Test("The observer's own handler whose script is gone reads as not installed, and install removes it")
    func missingObserverScriptIsRemoved() async throws {
        try await withHome(extracted: false) { home in
            try home.writeSettings(Self.sessionStart([observerCommand, "/usr/local/bin/mine"]))
            let installer = installer(home: home)

            #expect(await !installer.isInstalled())
            #expect(try await installer.renderPreview().contains("remove the conversation observer"))
            try await installer.install()

            let commands = try sessionStartHandlers(home: home).compactMap { $0["command"] as? String }
            #expect(commands == ["/usr/local/bin/mine", eventForwarder])
            #expect(await installer.isInstalled())
        }
    }

    @Test("The observer's command without async is not installed until it runs async")
    func synchronousObserverIsMadeAsync() async throws {
        try await withHome { home in
            try home.writeSettings([
                "hooks": [
                    "SessionStart": [
                        ["hooks": [["type": "command", "command": observerCommand, "async": false, "timeout": 5]]],
                        ["hooks": [["type": "command", "command": observerCommand]]],
                    ]
                ]
            ])

            let installer = installer(home: home)
            #expect(await !installer.isInstalled())
            try await installer.install()

            let observers = try sessionStartHandlers(home: home).filter {
                $0["command"] as? String == observerCommand
            }
            #expect(observers.count == 1)
            #expect(observers.first?["async"] as? Bool == true)
            #expect(await installer.isInstalled())
        }
    }

    @Test("Without an observer path the installer writes no observer")
    func noObserverPathWritesNone() async throws {
        try await withHome { home in
            try await ClaudeSettingsInstaller(homeDirectory: home.url, eventForwarderScriptPath: eventForwarder)
                .install()
            let commands = try sessionStartHandlers(home: home).compactMap { $0["command"] as? String }
            #expect(commands == [eventForwarder])
        }
    }
}
