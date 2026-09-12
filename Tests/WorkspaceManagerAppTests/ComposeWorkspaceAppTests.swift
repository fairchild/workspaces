// Verifies the app's Compose boundaries: guest Git routing, per-terminal guest
// reattachment, and no-follow file inspection of an agent-writable checkout.

import Foundation
import SwiftUI
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@Suite("Compose workspace app")
struct ComposeWorkspaceAppTests {
    private func target(path: String = "/tmp/compose-test") -> WorkspaceProviderTarget {
        WorkspaceProviderTarget(
            id: UUID(), name: "Sandbox", path: path, gitBranch: "main", status: .active,
            backendIdentifier: "compose", remoteId: "ws-test", sessionRoutingID: "ws-test", backendMetadataRaw: "{}"
        )
    }

    @MainActor
    @Test("Split terminals have distinct guest sessions and reopening keeps the same session")
    func terminalIdentity() throws {
        let command =
            "docker compose exec agent tmux new-session -A -s ws-\(ComposeWorkspaceProvider.terminalSessionPlaceholder)"
        let store = TileTreeStore()
        let original = store.activateSession(
            key: .backendSession(providerID: "compose", instanceID: "ws-test"),
            directory: URL(fileURLWithPath: "/tmp"), customCommand: command
        ).session
        let split = try #require(store.splitFocusedTile(inTabContaining: original.id))
        #expect(split.customCommand == original.customCommand)
        let first = TerminalSessionLaunchContext.hostSession(original, hooksSocketPath: "/tmp/host-hooks.sock")
        let reopened = TerminalSessionLaunchContext.hostSession(original, hooksSocketPath: "/tmp/host-hooks.sock")
        let second = TerminalSessionLaunchContext.hostSession(split, hooksSocketPath: "/tmp/host-hooks.sock")
        #expect(first == reopened)
        #expect(first.commandMode != second.commandMode)
        let config = GhosttyTerminalConfig(launchContext: first)
        #expect(config.command?.contains(original.id.uuidString.lowercased()) == true)
        #expect(config.command?.contains(ComposeWorkspaceProvider.terminalSessionPlaceholder) == false)
        #expect(first.hookEnvironment().isEmpty)
        #expect(config.environmentVariables["WORKSPACES_HOOKS_SOCKET"] == nil)
        #expect(config.environmentVariables["WORKSPACES_AUTOMATION_SOCKET"] == nil)
        #expect(config.environmentVariables["SSH_AUTH_SOCK"] == nil)
    }

