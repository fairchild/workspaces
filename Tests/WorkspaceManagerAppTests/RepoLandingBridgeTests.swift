//
//  RepoLandingBridgeTests.swift
//  WorkspaceManagerAppTests
//
//  Behavior tests for the JS ↔ Swift repo landing bridge.
//

import Foundation
import Testing
import WebKit

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("RepoLandingBridge")
struct RepoLandingBridgeTests {

    // MARK: - Message Dispatching

    @Test("ready action fires onReady callback")
    func readyActionFiresCallback() {
        let bridge = RepoLandingBridge()
        var readyCalled = false
        bridge.onReady = { readyCalled = true }

        simulateMessage(bridge: bridge, body: ["action": "ready"])
        #expect(readyCalled)
    }

    @Test("selectWorkspace action delivers workspace ID")
    func selectWorkspaceDeliversID() {
        let bridge = RepoLandingBridge()
        var receivedID: String?
        bridge.onSelectWorkspace = { receivedID = $0 }

        let testID = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
        simulateMessage(bridge: bridge, body: ["action": "selectWorkspace", "id": testID])
        #expect(receivedID == testID)
    }

    @Test("createWorkspace action fires callback")
    func createWorkspaceFiresCallback() {
        let bridge = RepoLandingBridge()
        var called = false
        bridge.onCreateWorkspace = { called = true }

        simulateMessage(bridge: bridge, body: ["action": "createWorkspace"])
        #expect(called)
    }

    @Test("openTerminal action fires callback")
    func openTerminalFiresCallback() {
        let bridge = RepoLandingBridge()
        var called = false
        bridge.onOpenTerminal = { called = true }

        simulateMessage(bridge: bridge, body: ["action": "openTerminal"])
        #expect(called)
    }

    @Test("archiveWorkspace action delivers workspace ID")
    func archiveWorkspaceDeliversID() {
        let bridge = RepoLandingBridge()
        var receivedID: String?
        bridge.onArchiveWorkspace = { receivedID = $0 }

        simulateMessage(bridge: bridge, body: ["action": "archiveWorkspace", "id": "ws-123"])
        #expect(receivedID == "ws-123")
    }

    @Test("revealInFinder action delivers workspace ID")
    func revealInFinderDeliversID() {
        let bridge = RepoLandingBridge()
        var receivedID: String?
        bridge.onRevealInFinder = { receivedID = $0 }

        simulateMessage(bridge: bridge, body: ["action": "revealInFinder", "id": "ws-456"])
        #expect(receivedID == "ws-456")
    }

    @Test("openInEditor action delivers workspace ID")
    func openInEditorDeliversID() {
        let bridge = RepoLandingBridge()
        var receivedID: String?
        bridge.onOpenInEditor = { receivedID = $0 }

        simulateMessage(bridge: bridge, body: ["action": "openInEditor", "id": "ws-789"])
        #expect(receivedID == "ws-789")
    }

    @Test("unknown action does not crash or fire callbacks")
    func unknownActionIsIgnored() {
        let bridge = RepoLandingBridge()
        var anyCalled = false
        bridge.onReady = { anyCalled = true }
        bridge.onSelectWorkspace = { _ in anyCalled = true }
        bridge.onCreateWorkspace = { anyCalled = true }

        simulateMessage(bridge: bridge, body: ["action": "unknownAction"])
        #expect(!anyCalled)
    }

    @Test("malformed message body is ignored gracefully")
    func malformedBodyIsIgnored() {
        let bridge = RepoLandingBridge()
        var anyCalled = false
        bridge.onReady = { anyCalled = true }

        // Missing "action" key
        simulateMessage(bridge: bridge, body: ["type": "ready"])
        #expect(!anyCalled)
    }

    @Test("selectWorkspace without id does not fire callback")
    func selectWorkspaceWithoutIDIsIgnored() {
        let bridge = RepoLandingBridge()
        var receivedID: String?
        bridge.onSelectWorkspace = { receivedID = $0 }

        simulateMessage(bridge: bridge, body: ["action": "selectWorkspace"])
        #expect(receivedID == nil)
    }

