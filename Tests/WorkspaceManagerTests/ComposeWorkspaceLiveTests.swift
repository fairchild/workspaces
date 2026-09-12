// Exercises the production Compose provider against a local Docker daemon.
// Opt in explicitly; ordinary swift test never pulls images or starts containers.

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Compose provider live", .serialized)
struct ComposeWorkspaceLiveTests {
    @Test(
        "Two provider workspaces survive stop/rebuild and keep deletion scoped",
        .enabled(if: ProcessInfo.processInfo.environment["WORKSPACES_COMPOSE_LIVE_TESTS"] == "1")
    )
    @MainActor
    func realProviderLifecycleAndIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "compose-provider-live-\(UUID().uuidString)"
        )
        .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try TestGitRepository.create()
        defer { source.cleanup() }
        let hostMarker = root.appendingPathComponent("must-not-be-written-on-host")
        try source.createFile("README.md", content: "Compose provider integration fixture\n")
        try source.createFile(
            "setup.sh",
            content: """
                set -eu
                test "$(id -u)" = 1000
                test ! -e /var/run/docker.sock
                printf 'setup ran inside container\n' > /workspace/setup-evidence.txt
                if touch '\(hostMarker.path)' 2>/dev/null; then exit 71; fi
                """
        )
        try source.createFile(
            "fsmonitor-probe.sh",
            content: """
                #!/bin/sh
                uname -s > .git/fsmonitor-probe-ran
                touch '\(hostMarker.path)' 2>/dev/null || true
                printf 'compose-probe-token\\0'
                """
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: source.url.appendingPathComponent("fsmonitor-probe.sh").path
        )
        try source.commit(message: "Live Compose fixture")
        let runtime = ComposeWorkspaceRuntime(runtimeRoot: root.appendingPathComponent("runtime"))
        let provider = ComposeWorkspaceProvider(runtime: runtime)
        let service = WorkspaceService(
            materializer: GitCloneWorkspaceMaterializer(),
            environment: [SyntheticRunRoot.environmentKey: root.appendingPathComponent("workspaces").path]
        )
        var owned: [String: WorkspaceProviderTarget] = [:]
        do {
            let first = try await provider.createWorkspace(
                request: request(source: source.url, name: "first"), workspaceService: service, progress: nil,
                persist: { result in owned[result.remoteId ?? ""] = target(result) }
            )
            let second = try await provider.createWorkspace(
                request: request(source: source.url, name: "second"), workspaceService: service, progress: nil,
                persist: { result in owned[result.remoteId ?? ""] = target(result) }
            )
            let firstTarget = target(first)
            let secondTarget = target(second)
            #expect(first.remoteId != second.remoteId)
            #expect(!FileManager.default.fileExists(atPath: hostMarker.path))
            #expect(
                try String(contentsOf: first.path.appendingPathComponent("setup-evidence.txt"), encoding: .utf8)
                    == "setup ran inside container\n"
            )
            #expect(
                try await provider.executeGit(arguments: ["remote", "get-url", "origin"], for: firstTarget)
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "https://example.com/compose-fixture.git"
            )
            #expect(
                try await provider.executeGit(arguments: ["rev-parse", "--git-dir"], for: firstTarget)
                    .trimmingCharacters(in: .whitespacesAndNewlines) == ".git"
            )
            let spec = try await provider.terminalLaunchSpec(for: firstTarget)
            #expect(spec.customCommand?.contains("'/bin/sh' '-c'") == true)
            try await verifyLiteralCommandWithPTY(provider, firstTarget, spec: spec)
            _ = try await checkedExec(
                provider, firstTarget,
                [
                    "/bin/bash", "-lc",
                    "echo retained > /home/agent/live-persistence; echo first > /workspace/first-only; "
                        + "tmux new-session -d -s live-verification 'sleep 300'",
                ]
            )
            _ = try await checkedExec(provider, firstTarget, ["tmux", "has-session", "-t", "live-verification"])
            _ = try await checkedExec(provider, secondTarget, ["test", "!", "-e", "/workspace/first-only"])
            _ = try await checkedExec(provider, secondTarget, ["test", "!", "-e", "/home/agent/live-persistence"])

            // A real executable hook proves Git ran inside Linux, as well as proving
            // its attempted write outside the checkout could not reach the Mac.
            _ = try await checkedExec(
                provider, firstTarget,
                ["git", "config", "core.fsmonitor", "./fsmonitor-probe.sh"]
            )
            _ = try await provider.executeGit(arguments: ["status", "--porcelain"], for: firstTarget)
            let hookMarker = first.path.appendingPathComponent(".git/fsmonitor-probe-ran")
            #expect(try String(contentsOf: hookMarker, encoding: .utf8) == "Linux\n")
            #expect(!FileManager.default.fileExists(atPath: hostMarker.path))

            // Positive mutation: deliberately use the forbidden host route against
            // this disposable, test-owned clone. The exact hook must create the
            // host marker, proving the preceding negative assertion detects a leak.
            let hostGitTimeout = await LaunchBudget.deadline(launches: 2, floor: 15, ceiling: 90)
            let hostGit = try await ProcessRunner.run(
                executable: "/usr/bin/git", arguments: ["status", "--porcelain"], currentDirectory: first.path,
                environment: [
                    "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                ],
                timeout: hostGitTimeout
            )
            #expect(hostGit.success)
            #expect(try String(contentsOf: hookMarker, encoding: .utf8) == "Darwin\n")
            #expect(FileManager.default.fileExists(atPath: hostMarker.path))
            try FileManager.default.removeItem(at: hostMarker)
            try FileManager.default.removeItem(at: hookMarker)
            print(
                "Compose fsmonitor probe: Linux execution confirmed; forbidden host-route mutation detected and cleaned"
            )
            _ = try await checkedExec(provider, firstTarget, ["git", "config", "--unset", "core.fsmonitor"])
            try await provider.stopWorkspace(firstTarget)
            let stopped = try await provider.syncStatuses(for: [firstTarget, secondTarget])
            #expect(stopped.first?.status == .stopped)
            #expect(stopped.last?.status == .active)
            try await provider.startWorkspace(firstTarget)
            _ = try await checkedExec(
                provider, firstTarget,
                ["/bin/bash", "-lc", "mkdir -p /workspace/scripts; printf 'exit 37\\n' > /workspace/scripts/stop"]
            )
            await #expect(throws: ComposeSandboxError.commandFailed(operation: "Sandbox stop script", exitCode: 37)) {
                try await provider.stopWorkspace(firstTarget)
            }
            #expect(try await provider.syncStatuses(for: [firstTarget]).first?.status == .stopped)
            try await provider.startWorkspace(firstTarget)
            #expect(try await provider.syncStatuses(for: [firstTarget]).first?.status == .active)
            _ = try await checkedExec(provider, firstTarget, ["rm", "/workspace/scripts/stop"])
            print("Compose stop hook: exit 37 reported after containers stopped; workspace restarted successfully")
            #expect(
                try await checkedExec(provider, firstTarget, ["cat", "/home/agent/live-persistence"])
                    .stdout == "retained\n"
            )
            try await provider.rebuildWorkspace(firstTarget)
            #expect(
                try await checkedExec(provider, firstTarget, ["cat", "/home/agent/live-persistence"])
                    .stdout == "retained\n"
            )
            let oldTmux = try await provider.execute(
                in: firstTarget, arguments: ["tmux", "has-session", "-t", "live-verification"]
            )
            #expect(!oldTmux.success)
            try await provider.deleteWorkspace(firstTarget, deleteFiles: false)
            #expect(FileManager.default.fileExists(atPath: first.path.path))
            try await provider.startWorkspace(firstTarget)
            #expect(
                try await checkedExec(provider, firstTarget, ["cat", "/home/agent/live-persistence"])
                    .stdout == "retained\n"
            )
            try await provider.deleteWorkspace(firstTarget, deleteFiles: true)
            owned.removeValue(forKey: first.remoteId ?? "")
            #expect(!FileManager.default.fileExists(atPath: first.path.path))
            #expect(try await provider.syncStatuses(for: [secondTarget]).first?.status == .active)

            try source.modifyFile(
                "setup.sh", content: "touch '\(hostMarker.path)' 2>/dev/null || true\nexit 42\n"
            )
            try source.commit(message: "Fail setup inside container")
            await #expect(throws: ComposeSandboxError.self) {
                try await provider.createWorkspace(
                    request: request(source: source.url, name: "failed"), workspaceService: service, progress: nil,
                    persist: { result in owned[result.remoteId ?? ""] = target(result) }
                )
            }
            let failed = try #require(owned.values.first { $0.name == "failed" })
            #expect(!FileManager.default.fileExists(atPath: hostMarker.path))
            #expect(throws: ComposeSandboxError.incompleteCreation) {
                try provider.reattachmentLaunchSpec(for: failed)
            }
            #expect(try await provider.syncStatuses(for: [failed]).first?.status == .stopped)
            for (id, workspace) in owned {
                try await provider.deleteWorkspace(workspace, deleteFiles: true)
                owned.removeValue(forKey: id)
            }
            print(
                "Compose live provider: two workspaces, guest setup/Git, tmux, stop/start/rebuild, retained data, scoped deletion, failed setup PASS"
            )
        } catch {
            for workspace in owned.values { try? await provider.deleteWorkspace(workspace, deleteFiles: true) }
            throw error
        }
    }

    private func verifyLiteralCommandWithPTY(
        _ provider: ComposeWorkspaceProvider, _ workspace: WorkspaceProviderTarget, spec: TerminalLaunchSpec
    ) async throws {
        let terminalID = UUID().uuidString.lowercased()
        let sessionName = "ws-\(terminalID)"
        let command = try #require(spec.customCommand).replacingOccurrences(
            of: ComposeWorkspaceProvider.terminalSessionPlaceholder, with: terminalID
        )
        let timeout = await LaunchBudget.deadline(launches: 8, floor: 30, ceiling: 120)
        // Match Ghostty's literal command launch, not an implicit shell invocation.
        // Python owns the PTY and always reaps the client on timeout or failure.
        let script = """
            import os, pty, select, shlex, subprocess, sys, time
            master, slave = pty.openpty()
            child = subprocess.Popen(shlex.split(sys.argv[1]), stdin=slave, stdout=slave, stderr=slave,
                                     shell=False, start_new_session=True)
            os.close(slave)
            deadline = time.monotonic() + float(sys.argv[2])
            try:
                while child.poll() is None and time.monotonic() < deadline:
                    readable, _, _ = select.select([master], [], [], 0.1)
                    if readable:
                        try:
                            data = os.read(master, 65536)
                        except OSError:
                            break
                        if data:
                            sys.stdout.buffer.write(data)
                            sys.stdout.buffer.flush()
                if child.poll() is None:
                    child.terminate()
                try:
                    code = child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    code = child.wait()
            finally:
                os.close(master)
            sys.exit(code)
            """
        let attachment = Task {
            try await ProcessRunner.run(
                executable: "/usr/bin/python3", arguments: ["-c", script, command, String(timeout)],
                currentDirectory: spec.workingDirectory, timeout: timeout + 10
            )
        }
        let attached = await waitUntil(timeout: timeout) {
            guard
                let result = try? await provider.execute(
                    in: workspace,
                    arguments: ["tmux", "display-message", "-p", "-t", sessionName, "#{session_attached}"]
                )
            else { return false }
            return result.success && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
        if attached {
            _ = try await checkedExec(provider, workspace, ["tmux", "detach-client", "-s", sessionName])
        }
        let result = try await attachment.value
        #expect(attached, "The literal terminal command must create an attached guest tmux client.")
        #expect(result.success, "PTY launch exited \(result.exitCode): \(result.stdout) \(result.stderr)")
        if attached {
            _ = try await checkedExec(provider, workspace, ["tmux", "has-session", "-t", sessionName])
        }
        print(
            "Compose terminal: literal argv launched a PTY, attached guest tmux, and detached without losing the session"
        )
    }

    private func request(source: URL, name: String) -> WorkspaceProviderCreationRequest {
        WorkspaceProviderCreationRequest(
            repoName: "fixture", repoLocalURL: source, repoRemoteURL: "https://example.com/compose-fixture.git",
            workspaceName: name, guestOS: .linux
        )
    }

    private func target(_ result: WorkspaceProviderCreationResult) -> WorkspaceProviderTarget {
        WorkspaceProviderTarget(
            id: UUID(), name: result.name, path: result.path.path, gitBranch: result.gitBranch, status: result.status,
            backendIdentifier: "compose", remoteId: result.remoteId, sessionRoutingID: result.sessionRoutingID,
            backendMetadataRaw: result.backendMetadataRaw
        )
    }

    @discardableResult
    private func checkedExec(
        _ provider: ComposeWorkspaceProvider, _ workspace: WorkspaceProviderTarget, _ arguments: [String]
    ) async throws -> ProcessResult {
        let result = try await provider.execute(in: workspace, arguments: arguments)
        #expect(result.success, "Container fixture command exited \(result.exitCode): \(result.stderr)")
        return result
    }
}