    @Test("Compose Git actions never call host Git and preserve literal file names")
    func containerGitRouting() async throws {
        let host = HostGitSentinel()
        let guest = GuestGitRecorder()
        let workspace = target()
        let inspection = ComposeRepositoryInspection(
            workspace: workspace, directoryURL: workspace.workspaceURL, hostGit: host,
            executeGit: { arguments, _ in await guest.run(arguments) }
        )
        let status = try await inspection.status()
        #expect(status.map(\.path) == ["name with\nnewline.txt", "new.txt", "untracked.txt"])
        #expect(status.map(\.status) == [.modified, .renamed, .untracked])
        _ = try await inspection.diff(file: ":(glob)literal[abc].txt")
        try await inspection.stage(file: "literal[abc].txt")
        try await inspection.unstage(file: "literal[abc].txt")
        try await inspection.discard(file: "literal[abc].txt", untracked: false)
        try await inspection.discard(file: "literal[abc].txt", untracked: true)
        #expect(await host.callCount == 0)
        let calls = await guest.calls
        #expect(calls.count == 6)
        #expect(
            calls[1] == [
                "--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--",
                ":(glob)literal[abc].txt",
            ])
        #expect(calls[2] == ["--literal-pathspecs", "add", "--", "literal[abc].txt"])
        #expect(calls[5] == ["--literal-pathspecs", "clean", "-f", "--", "literal[abc].txt"])
    }

    @Test("An unavailable sandbox is reported without falling back to host Git")
    func unavailableDoesNotFallBack() async {
        let host = HostGitSentinel()
        let workspace = target()
        let inspection = ComposeRepositoryInspection(
            workspace: workspace, directoryURL: workspace.workspaceURL, hostGit: host,
            executeGit: { _, _ in throw SandboxUnavailable() }
        )
        await #expect(throws: SandboxUnavailable.self) { try await inspection.status() }
        await #expect(throws: SandboxUnavailable.self) { try await inspection.diff(file: "README.md") }
        #expect(await host.callCount == 0)
    }

    @Test("Files in a new directory can be previewed and staged individually")
    func untrackedDirectoryFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compose-new-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The injected executor uses a disposable real Git repository so this
        // regression exercises Git's directory collapsing and actual index changes.
        let fixtureGit: @Sendable ([String]) async throws -> String = { arguments in
            let result = try await ProcessRunner.run(
                executable: "/usr/bin/git", arguments: arguments, currentDirectory: root,
                environment: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            )
            try #require(result.success, "Fixture Git failed: \(result.stderr)")
            return result.stdout
        }
        _ = try await fixtureGit(["init"])
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("new-directory"), withIntermediateDirectories: true)
        let firstPath = "new-directory/first.txt"
        let secondPath = "new-directory/second.txt"
        try Data("first file\n".utf8).write(to: root.appendingPathComponent(firstPath))
        try Data("second file\n".utf8).write(to: root.appendingPathComponent(secondPath))
        #expect(try await fixtureGit(["status", "--porcelain=v1", "-z"]) == "?? new-directory/\0")

        let workspace = target(path: root.path)
        let host = HostGitSentinel()
        let inspection = ComposeRepositoryInspection(
            workspace: workspace, directoryURL: root, hostGit: host,
            executeGit: { arguments, _ in try await fixtureGit(arguments) }
        )
        let changes = try await inspection.status()
        #expect(Set(changes.map(\.path)) == Set([firstPath, secondPath]))
        #expect(changes.allSatisfy { $0.status == .untracked })
        let selected = try #require(changes.first { $0.path == firstPath })
        let preview = try await ComposeSafeFiles.preview(root: root, relativePath: selected.path)
        #expect(preview.text == "first file\n")

        try await inspection.stage(file: selected.path)
        #expect(try await fixtureGit(["diff", "--cached", "--name-only", "-z"]) == firstPath + "\0")
        let afterStage = try await inspection.status()
        #expect(afterStage.first { $0.path == firstPath }?.status == .added)
        #expect(afterStage.first { $0.path == secondPath }?.status == .untracked)
        #expect(await host.callCount == 0)
    }

    @Test("Host-backed inspection keeps using the injected host Git service")
    func hostRouting() async throws {
        let host = HostGitSentinel()
        let inspection = ComposeRepositoryInspection(
            workspace: nil, directoryURL: URL(fileURLWithPath: "/tmp"), hostGit: host,
            executeGit: { _, _ in throw SandboxUnavailable() }
        )
        _ = try await inspection.status()
        #expect(await host.callCount == 1)
    }

    @MainActor
    @Test("App restart regenerates guest attachments from workspace metadata and retains terminal IDs")
    func metadataBasedRestoration() throws {
        let root = FileManager.default.temporaryDirectory
        let repo = Repo(name: "test", localPath: root)
        let workspace = Workspace(
            name: "sandbox", path: root, sourceRepo: repo, backendIdentifier: "compose",
            remoteId: "ws-test", sessionRoutingID: "ws-test"
        )
        repo.workspaces = [workspace]
        let store = TileTreeStore()
        let original = store.activateSession(
            key: .backendSession(providerID: "compose", instanceID: "ws-test"), directory: root,
            customCommand: "persisted command must never execute"
        ).session
        let split = try #require(store.splitFocusedTile(inTabContaining: original.id))
        let box = ComposeManifestBox()
        let controller = MainWindowTerminalContinuityController(
            dependencies: .init(
                manifestRawValue: Binding(get: { box.rawValue }, set: { box.rawValue = $0 }),
                repos: { [repo] }, tileTreeStore: store,
                providerRegistry: WorkspaceProviderRegistry(providers: [ComposeWorkspaceProvider.shared]),
                terminalMode: { .tmuxPerSession }, defaultHomeURL: root
            )
        )
        controller.persistSnapshot()
        let trustedCommand =
            "docker compose exec agent tmux new-session -A -s ws-\(ComposeWorkspaceProvider.terminalSessionPlaceholder)"
        let restored = try #require(
            controller.restoredHostSessionSnapshot(includeHostSessions: false) { target in
                #expect(target.id == workspace.id)
                return TerminalLaunchSpec(
                    sessionKey: original.key, workingDirectory: root, customCommand: trustedCommand)
            })
        #expect(Set(restored.sessions.map(\.id)) == Set([original.id, split.id]))
        #expect(restored.sessions.allSatisfy { $0.customCommand == trustedCommand })
        let restoredOriginal = try #require(restored.sessions.first { $0.id == original.id })
        let config = GhosttyTerminalConfig(launchContext: .hostSession(restoredOriginal, hooksSocketPath: nil))
        #expect(config.command?.contains(original.id.uuidString.lowercased()) == true)
        #expect(controller.restoredHostSessionSnapshot { _ in throw SandboxUnavailable() } == nil)
        repo.workspaces = []
        #expect(
            controller.restoredHostSessionSnapshot { _ in
                Issue.record("A deleted workspace must not attempt provider restoration")
                throw SandboxUnavailable()
            } == nil)
    }

    @MainActor
    @Test("Compose previews and workspaces do not launch a host editor")
    func externalEditorBoundary() {
        let workspaceTarget = target()
        let selection = CodePreviewSelection(
            rootURL: workspaceTarget.workspaceURL, relativePath: "README.md", composeWorkspace: workspaceTarget
        )
        #expect(
            MainWindowPresentationController().openInEditorTarget(
                selectedCodePreview: selection, selectedWorkspace: nil, selectedRepo: nil
            ) == nil)
    }

    @Test("Sandbox file tree and preview reject outside links including an intermediate directory")
    func noFollowFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compose-safe-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "compose-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("host secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try Data("# Sandbox\n".utf8).write(to: root.appendingPathComponent("README.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("secret.txt"),
            withDestinationURL: outside.appendingPathComponent("secret.txt")
        )
        let tree = try ComposeSafeFiles.fileTree(at: root)
        #expect(tree.children?.map(\.name) == ["README.md"])
        #expect(throws: (any Error).self) {
            try ComposeSafeFiles.read(root: root, relativePath: "escape/secret.txt", limit: 100)
        }
        #expect(throws: (any Error).self) {
            try ComposeSafeFiles.read(root: root, relativePath: "secret.txt", limit: 100)
        }
        #expect(throws: (any Error).self) {
            try ComposeSafeFiles.read(root: root, relativePath: "../secret.txt", limit: 100)
        }
        let preview = try await ComposeSafeFiles.preview(root: root, relativePath: "README.md")
        #expect(preview.text == "# Sandbox\n")
        #expect(preview.fileSnapshot == nil)
        #expect(CodeEditorDocument(payload: preview).canEdit == false)
    }
}

