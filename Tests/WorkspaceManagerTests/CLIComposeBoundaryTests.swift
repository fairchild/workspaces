// Exercises the real CLI against agent-controlled Git/configuration. Inventory
// adoption and legacy local records must both stop before any host command runs.

import Darwin
import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("CLI Compose boundary", .serialized)
struct CLIComposeBoundaryTests {
    @Test("Operator inventory preserves Compose identity and blocks host Git and command launch")
    func inventoryRejectsHostExecution() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let server = try InventoryServer(fixture: fixture)
        defer { server.stop() }
        let resolved = try fixture.run(["ws", "path", "demo/sandbox"])
        #expect(resolved.status == 0)
        #expect(resolved.stdout.contains(fixture.repo.url.path))
        for arguments in fixture.hostCommands {
            try fixture.expectRejected(arguments)
        }
        // A record adopted by an older CLI omitted backend identity and otherwise
        // wins selector resolution before the app inventory is considered.
        try fixture.writeLegacyState()
        try fixture.expectRejected(["status", "demo/sandbox"])
    }

    @Test("Offline receipts protect legacy records, descendants, aliases, and resume")
    func offlineReceiptRejectsHostExecution() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLegacyState()
        let receiptDirectory = fixture.syntheticRoot.appendingPathComponent(".compose/ws-fixture")
        try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["hostPath": fixture.repo.url.path]).write(
            to: receiptDirectory.appendingPathComponent("workspace.json")
        )
        for arguments in fixture.hostCommands + [["resume"]] {
            try fixture.expectRejected(arguments)
        }
        let child = fixture.repo.url.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        try fixture.expectRejected(["repo", "add", alias.path])
        try fixture.expectRejected([alias.path])
        try fixture.writeLegacyState(path: alias.path)
        try fixture.expectRejected(["status", "demo/sandbox"])
    }

    @Test("Persisted Compose identity rejects execution without the app or a runtime receipt")
    func persistedIdentityRejectsHostExecution() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLegacyState(backend: "compose")
        try fixture.expectRejected(["status", "demo/sandbox"])
        try fixture.expectRejected(["resume"])
    }

    @Test("Other and legacy workspace records keep existing CLI behavior", arguments: ["legacy", "local", "lume"])
    func localWorkspaceStillWorks(backend: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.git(["config", "--unset", "core.fsmonitor"])
        try fixture.writeLegacyState(backend: backend == "legacy" ? nil : backend)
        let result = try fixture.run(["status", "demo/sandbox"])
        #expect(result.status == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.gitMarker.path))
    }

    private struct Fixture {
        let root: URL
        let repo: TestGitRepository
        let binary: URL
        let workspaceID = UUID()
        let repoID = UUID()
        var syntheticRoot: URL { root.appendingPathComponent("synthetic") }
        var gitMarker: URL { root.appendingPathComponent("host-git-executed") }
        var commandMarker: URL { root.appendingPathComponent("host-command-executed") }
        var environment: [String: String] {
            [
                "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                "WORKSPACES_SYNTHETIC_ROOT": syntheticRoot.path,
                "TMUX_TMPDIR": root.path,
                TmuxSessionControl.socketLabelEnvironmentKey: "compose-boundary-\(workspaceID.uuidString.prefix(8))",
            ]
        }
        var automationDirectory: URL {
            AutomationSupportDirectory.url(bundleIdentifier: "com.cloudcompute.workspaces", environment: environment)
        }
        var hostCommands: [[String]] {
            [
                ["status", "demo/sandbox"], ["open", "demo/sandbox"],
                ["ws", "launch", "demo/sandbox", "--json"],
                ["run", "demo/sandbox", "--", "/usr/bin/touch", commandMarker.path],
            ]
        }

        init() throws {
            binary = try #require(CLIBinary.url, CLIBinary.missingBinaryMessage)
            root = URL(fileURLWithPath: "/tmp").appendingPathComponent("cli-compose-\(UUID().uuidString.prefix(12))")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            repo = try TestGitRepository.create()
            try repo.createFile("README.md", content: "sandbox fixture\n")
            try repo.commit(message: "fixture")
            let hook = root.appendingPathComponent("fsmonitor.sh")
            try "#!/bin/sh\n/usr/bin/touch '\(gitMarker.path)'\nprintf '\\0'\n".write(
                to: hook, atomically: true, encoding: .utf8
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            try git(["config", "core.fsmonitor", hook.path])
            // Establish that this exact executable hook is effective before asking
            // the CLI boundary to prevent it from running.
            try git(["status", "--porcelain=v1"])
            #expect(FileManager.default.fileExists(atPath: gitMarker.path))
            try FileManager.default.removeItem(at: gitMarker)
            try repo.createFile(
                ".workspaces.toml", content: "default_command = \"/usr/bin/touch \(commandMarker.path)\"\n")
        }

        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = repo.url
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        func writeLegacyState(path: String? = nil, backend: String? = nil) throws {
            var record: [String: Any] = [
                "id": workspaceID.uuidString, "name": "sandbox", "repoName": "demo", "repoPath": repo.url.path,
                "path": path ?? repo.url.path, "gitBranch": "main", "createdAt": 0, "lastAccessedAt": 0,
            ]
            if let backend { record["backendIdentifier"] = backend }
            let state: [String: Any] = [
                "version": 1, "repos": [], "workspaces": [record], "recents": [],
                "lastSession": ["workspaceID": workspaceID.uuidString, "openedAt": 0],
            ]
            let directory = root.appendingPathComponent("config/workspaces-cli")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: state).write(to: directory.appendingPathComponent("state.json"))
        }

        func run(_ arguments: [String]) throws -> CLIBinary.Invocation {
            try CLIBinary.run(binary, arguments: arguments, currentDirectory: root, environment: environment)
        }

        func expectRejected(_ arguments: [String]) throws {
            let result = try run(arguments)
            #expect(result.status == 1)
            #expect(result.stderr.contains("Host-only CLI commands cannot operate on a Docker Compose workspace"))
            #expect(!FileManager.default.fileExists(atPath: gitMarker.path))
            #expect(!FileManager.default.fileExists(atPath: commandMarker.path))
        }

        func cleanup() {
            repo.cleanup()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: automationDirectory)
        }
    }

    /// A disposable operator inventory endpoint. No app is launched, and the
    /// fixture credential lives in this test's isolated automation directory.
    private final class InventoryServer {
        private let state: ListenerState

        init(fixture: Fixture) throws {
            let socketURL = fixture.root.appendingPathComponent("inventory.sock")
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            var transferred = false
            defer { if !transferred { close(descriptor) } }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketURL.path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buffer in
                    for (index, byte) in bytes.enumerated() { buffer[index] = byte }
                }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(descriptor, 32) == 0 else { throw POSIXError(.EIO) }
            // Darwin can leave accept blocked after listener shutdown. Bounded
            // polling and nonblocking accept make the shutdown handshake reliable.
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
            let inventory = AutomationWorkspacesResult(
                repos: [
                    AutomationRepoDescriptor(
                        repoID: fixture.repoID, name: "demo", path: fixture.repo.url.path, isSelected: false)
                ],
                workspaces: [
                    AutomationWorkspaceDescriptor(
                        workspaceID: fixture.workspaceID, repoID: fixture.repoID, name: "sandbox",
                        path: fixture.repo.url.path,
                        branch: "main", status: "active", isArchived: false, backend: "compose", isSelected: false
                    )
                ]
            )
            let body = try JSONEncoder().encode(AutomationResponseEnvelope(result: inventory))
            let response =
                Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
            try AutomationOperatorCredentialStore.write(
                AutomationOperatorCredential(socketPath: socketURL.path, handle: "compose-test-handle"),
                to: fixture.automationDirectory.appendingPathComponent(AutomationOperatorCredentialStore.fileName)
            )
            let state = ListenerState(listener: descriptor)
            self.state = state
            let ready = DispatchSemaphore(value: 0)
            // The full suite runs synchronous child processes on global queues.
            // A dedicated thread keeps this subsecond CLI probe independent of them.
            let thread = Thread {
                defer { state.finish() }
                ready.signal()
                while !state.isStopping {
                    var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    guard poll(&readiness, 1, 100) > 0 else { continue }
                    guard !state.isStopping else { return }
                    let client = accept(descriptor, nil, nil)
                    guard client >= 0 else {
                        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                        return
                    }
                    guard state.claim(client) else {
                        close(client)
                        return
                    }
                    Self.respond(to: client, with: response)
                    state.closeClient()
                }
            }
            thread.name = "Compose CLI test inventory"
            thread.qualityOfService = .userInitiated
            transferred = true
            thread.start()
            guard ready.wait(timeout: .now() + 5) == .success else {
                _ = state.stop()
                throw POSIXError(.ETIMEDOUT)
            }
        }

        func stop() {
            #expect(state.stop(), "Inventory listener must exit and close its descriptors")
        }

        private static func respond(to client: Int32, with response: Data) {
            let flags = fcntl(client, F_GETFL)
            guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else { return }
            var enabled: Int32 = 1
            guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
            else { return }
            var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
            guard setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
            else { return }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            let headerEnd = Data("\r\n\r\n".utf8)
            while request.range(of: headerEnd) == nil {
                guard request.count < 16_384, ProcessInfo.processInfo.systemUptime < deadline else { return }
                let count = recv(client, &buffer, buffer.count, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                request.append(contentsOf: buffer.prefix(count))
            }
            response.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var sent = 0
                while sent < bytes.count, ProcessInfo.processInfo.systemUptime < deadline {
                    let count = send(client, baseAddress.advanced(by: sent), bytes.count - sent, 0)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return }
                    sent += count
                }
            }
        }

        /// Shutdown only interrupts descriptors; the listener thread owns their
        /// close. The condition prevents stop racing a close and a reused fd.
        private final class ListenerState: @unchecked Sendable {
            private let condition = NSCondition()
            private var listener: Int32?
            private var client: Int32?
            private var stopping = false
            private var finished = false

            init(listener: Int32) { self.listener = listener }

            var isStopping: Bool {
                condition.lock()
                defer { condition.unlock() }
                return stopping
            }

            func claim(_ descriptor: Int32) -> Bool {
                condition.lock()
                defer { condition.unlock() }
                guard !stopping else { return false }
                client = descriptor
                return true
            }

            func closeClient() {
                condition.lock()
                defer { condition.unlock() }
                if let client { close(client) }
                client = nil
            }

            func finish() {
                condition.lock()
                defer { condition.unlock() }
                if let client { close(client) }
                if let listener { close(listener) }
                client = nil
                listener = nil
                finished = true
                condition.broadcast()
            }

            func stop() -> Bool {
                condition.lock()
                defer { condition.unlock() }
                stopping = true
                if let listener { shutdown(listener, SHUT_RDWR) }
                if let client { shutdown(client, SHUT_RDWR) }
                let deadline = Date().addingTimeInterval(5)
                while !finished {
                    guard condition.wait(until: deadline) else { return finished }
                }
                return true
            }
        }
    }
}
