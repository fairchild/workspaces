//
//  WorkspaceProcessMonitorTests.swift
//  WorkspaceManagerTests
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("WorkspaceProcessMonitor")
struct WorkspaceProcessMonitorTests {
    let monitor = WorkspaceProcessMonitor()

    @Test("inactive status for non-existent path")
    func detectsNoAgentInNonexistentPath() async {
        let fakeDir = URL(fileURLWithPath: "/tmp/nonexistent-workspace-\(UUID().uuidString)")
        let status = await monitor.detectAgentSession(in: fakeDir)
        #expect(!status.isAgentRunning)
        #expect(status.agentName == nil)
        #expect(status.processCount == 0)
        #expect(status.processes.isEmpty)
    }

    @Test("batch detection returns results for all workspace IDs")
    func batchDetectionReturnsAllKeys() async {
        let id1 = UUID()
        let id2 = UUID()
        let directories: [UUID: URL] = [
            id1: URL(fileURLWithPath: "/tmp/nonexistent-ws-\(id1.uuidString)"),
            id2: URL(fileURLWithPath: "/tmp/nonexistent-ws-\(id2.uuidString)"),
        ]
        let results = await monitor.detectAgents(in: directories)
        #expect(results.count == 2)
        #expect(results[id1] != nil)
        #expect(results[id2] != nil)
        #expect(results[id1]?.isAgentRunning == false)
        #expect(results[id2]?.isAgentRunning == false)
    }

    @Test("AgentStatus.inactive is not running")
    func inactiveStatus() {
        let status = WorkspaceProcessMonitor.AgentStatus.inactive
        #expect(!status.isAgentRunning)
        #expect(status.agentName == nil)
        #expect(status.processCount == 0)
        #expect(status.processes.isEmpty)
    }

    @Test("AgentStatus equality")
    func agentStatusEquality() {
        let a = WorkspaceProcessMonitor.AgentStatus(
            processes: [.init(displayName: "Claude", isKnownAgent: true)]
        )
        let b = WorkspaceProcessMonitor.AgentStatus(
            processes: [.init(displayName: "Claude", isKnownAgent: true)]
        )
        let c = WorkspaceProcessMonitor.AgentStatus.inactive
        #expect(a == b)
        #expect(a != c)
    }

    @Test("AgentStatus convenience properties")
    func agentStatusConvenience() {
        let status = WorkspaceProcessMonitor.AgentStatus(
            processes: [
                .init(displayName: "Claude", isKnownAgent: true),
                .init(displayName: "node", isKnownAgent: false),
            ]
        )
        #expect(status.isAgentRunning)
        #expect(status.agentName == "Claude")
        #expect(status.processCount == 2)
    }

    @Test("isAgentRunning is false when only non-agent processes exist")
    func nonAgentProcessesNotReportedAsAgents() {
        let status = WorkspaceProcessMonitor.AgentStatus(
            processes: [
                .init(displayName: "node", isKnownAgent: false),
                .init(displayName: "swift", isKnownAgent: false),
            ]
        )
        #expect(!status.isAgentRunning)
        #expect(status.agentName == nil)
        #expect(status.processCount == 2)
    }

    @Test("extractCommandName trims path to binary name")
    func extractCommandName() {
        #expect(
            WorkspaceProcessMonitor.extractCommandName(
                command: "node",
                fullArgs: "/usr/local/bin/python3 script.py"
            ) == "python3"
        )
        #expect(
            WorkspaceProcessMonitor.extractCommandName(
                command: "claude",
                fullArgs: "/Users/me/Library/Application Support/com.conductor.app/bin/claude --verbose"
            ) == "claude"
        )
        #expect(
            WorkspaceProcessMonitor.extractCommandName(
                command: "truncat",
                fullArgs: ""
            ) == "truncat"
        )
    }

    @Test("DetectedProcess Codable roundtrip")
    func detectedProcessCodable() throws {
        let proc = WorkspaceProcessMonitor.DetectedProcess(displayName: "Claude", isKnownAgent: true)
        let data = try JSONEncoder().encode(proc)
        let decoded = try JSONDecoder().decode(WorkspaceProcessMonitor.DetectedProcess.self, from: data)
        #expect(decoded == proc)
        #expect(decoded.displayName == "Claude")
        #expect(decoded.isKnownAgent == true)
    }
}
