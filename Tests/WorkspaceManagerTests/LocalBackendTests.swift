//
//  LocalBackendTests.swift
//  WorkspaceManagerTests
//
//  Tests for LocalBackend actor
//

import Testing
import Foundation
@testable import WorkspaceManagerCore

@Suite("LocalBackend")
struct LocalBackendTests {

    private func makeTempWorkspace() throws -> (Workspace, Repo, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalBackendTest-\(UUID().uuidString)")
        let wsDir = tempDir.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)

        let repo = Repo(name: "test-repo", localPath: tempDir)
        let workspace = Workspace(name: "test-ws", path: wsDir, sourceRepo: repo)
        return (workspace, repo, tempDir)
    }

    @Test("initialize creates workspace directory")
    func initializeCreatesDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalBackendTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wsDir = tempDir.appendingPathComponent("new-ws")
        let repo = Repo(name: "test-repo", localPath: tempDir)
        let workspace = Workspace(name: "new-ws", path: wsDir, sourceRepo: repo)

        let backend = LocalBackend()
        try await backend.initialize(workspace: workspace)

        #expect(FileManager.default.fileExists(atPath: wsDir.path))
    }

    @Test("isRunning always returns true")
    func isRunningReturnsTrue() async throws {
        let (workspace, _, tempDir) = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let backend = LocalBackend()
        let running = await backend.isRunning(workspace: workspace)
        #expect(running)
    }

    @Test("execute runs simple command and captures output")
    func executeRunsCommand() async throws {
        let (workspace, _, tempDir) = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let backend = LocalBackend()
        let result = try await backend.execute(
            command: ["/bin/echo", "hello world"],
            in: workspace
        )

        #expect(result.success)
        #expect(result.stdout.contains("hello world"))
    }

    @Test("execute resolves relative command via PATH")
    func executeResolvesRelativeCommand() async throws {
        let (workspace, _, tempDir) = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let backend = LocalBackend()
        let result = try await backend.execute(
            command: ["echo", "resolved"],
            in: workspace
        )

        #expect(result.success)
        #expect(result.stdout.contains("resolved"))
    }

    @Test("execute throws on empty command")
    func executeThrowsOnEmptyCommand() async throws {
        let (workspace, _, tempDir) = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let backend = LocalBackend()

        await #expect(throws: BackendError.self) {
            _ = try await backend.execute(command: [], in: workspace)
        }
    }

    @Test("execute throws commandNotFound for nonexistent binary")
    func executeThrowsCommandNotFound() async throws {
        let (workspace, _, tempDir) = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let backend = LocalBackend()

        await #expect(throws: BackendError.self) {
            _ = try await backend.execute(
                command: ["definitely-not-a-real-command-xyz"],
                in: workspace
            )
        }
    }

    @Test("execute merges custom environment variables")
    func executeMergesEnvironment() async throws {
        let (workspace, _, tempDir) = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let backend = LocalBackend()
        let result = try await backend.execute(
            command: ["/bin/bash", "-c", "echo $MY_TEST_VAR"],
            in: workspace,
            environment: ["MY_TEST_VAR": "custom_value"]
        )

        #expect(result.success)
        #expect(result.stdout.contains("custom_value"))
    }

    @Test("hostPath returns workspace URL")
    func hostPathReturnsURL() async throws {
        let (workspace, _, tempDir) = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let backend = LocalBackend()
        let path = await backend.hostPath(for: workspace)
        #expect(path == workspace.workspaceURL)
    }
}
