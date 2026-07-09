//
//  WebNextServerServiceTests.swift
//  WorkspaceManagerTests
//
//  Behavior tests for the local-mode web-next supervisor: state transitions,
//  strict healthz readiness, process-group termination, post-ready watchdog,
//  and sign-in URL construction — all against stub shell commands so no test
//  needs pnpm or a web-next checkout.
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
            try Self.healthzServerSource.write(
                to: root.appendingPathComponent("healthz-server.py"), atomically: true, encoding: .utf8)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func configuration(
            script: String,
            readinessTimeout: TimeInterval = 20,
            readinessPollInterval: TimeInterval = 0.1,
            terminationGracePeriod: TimeInterval = 1,
            watchdogInterval: TimeInterval = 5,
            watchdogFailureThreshold: Int = 3
        ) -> WebNextServerConfiguration {
            WebNextServerConfiguration(
                webNextRoot: root,
                port: port,
                dataDir: dataDir,
                logDirectory: root.appendingPathComponent("logs", isDirectory: true),
                launchCommand: WebNextLaunchCommand(executablePath: "/bin/sh", arguments: ["-c", script]),
                readinessTimeout: readinessTimeout,
                readinessPollInterval: readinessPollInterval,
                terminationGracePeriod: terminationGracePeriod,
                watchdogInterval: watchdogInterval,
                watchdogFailureThreshold: watchdogFailureThreshold
            )
        }

        /// Stub server: records env/cwd the service injected, then answers
        /// `/api/healthz` with `200 {"ok": true}` on the configured port.
        var healthzServerScript: String {
            """
            echo "$PORT" > "$WEB_NEXT_DATA_DIR/observed-port"
            pwd > "$WEB_NEXT_DATA_DIR/observed-cwd"
            exec python3 "\(root.path)/healthz-server.py"
            """
        }

        /// Minimal healthz endpoint matching embedded-native-contract.md § 2;
        /// every other path answers 404 so tests exercise the strict check.
        private static let healthzServerSource = """
            from http.server import BaseHTTPRequestHandler, HTTPServer
            import os

            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    if self.path.startswith("/api/healthz"):
                        body = b'{"ok": true}'
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                    else:
                        self.send_response(404)
                        self.end_headers()

                def log_message(self, *args):
                    pass

            HTTPServer(("127.0.0.1", int(os.environ["PORT"])), Handler).serve_forever()
            """

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

    @Test("start reaches ready on healthz ok, with PORT/WEB_NEXT_DATA_DIR/cwd injected")
    func startBecomesReady() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = WebNextServerService(configuration: fixture.configuration(script: fixture.healthzServerScript))

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

    @Test("an HTTP listener without healthz never becomes ready — stale/foreign ports are rejected")
    func readinessRejectsNonHealthzListener() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // python http.server answers every path (404 for /api/healthz) — an HTTP
        // response, but not a healthy web-next. Must time out, not go ready.
        let script = """
            exec python3 -m http.server "$PORT" --bind 127.0.0.1
            """
        let service = WebNextServerService(
            configuration: fixture.configuration(script: script, readinessTimeout: 2.5))

        await service.start()

        guard case .failed(let reason) = await service.state else {
            Issue.record("expected .failed, got \(await service.state)")
            return
        }
        #expect(reason.contains("Timed out"))
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

    @Test("pre-ready leader exit still kills surviving group members")
    func earlyExitKillsSurvivingChildren() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let script = """
            sleep 300 &
            echo $! > "$WEB_NEXT_DATA_DIR/child.pid"
            exit 0
            """
        let service = WebNextServerService(
            configuration: fixture.configuration(script: script, readinessTimeout: 30))

        await service.start()

        guard case .failed(let reason) = await service.state else {
            Issue.record("expected .failed, got \(await service.state)")
            return
        }
        #expect(reason.contains("exited before becoming ready"))

        let childPID = try #require(readPID(at: fixture.dataDir.appendingPathComponent("child.pid")))
        let childDied = await waitUntil { !self.processIsAlive(childPID) }
        #expect(childDied, "a child left behind by an exited leader must not survive the failure transition")
    }

    // MARK: - Stop

    @Test("stop terminates the entire process group, including grandchildren")
    func stopKillsProcessGroup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let script = """
            sleep 300 &
            echo $! > "$WEB_NEXT_DATA_DIR/child.pid"
            \(fixture.healthzServerScript)
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

    @Test("stop escalates to SIGKILL when the leader dies but a member ignores SIGTERM")
    func stopEscalatesToSIGKILLForTermIgnoringMember() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // The child writes an "armed" marker only after installing SIG_IGN, so
        // the test cannot race SIGTERM against handler installation.
        let script = """
            python3 -c 'import os, signal, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            open(os.environ["WEB_NEXT_DATA_DIR"] + "/term-ignorer-armed", "w").write("1")
            time.sleep(300)' &
            echo $! > "$WEB_NEXT_DATA_DIR/child.pid"
            \(fixture.healthzServerScript)
            """
        let service = WebNextServerService(
            configuration: fixture.configuration(script: script, terminationGracePeriod: 0.5))

        await service.start()
        guard case .ready = await service.state else {
            Issue.record("expected .ready, got \(await service.state)")
            return
        }
        let armedURL = fixture.dataDir.appendingPathComponent("term-ignorer-armed")
        let armed = await waitUntil(timeout: 5) { FileManager.default.fileExists(atPath: armedURL.path) }
        #expect(armed, "the SIGTERM-ignoring child must be armed before stop() is exercised")
        let childPID = try #require(readPID(at: fixture.dataDir.appendingPathComponent("child.pid")))
        #expect(processIsAlive(childPID))

        await service.stop()

        let childDied = await waitUntil(timeout: 5) { !self.processIsAlive(childPID) }
        #expect(childDied, "a SIGTERM-ignoring group member must be SIGKILLed even after the leader exits")
        #expect(await service.state == .idle)
    }

    // MARK: - Watchdog

    @Test("watchdog fails the state when the server dies after becoming ready")
    func watchdogDetectsServerDeath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let script = """
            echo $$ > "$WEB_NEXT_DATA_DIR/server.pid"
            \(fixture.healthzServerScript)
            """
        let service = WebNextServerService(
            configuration: fixture.configuration(script: script, watchdogInterval: 0.15))

        await service.start()
        guard case .ready = await service.state else {
            Issue.record("expected .ready, got \(await service.state)")
            return
        }

        let serverPID = try #require(readPID(at: fixture.dataDir.appendingPathComponent("server.pid")))
        kill(serverPID, SIGKILL)

        let failed = await waitUntil(timeout: 5) {
            if case .failed = await service.state { return true }
            return false
        }
        #expect(failed, "watchdog should transition to .failed after the server dies")
        #expect(await service.signInURL(redirect: nil) == nil, "no sign-in URLs for a dead server")
    }

    // MARK: - Sign-in URL

    @Test("signInURL builds token + redirect URL from the token file, and the token never reaches logs")
    func signInURLFromTokenFile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = WebNextServerService(configuration: fixture.configuration(script: fixture.healthzServerScript))

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

        let plussed = try #require(await service.signInURL(redirect: "/search?q=a+b"))
        #expect(plussed.absoluteString.contains("%2B"), "a literal + must be percent-encoded in the query")
        let plussedComponents = try #require(URLComponents(url: plussed, resolvingAgainstBaseURL: false))
        #expect(
            plussedComponents.queryItems?.last == URLQueryItem(name: "redirect", value: "/search?q=a+b"),
            "a literal + in the redirect must survive the round-trip, not decay to a space"
        )

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