private struct SandboxUnavailable: Error {}

@MainActor
private final class ComposeManifestBox {
    var rawValue = ""
}

private actor GuestGitRecorder {
    var calls: [[String]] = []

    func run(_ arguments: [String]) -> String {
        calls.append(arguments)
        if arguments.first == "status" {
            return " M name with\nnewline.txt\0R  new.txt\0old.txt\0?? untracked.txt\0"
        }
        return ""
    }
}

private actor HostGitSentinel: GitServiceProtocol {
    var callCount = 0
    func getStatus(at path: URL) -> [FileChange] { callCount += 1; return [] }
    func getRemoteURL(at path: URL) -> String? { callCount += 1; return nil }
    func getCurrentBranch(at path: URL) -> String? { callCount += 1; return nil }
    func createBranch(_ name: String, at path: URL) { callCount += 1 }
    func createWorktree(branchName: String, at destination: URL, from source: URL, startPoint: String?) {
        callCount += 1
    }
    func checkoutBranch(_ name: String, at path: URL) { callCount += 1 }
    func getFileTree(at path: URL, maxDepth: Int) -> FileNode {
        callCount += 1
        return FileNode(name: "test", path: "", isDirectory: true, children: [])
    }
    func diff(file: String, at path: URL) throws -> UnifiedDiff {
        callCount += 1
        return try UnifiedDiff.parse("", path: file)
    }
    func stage(file: String, at path: URL) { callCount += 1 }
    func unstage(file: String, at path: URL) { callCount += 1 }
    func discard(file: String, at path: URL) { callCount += 1 }
    func discardUntracked(file: String, at path: URL) { callCount += 1 }
    func branches(at path: URL) -> [BranchName] { callCount += 1; return [] }
}