    // MARK: - Helpers

    private func simulateMessage(bridge: RepoLandingBridge, body: [String: Any]) {
        let controller = WKUserContentController()
        let message = FakeScriptMessage(body: body, name: RepoLandingBridge.handlerName)
        bridge.userContentController(controller, didReceive: message)
    }
}

// MARK: - RepoLandingData Encoding

@Suite("RepoLandingData")
struct RepoLandingDataTests {

    @Test("encodes repo info with all fields")
    func encodesRepoInfo() throws {
        let data = RepoLandingData(
            repo: .init(name: "voxcode", localPath: "/Users/dev/voxcode", remoteURL: "https://github.com/dev/voxcode"),
            workspaces: []
        )

        let json = try encodeToDictionary(data)
        let repo = try #require(json["repo"] as? [String: Any])
        #expect(repo["name"] as? String == "voxcode")
        #expect(repo["localPath"] as? String == "/Users/dev/voxcode")
        #expect(repo["remoteURL"] as? String == "https://github.com/dev/voxcode")
    }

    @Test("encodes repo with nil remoteURL as absent or null")
    func encodesNilRemoteURL() throws {
        let data = RepoLandingData(
            repo: .init(name: "local-only", localPath: "/tmp/local", remoteURL: nil),
            workspaces: []
        )

        let json = try encodeToDictionary(data)
        let repo = try #require(json["repo"] as? [String: Any])
        // JSONEncoder omits nil keys; verify the value is not a non-nil string
        let remoteURL = repo["remoteURL"]
        #expect(remoteURL == nil || remoteURL is NSNull)
    }

    @Test("encodes workspace info with agent status")
    func encodesWorkspaceWithAgent() throws {
        let data = RepoLandingData(
            repo: .init(name: "test", localPath: "/tmp/test", remoteURL: nil),
            workspaces: [
                .init(
                    id: "uuid-1", name: "feature-x", branch: "ws/feature-x",
                    path: "/tmp/test/.workspaces/feature-x",
                    status: "active", lastAccessedAt: 1_700_000_000,
                    isAgentRunning: true, agentName: "claude",
                    processes: [.init(displayName: "Claude", isKnownAgent: true)]
                )
            ]
        )

        let json = try encodeToDictionary(data)
        let workspaces = try #require(json["workspaces"] as? [[String: Any]])
        #expect(workspaces.count == 1)

        let ws = workspaces[0]
        #expect(ws["id"] as? String == "uuid-1")
        #expect(ws["name"] as? String == "feature-x")
        #expect(ws["branch"] as? String == "ws/feature-x")
        #expect(ws["status"] as? String == "active")
        #expect(ws["isAgentRunning"] as? Bool == true)
        #expect(ws["agentName"] as? String == "claude")
        #expect(ws["lastAccessedAt"] as? Double == 1_700_000_000)
    }

    @Test("encodes workspace with nil branch and agentName as absent or null")
    func encodesNilBranch() throws {
        let data = RepoLandingData(
            repo: .init(name: "test", localPath: "/tmp/test", remoteURL: nil),
            workspaces: [
                .init(
                    id: "uuid-2", name: "scratch", branch: nil,
                    path: "/tmp/test/.workspaces/scratch",
                    status: "stopped", lastAccessedAt: 1_700_000_000,
                    isAgentRunning: false, agentName: nil,
                    processes: []
                )
            ]
        )

        let json = try encodeToDictionary(data)
        let workspaces = try #require(json["workspaces"] as? [[String: Any]])
        let ws = workspaces[0]
        // JSONEncoder omits nil optionals; verify they're not non-nil strings
        let branch = ws["branch"]
        let agentName = ws["agentName"]
        #expect(branch == nil || branch is NSNull)
        #expect(agentName == nil || agentName is NSNull)
        #expect(ws["isAgentRunning"] as? Bool == false)
    }

