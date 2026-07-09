//
//  WebNextServerServiceTests.swift
//  WorkspaceManagerTests
//
//  Behavior tests for the local-mode web-next supervisor: state transitions,
//  process-group termination, and sign-in URL construction — all against stub
//  shell commands so no test needs pnpm or a web-next checkout.
//

import Darwin
import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("WebNextServerService")
struct WebNextServerServiceTests {
    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let dataDir: URL
        let port: Int

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("webnext-server-tests-\(UUID().uuidString)", isDirectory: true)
            dataDir = root.appendingPathComponent("data", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            port = try Self.findFreePort()
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func configuration(
            script: String,
            readinessTimeout: TimeInterval = 20,
            readinessPollInterval: TimeInterval = 0.1,
            terminationGracePeriod: TimeInterval = 3
        ) -> WebNextServerConfiguration {
            WebNextServerConfiguration(
                webNextRoot: root,
                port: port,
                dataDir: dataDir,
                logDirectory: root.appendingPathComponent("logs", isDirectory: true),
                launchCommand: WebNextLaunchCommand(executablePath: "/bin/sh", arguments: ["-c", script]),
                readinessTimeout: readinessTimeout,
                readinessPollInterval: readinessPollInterval,
                terminationGracePeriod: terminationGracePeriod
            )
        }

        /// Stub server: records env/cwd the service injected, then answers HTTP
        /// on the configured port (any HTTP response counts as ready).
        var httpServerScript: String {
            """
            echo "$PORT" > "$WEB_NEXT_DATA_DIR/observed-port"
            pwd > "$WEB_NEXT_DATA_DIR/observed-cwd"
            exec python3 -m http.server "$PORT" --bind 127.0.0.1
            """
        }

        private static func findFreePort() throws -> Int {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { throw POSIXError(.EIO) }
            defer { close(sock) }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw POSIXError(.EADDRINUSE) }

            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(sock, $0, &length)
                }
            }
            guard named == 0 else { throw POSIXError(.EIO) }
            return Int(UInt16(bigEndian: address.sin_port))
        }
    }

    private func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func readPID(at url: URL) -> pid_t? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
            let value = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return value
    }

    // MARK: - Readiness

    @Test("start reaches ready once the port answers HTTP, with PORT/WEB_NEXT_DATA_DIR/cwd injected")
    func startBecomesReady() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = WebNextServerService(configuration: fixture.configuration(script: fixture.httpServerScript))

        await service.start()
        defer { Task { await service.stop() } }

        let expectedBaseURL = URL(string: "http://127.0.0.1:\(fixture.port)")!
        #expect(await service.state == .ready(signInBaseURL: expectedBaseURL))

        let observedPort = try String(
            contentsOf: fixture.dataDir.appendingPathComponent("observed-port"), encoding: .utf8)
        #expect(observedPort.trimmingCharacters(in: .whitespacesAndNewlines) == String(fixture.port))

        let observedCwd = try String(
            contentsOf: fixture.dataDir.appendingPathComponent("observed-cwd"), encoding: .utf8)
        #expect(
            URL(fileURLWithPath: observedCwd.trimmingCharacters(in: .whitespacesAndNewlines))
                .resolvingSymlinksInPath().path == fixture.root.resolvingSymlinksInPath().path
        )

        await service.stop()
    }

    @Test("readiness timeout transitions to failed and kills the spawned process")
    func readinessTimeoutFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let script = """
            echo $$ > "$WEB_NEXT_DATA_DIR/server.pid"
            exec sleep 300
            """
        let service = WebNextServerService(
            configuration: fixture.configuration(script: script, readinessTimeout: 1.5))

        await service.start()

        guard case .failed(let reason) = await service.state else {
            Issue.record("expected .failed, got \(await service.state)")
            return
        }
        #expect(reason.contains("Timed out"))

        let serverPID = try #require(readPID(at: fixture.dataDir.appendingPathComponent("server.pid")))
        let died = await waitUntil { !self.processIsAlive(serverPID) }
        #expect(died, "spawned process should be terminated after readiness timeout")
    }

    @Test("early process exit transitions to failed before the timeout")
    func earlyExitFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = WebNextServerService(
            configuration: fixture.configuration(script: "exit 1", readinessTimeout: 30))

        let startedAt = Date()
        await service.start()

        guard case .failed(let reason) = await service.state else {
            Issue.record("expected .failed, got \(await service.state)")
            return
        }
        #expect(reason.contains("exited before becoming ready"))
        #expect(Date().timeIntervalSince(startedAt) < 10, "early exit should fail fast, not wait out the timeout")
    }

    // MARK: - Stop

    @Test("stop terminates the entire process group, including grandchildren")
    func stopKillsProcessGroup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let script = """
            sleep 300 &
            echo $! > "$WEB_NEXT_DATA_DIR/child.pid"
            \(fixture.httpServerScript)
            """
        let service = WebNextServerService(configuration: fixture.configuration(script: script))

        await service.start()
        guard case .ready = await service.state else {
            Issue.record("expected .ready, got \(await service.state)")
            return
        }
        let childPID = try #require(readPID(at: fixture.dataDir.appendingPathComponent("child.pid")))
        #expect(processIsAlive(childPID))

        await service.stop()

        let childDied = await waitUntil { !self.processIsAlive(childPID) }
        #expect(childDied, "grandchild should die with the process group")
        #expect(await service.state == .idle)

        await service.stop()
        #expect(await service.state == .idle, "stop is idempotent")
    }

    // MARK: - Sign-in URL

    @Test("signInURL builds token + redirect URL from the token file, and the token never reaches logs")
    func signInURLFromTokenFile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = WebNextServerService(configuration: fixture.configuration(script: fixture.httpServerScript))

        await service.start()
        defer { Task { await service.stop() } }

        let token = "tok-\(UUID().uuidString)"
        try "\(token)\n".write(
            to: fixture.dataDir.appendingPathComponent("local-sign-in-token"),
            atomically: true,
            encoding: .utf8
        )

        let url = try #require(await service.signInURL(redirect: "/w/demo"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "127.0.0.1")
        #expect(components.port == fixture.port)
        #expect(components.path == "/sign-in")
        #expect(
            components.queryItems == [
                URLQueryItem(name: "token", value: token),
                URLQueryItem(name: "redirect", value: "/w/demo"),
            ]
        )

        let bare = try #require(await service.signInURL(redirect: nil))
        let bareComponents = try #require(URLComponents(url: bare, resolvingAgainstBaseURL: false))
        #expect(bareComponents.queryItems == [URLQueryItem(name: "token", value: token)])

        let logURL = try #require(await service.logFileURL)
        let logContents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        #expect(!logContents.contains(token), "token must never appear in server logs")

        await service.stop()
    }

    @Test("signInURL is nil while not ready")
    func signInURLNilWhenNotReady() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = WebNextServerService(configuration: fixture.configuration(script: "exit 0"))

        #expect(await service.signInURL(redirect: "/w/demo") == nil)

        try "tok-unreachable\n".write(
            to: fixture.dataDir.appendingPathComponent("local-sign-in-token"),
            atomically: true,
            encoding: .utf8
        )
        #expect(await service.signInURL(redirect: nil) == nil, "token on disk alone must not produce a URL")
    }
}
