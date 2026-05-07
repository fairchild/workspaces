//
//  WorkspaceServiceClaudeSetupTests.swift
//  WorkspaceManagerTests
//
//  Channel 5 integration tests: when a workspace ships
//  `.workspaces/claude-setup.json`, `WorkspaceService.createWorkspace`
//  invokes `HeadlessClaudeRunner` after `setup.sh`. Failures must NEVER
//  fail workspace creation.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("WorkspaceService claude-setup integration", .serialized)
struct WorkspaceServiceClaudeSetupTests {

    private func makeFixture() throws -> (testRoot: URL, repoDir: URL, wsRoot: URL) {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSClaudeSetup-\(UUID().uuidString)")
        let repoDir = testRoot.appendingPathComponent("repos/test-repo")
        let wsRoot = testRoot.appendingPathComponent("workspaces")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repoDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        // Drop the per-project config that should drive the warm-up.
        let configDir =
            repoDir
            .appendingPathComponent(".workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let configJSON = """
            {"prompt":"warm up the workspace","allowedTools":["Read","Bash"]}
            """
        try configJSON.write(
            to: configDir.appendingPathComponent("claude-setup.json"),
            atomically: true,
            encoding: .utf8
        )
        return (testRoot, repoDir, wsRoot)
    }

    private func setWorkspacesRoot(_ url: URL) -> String? {
        let key = "workspacesRoot"
        let original = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(url.path, forKey: key)
        return original
    }

    private func restoreWorkspacesRoot(_ original: String?) {
        let key = "workspacesRoot"
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test("createWorkspace invokes HeadlessClaudeRunner with the configured prompt + tools")
    func warmupRunsWithConfig() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.testRoot) }
        let original = setWorkspacesRoot(fixture.wsRoot)
        defer { restoreWorkspacesRoot(original) }

        let stub = StubStreamingRunner(
            stdoutChunks: [
                #"{"type":"system","subtype":"init","model":"m","session_id":"sess-warm","tools":[]}"# + "\n",
                #"{"type":"result","result":"ok","total_cost_usd":0.0,"duration_ms":1,"num_turns":1,"session_id":"sess-warm"}"#
                    + "\n",
            ],
            stderrChunks: [],
            exitCode: 0
        )

        let runner = HeadlessClaudeRunner(
            processRunner: stub,
            executableResolver: { "/opt/homebrew/bin/claude" }
        )
        let mockGit = MockGitService()
        let service = WorkspaceService(
            gitService: mockGit,
            claudeRunnerFactory: { runner }
        )

        let info = try await service.createWorkspace(
            repoName: "test-repo",
            repoLocalURL: fixture.repoDir,
            name: "ws-1",
            progress: nil
        )

        #expect(info.warnings.isEmpty)

        // The runner was invoked with the config prompt + allowedTools + --bare.
        let captured = stub.captured.value
        #expect(captured?.arguments.contains("--bare") == true)
        #expect(captured?.arguments.contains("warm up the workspace") == true)
        #expect(captured?.arguments.contains("Read,Bash") == true)
        #expect(captured?.cwd?.standardizedFileURL.path == info.path.standardizedFileURL.path)

        // Session id was persisted.
        let store = HeadlessSessionStore(workspaceRoot: info.path)
        #expect(store.loadLatestSessionID() == "sess-warm")
    }

    @Test("createWorkspace skips warm-up cleanly when no config is present")
    func warmupSkippedWithoutConfig() async throws {
        // Identical fixture but without `claude-setup.json`.
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSClaudeSetupSkip-\(UUID().uuidString)")
        let repoDir = testRoot.appendingPathComponent("repos/test-repo")
        let wsRoot = testRoot.appendingPathComponent("workspaces")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repoDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let original = setWorkspacesRoot(wsRoot)
        defer { restoreWorkspacesRoot(original) }

        let stub = StubStreamingRunner(stdoutChunks: [], stderrChunks: [], exitCode: 0)
        let runner = HeadlessClaudeRunner(
            processRunner: stub,
            executableResolver: { "/opt/homebrew/bin/claude" }
        )
        let service = WorkspaceService(
            gitService: MockGitService(),
            claudeRunnerFactory: { runner }
        )

        let info = try await service.createWorkspace(
            repoName: "test-repo",
            repoLocalURL: repoDir,
            name: "ws-skip",
            progress: nil
        )
        #expect(info.warnings.isEmpty)
        #expect(stub.captured.value == nil)  // never invoked
    }

    @Test("warm-up failure does NOT fail workspace creation")
    func warmupFailureNonFatal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.testRoot) }
        let original = setWorkspacesRoot(fixture.wsRoot)
        defer { restoreWorkspacesRoot(original) }

        let stub = StubStreamingRunner(
            stdoutChunks: [],
            stderrChunks: ["claude: not authenticated\n"],
            exitCode: 1
        )
        let runner = HeadlessClaudeRunner(
            processRunner: stub,
            executableResolver: { "/opt/homebrew/bin/claude" }
        )
        let service = WorkspaceService(
            gitService: MockGitService(),
            claudeRunnerFactory: { runner }
        )

        // Should NOT throw — warm-up failure is best-effort.
        let info = try await service.createWorkspace(
            repoName: "test-repo",
            repoLocalURL: fixture.repoDir,
            name: "ws-failure",
            progress: nil
        )
        #expect(FileManager.default.fileExists(atPath: info.path.path))
    }

    @Test("WorkspaceClaudeSetup loads per-project config preferentially")
    func loadsProjectConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSetupLoad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configDir = dir.appendingPathComponent(".workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try """
        {"prompt":"hello","allowedTools":["Read"]}
        """.write(
            to: configDir.appendingPathComponent("claude-setup.json"),
            atomically: true,
            encoding: .utf8
        )

        let config = WorkspaceClaudeSetup.loadConfig(for: dir, appDefaultsLookup: { nil })
        #expect(config?.prompt == "hello")
        #expect(config?.allowedTools == ["Read"])
    }

    @Test("malformed claude-setup.json is ignored, returns nil")
    func malformedConfigIgnored() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSetupBad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configDir = dir.appendingPathComponent(".workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "{ not json".write(
            to: configDir.appendingPathComponent("claude-setup.json"),
            atomically: true,
            encoding: .utf8
        )
        let config = WorkspaceClaudeSetup.loadConfig(for: dir, appDefaultsLookup: { nil })
        #expect(config == nil)
    }

    @Test("WorkspaceClaudeActions loads action list from .workspaces/claude-actions.json")
    func loadsActionList() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeActionsLoad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configDir = dir.appendingPathComponent(".workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let json = """
            {"actions":[
                {"id":"lint","name":"Lint sweep","prompt":"run linters","allowedTools":["Bash"]},
                {"name":"Doc gen","prompt":"generate docs"}
            ]}
            """
        try json.write(
            to: configDir.appendingPathComponent("claude-actions.json"),
            atomically: true,
            encoding: .utf8
        )

        let actions = WorkspaceClaudeActions.loadActions(for: dir)
        #expect(actions.count == 2)
        #expect(actions[0].id == "lint")
        #expect(actions[0].allowedTools == ["Bash"])
        #expect(actions[1].id == "doc-gen")  // slug fallback
    }
}
