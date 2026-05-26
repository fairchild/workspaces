//
//  HookForwarderScriptTests.swift
//  WorkspaceManagerTests
//
//  Executes the bundled Claude Code shell forwarders against a real
//  AgentHookListener socket. This protects the bash + curl boundary that unit
//  tests of the listener alone cannot cover.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Hook forwarder scripts", .serialized)
struct HookForwarderScriptTests {
    private static func makeTempSocketURL() -> URL {
        URL(fileURLWithPath: "/tmp/wm-fwd-\(UUID().uuidString.prefix(8)).sock")
    }

    private static func hookForwarder(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WorkspaceManager/Resources/HookForwarders/\(name)")
    }

    private static func runForwarder(
        named name: String,
        stdin: Data,
        socket: URL,
        hostSessionID: UUID
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [hookForwarder(named: name).path]
        var environment = ProcessInfo.processInfo.environment
        environment["WORKSPACES_HOOKS_SOCKET"] = socket.path
        environment["WORKSPACES_HOST_SESSION_ID"] = hostSessionID.uuidString
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        try process.run()
        try input.fileHandleForWriting.write(contentsOf: stdin)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private static func runZshCommandStatusHook(
        socket: URL,
        hostSessionID: UUID
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-f",
            "-c",
            """
            source "$WORKSPACES_COMMAND_STATUS_ZSH"
            __workspaces_command_status_preexec "false"
            false
            __workspaces_command_status_precmd
            """,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["WORKSPACES_HOOKS_SOCKET"] = socket.path
        environment["WORKSPACES_HOST_SESSION_ID"] = hostSessionID.uuidString
        environment["WORKSPACES_COMMAND_STATUS_ZSH"] = hookForwarder(named: "command-status.zsh").path
        process.environment = environment

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    @Test("event-forwarder posts hook JSON with host-session header")
    @MainActor
    func eventForwarderPostsHookJSONWithHostSessionHeader() async throws {
        let socket = Self.makeTempSocketURL()
        let registry = AgentSessionRegistry()
        let hostSessionID = UUID()
        registry.register(hostSessionID: hostSessionID, cwd: "/tmp", kind: .claudeCode)
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }

        let payload: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "script-session",
            "cwd": "/tmp",
        ]
        let result = try Self.runForwarder(
            named: "event-forwarder.sh",
            stdin: try JSONSerialization.data(withJSONObject: payload),
            socket: socket,
            hostSessionID: hostSessionID
        )

        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
        let reached = await waitUntil {
            await MainActor.run {
                registry.statuses[hostSessionID]?.agentSessionID == "script-session"
            }
        }
        #expect(reached)
    }

    @Test("statusline forwarder posts status JSON and keeps terminal row empty")
    @MainActor
    func statusLineForwarderPostsStatusJSONWithHostSessionHeader() async throws {
        let socket = Self.makeTempSocketURL()
        let registry = AgentSessionRegistry()
        let hostSessionID = UUID()
        registry.register(hostSessionID: hostSessionID, cwd: "/tmp", kind: .claudeCode)
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }

        let payload: [String: Any] = [
            "model": ["display_name": "Claude Sonnet 4.5"],
            "workspace": ["current_dir": "/tmp"],
            "cost": ["total_cost_usd": 0.42],
        ]
        let result = try Self.runForwarder(
            named: "statusline.sh",
            stdin: try JSONSerialization.data(withJSONObject: payload),
            socket: socket,
            hostSessionID: hostSessionID
        )

        #expect(result.status == 0)
        #expect(result.stdout == " ")
        #expect(result.stderr.isEmpty)
        let reached = await waitUntil {
            await MainActor.run {
                registry.statuses[hostSessionID]?.modelDisplayName == "Claude Sonnet 4.5"
            }
        }
        #expect(reached)
        #expect(registry.statuses[hostSessionID]?.costUSD == 0.42)
    }

    @Test("command-status zsh hook posts command markers with host-session header")
    @MainActor
    func commandStatusZshHookPostsCommandMarkersWithHostSessionHeader() async throws {
        let socket = Self.makeTempSocketURL()
        let registry = AgentSessionRegistry()
        let commandStatusRegistry = LastCommandStatusRegistry()
        let hostSessionID = UUID()
        registry.register(hostSessionID: hostSessionID, cwd: "/tmp", kind: .claudeCode)
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            commandStatusRegistry: commandStatusRegistry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }

        let result = try Self.runZshCommandStatusHook(
            socket: socket,
            hostSessionID: hostSessionID
        )

        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        let reached = await waitUntil {
            await MainActor.run {
                commandStatusRegistry.statusByTerminalSession[hostSessionID]?.exitCode == 1
            }
        }
        #expect(reached)
        #expect(commandStatusRegistry.statusByTerminalSession[hostSessionID]?.isSuccess == false)
    }
}