    @Test("Codable roundtrip preserves all data")
    func codableRoundtrip() throws {
        let original = RepoLandingData(
            repo: .init(name: "roundtrip", localPath: "/tmp/roundtrip", remoteURL: "https://example.com"),
            workspaces: [
                .init(
                    id: "id-a", name: "alpha", branch: "ws/alpha",
                    path: "/tmp/roundtrip/.workspaces/alpha",
                    status: "active", lastAccessedAt: 1_700_100_000,
                    isAgentRunning: true, agentName: "codex",
                    processes: [.init(displayName: "Codex", isKnownAgent: true)]
                ),
                .init(
                    id: "id-b", name: "beta", branch: nil,
                    path: "/tmp/roundtrip/.workspaces/beta",
                    status: "archived", lastAccessedAt: 1_699_900_000,
                    isAgentRunning: false, agentName: nil,
                    processes: []
                ),
            ]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RepoLandingData.self, from: encoded)

        #expect(decoded.repo.name == original.repo.name)
        #expect(decoded.repo.localPath == original.repo.localPath)
        #expect(decoded.repo.remoteURL == original.repo.remoteURL)
        #expect(decoded.workspaces.count == 2)
        #expect(decoded.workspaces[0].id == "id-a")
        #expect(decoded.workspaces[0].agentName == "codex")
        #expect(decoded.workspaces[1].branch == nil)
        #expect(decoded.workspaces[1].agentName == nil)
    }

    // MARK: - Helpers

    private func encodeToDictionary(_ data: RepoLandingData) throws -> [String: Any] {
        let jsonData = try JSONEncoder().encode(data)
        return try #require(
            JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        )
    }
}

// MARK: - Web Index Resolution

@Suite("WebIndexResolution")
struct WebIndexResolutionTests {

    @Test("repo override takes precedence when present")
    func repoOverrideTakesPrecedence() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-test-\(UUID().uuidString)")
        let agentsDir = tmp.appendingPathComponent(".agents/workspaces")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let indexFile = agentsDir.appendingPathComponent("index.html")
        try "<html>repo</html>".write(to: indexFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resolved = resolveWebIndex(repoLocalPath: tmp.path)
        #expect(resolved == indexFile)
    }

    @Test("returns nil when no overrides exist (native is default)")
    func returnsNilWhenNoOverrides() {
        let resolved = resolveWebIndex(repoLocalPath: "/nonexistent/repo/path")
        let globalWeb = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/workspaces/index.html")
        let globalExists = FileManager.default.fileExists(atPath: globalWeb.path)
        if globalExists {
            #expect(resolved == globalWeb)
        } else {
            #expect(resolved == nil)
        }
    }

    @Test("resolution skips missing repo override and falls through")
    func resolutionSkipsMissingRepoOverride() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-test-\(UUID().uuidString)")
        let resolved = resolveWebIndex(repoLocalPath: tmp.path)
        let globalWeb = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/workspaces/index.html")
        let globalExists = FileManager.default.fileExists(atPath: globalWeb.path)
        if globalExists {
            #expect(resolved == globalWeb)
        } else {
            #expect(resolved == nil)
        }
    }

    /// Extracted resolution logic matching RepoLandingView.resolvedWebIndex
    private func resolveWebIndex(repoLocalPath: String) -> URL? {
        let repoURL = URL(fileURLWithPath: repoLocalPath)
        let repoWeb = repoURL.appendingPathComponent(".agents/workspaces/index.html")
        if FileManager.default.fileExists(atPath: repoWeb.path) { return repoWeb }

        let globalWeb = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/workspaces/index.html")
        if FileManager.default.fileExists(atPath: globalWeb.path) { return globalWeb }

        return nil
    }
}

// MARK: - Fake WKScriptMessage

/// Minimal stub for WKScriptMessage to drive bridge tests without a live WKWebView.
private final class FakeScriptMessage: WKScriptMessage {
    private let _body: Any
    private let _name: String

    init(body: Any, name: String) {
        self._body = body
        self._name = name
        super.init()
    }

    override var body: Any { _body }
    override var name: String { _name }
}
