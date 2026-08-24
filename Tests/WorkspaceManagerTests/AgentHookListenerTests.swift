// swift-format-ignore-file: NeverForceUnwrap
// Test fixtures/helpers force-unwrap known-good literals or generator output; a failure here is a loud test crash, not a user-facing risk.
//
//  AgentHookListenerTests.swift
//  WorkspaceManagerTests
//
//  Round-trip tests for the AgentHookListener: spin up a listener on a tmp Unix
//  socket, POST hook-event JSON via `curl --unix-socket`, assert registry
//  transitions.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("AgentHookListener", .serialized)
struct AgentHookListenerTests {

    private static func makeTempSocketURL() -> URL {
        // Unix socket paths must fit in 104 chars on macOS — keep this short.
        let dir = URL(fileURLWithPath: "/tmp")
        let name = "wm-hook-\(UUID().uuidString.prefix(8)).sock"
        return dir.appendingPathComponent(name)
    }

    private static func curlPost(
        socket: URL,
        path: String,
        body: Data,
        hostSessionID: UUID? = nil
    ) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var arguments = [
            "--silent",
            "--show-error",
            "--unix-socket", socket.path,
            "-X", "POST",
            "-H", "Content-Type: application/json",
        ]
        if let hostSessionID {
            arguments.append(contentsOf: [
                "-H", "X-WorkSpaces-Host-Session-ID: \(hostSessionID.uuidString)",
            ])
        }
        arguments.append(contentsOf: [
            "--data-binary", "@-",
            "http://localhost\(path)",
        ])
        process.arguments = arguments
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return -1
        }
        try? stdin.fileHandleForWriting.write(contentsOf: body)
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func osc133(_ payload: String) -> Data {
        var data = Data([0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B])
        data.append(payload.data(using: .utf8)!)
        data.append(0x07)
        return data
    }

    @MainActor
    private final class TestRegistry: AgentSessionRegistryProtocol {
        var statuses: [UUID: AgentSessionStatus] = [:]
        let underlying = AgentSessionRegistry()
        let registeredID: UUID
        let cwd: String

        init(cwd: String) {
            self.cwd = cwd
            self.registeredID = UUID()
            underlying.register(hostSessionID: registeredID, cwd: cwd, kind: .claudeCode)
            statuses = underlying.statuses
        }

        func register(hostSessionID: UUID, cwd: String, kind: AgentKind) {
            underlying.register(hostSessionID: hostSessionID, cwd: cwd, kind: kind)
            statuses = underlying.statuses
        }

        var appliedBatches: [(events: [AgentEvent], origin: AgentEventOrigin)] = []

        func apply(events: [AgentEvent], for hostSessionID: UUID, origin: AgentEventOrigin) {
            appliedBatches.append((events, origin))
            underlying.apply(events: events, for: hostSessionID, origin: origin)
            statuses = underlying.statuses
        }

        func deregister(hostSessionID: UUID) {
            underlying.deregister(hostSessionID: hostSessionID)
            statuses = underlying.statuses
        }
    }

    @Test("Healthz returns 200 OK")
    func healthz() async throws {
        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: "/tmp")
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }

        try await Task.sleep(nanoseconds: 250_000_000)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--silent", "--unix-socket", socket.path,
            "http://localhost/healthz",
        ]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text == "OK")

        await listener.stop()
    }

    @Test("SessionStart hook ingest binds agent session id and stays idle")
    func sessionStartIngest() async throws {
        let cwd = "/tmp/hook-test-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: cwd)
        let registeredID = registry.registeredID
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let body: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "abc-123",
            "cwd": cwd,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let status = await Self.curlPost(
            socket: socket, path: "/event", body: data, hostSessionID: registeredID)
        #expect(status == 0)

        let bound = await waitUntil {
            await MainActor.run { registry.statuses[registeredID]?.agentSessionID == "abc-123" }
        }
        #expect(bound)
        let registryStatus = await registry.statuses[registeredID]
        #expect(registryStatus?.agentSessionID == "abc-123")
        #expect(registryStatus?.run == .idle)
        #expect(registryStatus?.hookActive == true)

        await listener.stop()
    }

    @Test("PreToolUse → runningTool, PostToolUse → thinking, Stop → complete")
    func toolLifecycleIngest() async throws {
        let cwd = "/tmp/hook-test-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: cwd)
        let registeredID = registry.registeredID
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let common: [String: Any] = ["session_id": "s1", "cwd": cwd]

        var preBody = common
        preBody["hook_event_name"] = "PreToolUse"
        preBody["tool_name"] = "Read"
        preBody["tool_input"] = ["file_path": "/tmp/x.swift"]
        let preData = try JSONSerialization.data(withJSONObject: preBody)
        _ = await Self.curlPost(
            socket: socket, path: "/event", body: preData, hostSessionID: registeredID)
        let preReached = await waitUntil {
            await MainActor.run {
                if case .runningTool = registry.statuses[registeredID]?.run { return true }
                return false
            }
        }
        #expect(preReached)
        if case .runningTool(let name, let detail) = await registry.statuses[registeredID]?.run {
            #expect(name == "Read")
            #expect(detail == "/tmp/x.swift")
        } else {
            Issue.record("expected runningTool")
        }

        var postBody = common
        postBody["hook_event_name"] = "PostToolUse"
        postBody["tool_name"] = "Read"
        postBody["duration_ms"] = 5
        let postData = try JSONSerialization.data(withJSONObject: postBody)
        _ = await Self.curlPost(
            socket: socket, path: "/event", body: postData, hostSessionID: registeredID)
        let postReached = await waitUntil {
            await MainActor.run { registry.statuses[registeredID]?.run == .thinking }
        }
        #expect(postReached)

        var stopBody = common
        stopBody["hook_event_name"] = "Stop"
        let stopData = try JSONSerialization.data(withJSONObject: stopBody)
        _ = await Self.curlPost(
            socket: socket, path: "/event", body: stopData, hostSessionID: registeredID)
        let stopReached = await waitUntil {
            await MainActor.run { registry.statuses[registeredID]?.run == .complete }
        }
        #expect(stopReached)

        await listener.stop()
    }

    @Test("PermissionRequest and Notification(permission_prompt) drive awaitingInput")
    func permissionFlow() async throws {
        let cwd = "/tmp/hook-test-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: cwd)
        let registeredID = registry.registeredID
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let body: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "s",
            "cwd": cwd,
            "tool_name": "Bash",
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = await Self.curlPost(
            socket: socket, path: "/event", body: data, hostSessionID: registeredID)
        let reached = await waitUntil {
            await MainActor.run {
                if case .awaitingInput(.permissionPrompt) = registry.statuses[registeredID]?.run {
                    return true
                }
                return false
            }
        }
        #expect(reached)

        await listener.stop()
    }

    @Test("StopFailure with rate_limit → errored(rateLimit)")
    func stopFailureRateLimit() async throws {
        let cwd = "/tmp/hook-test-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: cwd)
        let registeredID = registry.registeredID
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let body: [String: Any] = [
            "hook_event_name": "StopFailure",
            "session_id": "s",
            "cwd": cwd,
            "error": "rate limit hit",
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = await Self.curlPost(
            socket: socket, path: "/event", body: data, hostSessionID: registeredID)
        let reached = await waitUntil {
            await MainActor.run {
                if case .errored = registry.statuses[registeredID]?.run { return true }
                return false
            }
        }
        #expect(reached)
        if case .errored(let category, _) = await registry.statuses[registeredID]?.run {
            #expect(category == .rateLimit)
        } else {
            Issue.record("expected errored")
        }

        await listener.stop()
    }

    @Test("PostToolUseFailure routes to errored(toolFailure)")
    func postToolUseFailure() async throws {
        let cwd = "/tmp/hook-test-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: cwd)
        let registeredID = registry.registeredID
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let body: [String: Any] = [
            "hook_event_name": "PostToolUseFailure",
            "session_id": "s",
            "cwd": cwd,
            "tool_name": "Bash",
            "error": "exit 1",
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = await Self.curlPost(
            socket: socket, path: "/event", body: data, hostSessionID: registeredID)
        let reached = await waitUntil {
            await MainActor.run {
                if case .errored = registry.statuses[registeredID]?.run { return true }
                return false
            }
        }
        #expect(reached)
        if case .errored(let category, _) = await registry.statuses[registeredID]?.run {
            #expect(category == .toolFailure)
        } else {
            Issue.record("expected errored")
        }

        await listener.stop()
    }

    @Test("UserPromptSubmit drives thinking")
    func userPromptSubmit() async throws {
        let cwd = "/tmp/hook-test-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: cwd)
        let registeredID = registry.registeredID
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let body: [String: Any] = [
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s",
            "cwd": cwd,
            "prompt": "hello",
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = await Self.curlPost(
            socket: socket, path: "/event", body: data, hostSessionID: registeredID)
        let reached = await waitUntil {
            await MainActor.run { registry.statuses[registeredID]?.run == .thinking }
        }
        #expect(reached)

        await listener.stop()
    }

    @Test("statusline POST updates registry status fields by host session header")
    func statusLineUpdatesByCwd() async throws {
        let cwd = "/tmp/hook-test-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: cwd)
        let registeredID = registry.registeredID
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let body: [String: Any] = [
            "model": ["id": "claude-sonnet", "display_name": "Claude Sonnet 4.5"],
            "workspace": ["current_dir": cwd],
            "cost": ["total_cost_usd": 0.123],
            "context_window": ["used_percentage": 12.5, "context_window_size": 200_000],
            "rate_limits": [
                "five_hour": [
                    "used_percentage": 33.3,
                    "resets_at": "2026-05-07T20:00:00Z",
                ]
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let status = await Self.curlPost(
            socket: socket, path: "/statusline", body: data, hostSessionID: registeredID)
        #expect(status == 0)

        let reached = await waitUntil {
            await MainActor.run {
                registry.statuses[registeredID]?.modelDisplayName == "Claude Sonnet 4.5"
            }
        }
        #expect(reached)
        let live = await registry.statuses[registeredID]
        #expect(live?.contextUsedPercent == 12.5)
        #expect(live?.fiveHourLimitUsedPercent == 33.3)
        #expect(live?.costUSD == 0.123)
        #expect(live?.fiveHourLimitResetsAt != nil)
        // Status-line ticks must NOT change the run state.
        #expect(live?.run == .idle)

        await listener.stop()
    }

    @Test("statusline POST uses host session header even when cwd and agent id drift")
    func statusLineResolvesByAgentSessionID() async throws {
        let cwd = "/tmp/hook-test-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: cwd)
        let registeredID = registry.registeredID
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let bind: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "session-xyz",
            "cwd": cwd,
        ]
        _ = await Self.curlPost(
            socket: socket, path: "/event",
            body: try JSONSerialization.data(withJSONObject: bind),
            hostSessionID: registeredID
        )
        let bound = await waitUntil {
            await MainActor.run {
                registry.statuses[registeredID]?.agentSessionID == "session-xyz"
            }
        }
        #expect(bound)

        let body: [String: Any] = [
            "session_id": "session-xyz",
            "workspace": ["current_dir": "/some/other/path"],
            "model": ["display_name": "Sonnet"],
            "cost": ["total_cost_usd": 0.01],
        ]
        _ = await Self.curlPost(
            socket: socket, path: "/statusline",
            body: try JSONSerialization.data(withJSONObject: body),
            hostSessionID: registeredID
        )

        let reached = await waitUntil {
            await MainActor.run { registry.statuses[registeredID]?.modelDisplayName == "Sonnet" }
        }
        #expect(reached)
        let live = await registry.statuses[registeredID]
        #expect(live?.costUSD == 0.01)

        await listener.stop()
    }

    @Test("statusline POST with no matching session is dropped without crashing")
    func statusLineNoMatchingSession() async throws {
        let cwd = "/tmp/hook-test-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: cwd)
        let registeredID = registry.registeredID
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let runBefore = await registry.statuses[registeredID]?.modelDisplayName

        let body: [String: Any] = [
            "session_id": "unknown-session-id",
            "workspace": ["current_dir": "/somewhere/else"],
            "model": ["display_name": "Should not apply"],
        ]
        let posted = await Self.curlPost(
            socket: socket, path: "/statusline",
            body: try JSONSerialization.data(withJSONObject: body),
            hostSessionID: UUID()
        )
        #expect(posted == 0)

        try await Task.sleep(nanoseconds: 300_000_000)
        let runAfter = await registry.statuses[registeredID]?.modelDisplayName
        #expect(runAfter == runBefore)

        await listener.stop()
    }

    @Test("command-markers POST updates last command status by host session header")
    func commandMarkersUpdateLastCommandStatusByHostSessionHeader() async throws {
        let cwd = "/tmp/hook-test-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: cwd)
        let registeredID = registry.registeredID
        await MainActor.run {
            registry.register(hostSessionID: UUID(), cwd: "/tmp/other", kind: .claudeCode)
        }
        let commandStatusRegistry = await MainActor.run { LastCommandStatusRegistry() }
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            commandStatusRegistry: commandStatusRegistry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        var body = Data()
        body.append(Self.osc133("B"))
        body.append(Self.osc133("D;7"))
        let status = await Self.curlPost(
            socket: socket,
            path: "/command-markers",
            body: body,
            hostSessionID: registeredID
        )
        #expect(status == 0)

        let reached = await waitUntil {
            await MainActor.run {
                commandStatusRegistry.statusByTerminalSession[registeredID]?.exitCode == 7
            }
        }
        #expect(reached)
        let live = await MainActor.run {
            commandStatusRegistry.statusByTerminalSession[registeredID]
        }
        #expect(live?.isRunning == false)
        #expect(live?.isSuccess == false)

        let stats = await listener.currentStatistics()
        #expect(stats.commandMarkerUpdates == 1)

        await listener.stop()
    }

    @Test("command-markers POST preserves start/end order across separate requests")
    func commandMarkersPreserveOrderAcrossSeparateRequests() async throws {
        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: "/tmp")
        let registeredID = registry.registeredID
        let commandStatusRegistry = await MainActor.run { LastCommandStatusRegistry() }
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            commandStatusRegistry: commandStatusRegistry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let startStatus = await Self.curlPost(
            socket: socket,
            path: "/command-markers",
            body: Self.osc133("B"),
            hostSessionID: registeredID
        )
        #expect(startStatus == 0)

        let endStatus = await Self.curlPost(
            socket: socket,
            path: "/command-markers",
            body: Self.osc133("D;0"),
            hostSessionID: registeredID
        )
        #expect(endStatus == 0)

        let reached = await waitUntil {
            await MainActor.run {
                commandStatusRegistry.statusByTerminalSession[registeredID]?.exitCode == 0
                    && commandStatusRegistry.statusByTerminalSession[registeredID]?.isRunning == false
            }
        }
        #expect(reached)
        let live = await MainActor.run {
            commandStatusRegistry.statusByTerminalSession[registeredID]
        }
        #expect(live?.isSuccess == true)

        let stats = await listener.currentStatistics()
        #expect(stats.commandMarkerUpdates == 2)

        await listener.stop()
    }

    @Test("command-markers POST drops missing and unregistered sessions")
    func commandMarkersDropMissingAndUnregisteredSessions() async throws {
        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: "/tmp")
        let registeredID = registry.registeredID
        let commandStatusRegistry = await MainActor.run { LastCommandStatusRegistry() }
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            commandStatusRegistry: commandStatusRegistry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        _ = await Self.curlPost(
            socket: socket,
            path: "/command-markers",
            body: Self.osc133("B")
        )
        _ = await Self.curlPost(
            socket: socket,
            path: "/command-markers",
            body: Self.osc133("D;0"),
            hostSessionID: UUID()
        )

        try await Task.sleep(nanoseconds: 400_000_000)
        let status = await MainActor.run {
            commandStatusRegistry.statusByTerminalSession[registeredID]
        }
        #expect(status == nil)

        await listener.stop()
    }

    @Test("command-markers POST with malformed body records decode failure")
    func commandMarkersMalformedBodyRecordsDecodeFailure() async throws {
        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: "/tmp")
        let registeredID = registry.registeredID
        let commandStatusRegistry = await MainActor.run { LastCommandStatusRegistry() }
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            commandStatusRegistry: commandStatusRegistry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let status = await Self.curlPost(
            socket: socket,
            path: "/command-markers",
            body: Data("not an osc marker".utf8),
            hostSessionID: registeredID
        )
        #expect(status == 0)

        let reached = await waitUntil {
            await listener.currentStatistics().decodeFailures == 1
        }
        #expect(reached)
        let commandStatus = await MainActor.run {
            commandStatusRegistry.statusByTerminalSession[registeredID]
        }
        #expect(commandStatus == nil)

        await listener.stop()
    }

    @Test("Unknown event payload returns 200 without state mutation")
    func unknownEventDoesNotError() async throws {
        let cwd = "/tmp/hook-test-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: cwd)
        let registeredID = registry.registeredID
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let runBefore = await registry.statuses[registeredID]?.run

        let body: [String: Any] = [
            "hook_event_name": "SomeFutureEvent",
            "session_id": "s",
            "cwd": cwd,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let status = await Self.curlPost(
            socket: socket, path: "/event", body: data, hostSessionID: registeredID)
        #expect(status == 0)

        // Absence-of-mutation check — give the listener mailbox room to drain
        // before sampling. A short fixed wait is fine here because there is no
        // condition we could poll on.
        try await Task.sleep(nanoseconds: 400_000_000)
        let runAfter = await registry.statuses[registeredID]?.run
        #expect(runAfter == runBefore)

        await listener.stop()
    }

    // MARK: - Coalesced ingest (#1347)

    private func hookBody(_ name: String, cwd: String, extra: [String: Any] = [:]) throws -> Data {
        var body: [String: Any] = [
            "hook_event_name": name,
            "session_id": "coalesce-session",
            "cwd": cwd,
        ]
        for (k, v) in extra { body[k] = v }
        return try JSONSerialization.data(withJSONObject: body)
    }

    @Test("Events within one window flush as a single batch with one apply")
    func coalescedBurstFlushesOnce() async throws {
        let cwd = "/tmp/hook-co-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: cwd)
        let registeredID = registry.registeredID
        // Interval far beyond the test's lifetime: the flush below is explicit,
        // so the assertion is deterministic on any runner.
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            coalescingInterval: 600,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        for (name, extra) in [
            ("PreToolUse", ["tool_name": "Read"]),
            ("PostToolUse", ["tool_name": "Read"]),
            ("PreToolUse", ["tool_name": "Edit"]),
            ("PostToolUse", ["tool_name": "Edit"]),
        ] {
            let status = await Self.curlPost(
                socket: socket, path: "/event",
                body: try hookBody(name, cwd: cwd, extra: extra),
                hostSessionID: registeredID)
            #expect(status == 0)
        }

        let buffered = await waitUntil(timeout: 5.0) {
            await listener.pendingEventCount() == 4
        }
        #expect(buffered)
        // Nothing may reach the registry before the window flushes.
        let batchesBeforeFlush = await registry.appliedBatches.count
        #expect(batchesBeforeFlush == 0)

        await listener.flushPendingEvents()

        let batches = await registry.appliedBatches
        #expect(batches.count == 1)
        #expect(batches.first?.events.count == 4)
        #expect(batches.first?.origin == .hook)
        let stats = await listener.currentStatistics()
        #expect(stats.flushCount == 1)
        #expect(stats.ingestedEvents == 4)
        #expect(await registry.statuses[registeredID]?.run == .thinking)

        await listener.stop()
    }

    @Test("Interleaved hook and statusline events flush as ordered origin groups")
    func coalescedOriginGroupsPreserveOrder() async throws {
        let cwd = "/tmp/hook-og-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: cwd)
        let registeredID = registry.registeredID
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            coalescingInterval: 600,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        var status = await Self.curlPost(
            socket: socket, path: "/event",
            body: try hookBody("PreToolUse", cwd: cwd, extra: ["tool_name": "Read"]),
            hostSessionID: registeredID)
        #expect(status == 0)

        let statusLine: [String: Any] = [
            "session_id": "coalesce-session",
            "workspace": ["current_dir": cwd],
            "cost": ["total_cost_usd": 0.5],
        ]
        status = await Self.curlPost(
            socket: socket, path: "/statusline",
            body: try JSONSerialization.data(withJSONObject: statusLine),
            hostSessionID: registeredID)
        #expect(status == 0)

        status = await Self.curlPost(
            socket: socket, path: "/event",
            body: try hookBody("PostToolUse", cwd: cwd, extra: ["tool_name": "Read"]),
            hostSessionID: registeredID)
        #expect(status == 0)

        let buffered = await waitUntil(timeout: 5.0) {
            await listener.pendingEventCount() == 3
        }
        #expect(buffered)

        await listener.flushPendingEvents()

        let batches = await registry.appliedBatches
        #expect(batches.map { $0.origin } == [.hook, .statusLine, .hook])
        #expect(batches.map { $0.events.count } == [1, 1, 1])
        let stats = await listener.currentStatistics()
        #expect(stats.flushCount == 1)
        #expect(stats.ingestedEvents == 2)
        #expect(stats.statusLineUpdates == 1)

        await listener.stop()
    }

    @Test("Unregistered-session events drop as a unit at flush time")
    func coalescedUnregisteredDropsAtFlush() async throws {
        let cwd = "/tmp/hook-ud-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let socket = Self.makeTempSocketURL()
        let registry = await TestRegistry(cwd: cwd)
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.workspaces",
            registry: registry,
            coalescingInterval: 600,
            socketURLOverride: socket
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let status = await Self.curlPost(
            socket: socket, path: "/event",
            body: try hookBody("PreToolUse", cwd: cwd, extra: ["tool_name": "Read"]),
            hostSessionID: UUID())
        #expect(status == 0)

        let buffered = await waitUntil(timeout: 5.0) {
            await listener.pendingEventCount() == 1
        }
        #expect(buffered)

        await listener.flushPendingEvents()

        let batches = await registry.appliedBatches
        #expect(batches.isEmpty)
        let stats = await listener.currentStatistics()
        #expect(stats.flushCount == 1)
        #expect(stats.ingestedEvents == 0)

        await listener.stop()
    }
}
