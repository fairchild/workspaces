//
//  WebNextServerServiceTests.swift
//  WorkspaceManagerTests
//
//  Behavior tests for the local-mode web-next supervisor: state transitions,
//  strict healthz readiness, process-group termination, post-ready watchdog,
//  and sign-in URL construction — all against stub shell commands so no test
//  needs pnpm or a web-next checkout.
//
//  Deadlines here are sized from `SpawnBudget`'s measured process-spawn cost rather
//  than fixed wall clocks, because spawn latency is the term that varies by two
//  orders of magnitude between a laptop and a loaded hosted runner.
//

import Darwin
import Foundation
import Testing

@testable import WorkspaceManagerCore

/// `.serialized` because these tests are spawn-bound rather than CPU-bound: run
/// concurrently, the suite becomes its own largest source of load, and `SpawnBudget`'s
/// serially-measured baseline then under-predicts what each test actually pays. One
/// stub process group at a time keeps the measurement honest and the budgets derived
/// from it meaningful.
@Suite("WebNextServerService", .serialized)
struct WebNextServerServiceTests {
    // MARK: - Budgets

    /// Readiness budget for tests where reaching `.ready` is a precondition rather
    /// than the property under test: covers the stub's `/bin/sh` spawn, its `python3`
    /// exec, module imports, bind, and first successful health probe, with room for
    /// external load on top.
    private static let readyBudget = SpawnBudget.deadline(spawns: 8, floor: 45, ceiling: 240)

    /// Budget for a side effect of an already-running process — a signal landing, a
    /// process group draining, a marker file appearing. No spawn, but the scheduler
    /// that starves spawns also delays these, so it scales too.
    private static let eventBudget = SpawnBudget.deadline(spawns: 4, floor: 20, ceiling: 120)

    /// Readiness budget for the tests that must let their stub come fully up and then
    /// still be refused. Unlike the others this one is paid in full on every run — a
    /// rejection has no early event to wait on — so it stays as tight as the spawn
    /// measurement allows while keeping ~2x headroom over the two spawns (`/bin/sh`,
    /// then `python3`) the stub needs.
    private static let rejectionBudget = SpawnBudget.deadline(spawns: 4, floor: 4, ceiling: 120)

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

        var baseURL: URL {
            // swift-format-ignore: NeverForceUnwrap
            // Safe: fixed scheme/host plus a kernel-assigned port always forms a valid URL.
            URL(string: "http://127.0.0.1:\(port)")!
        }

        func configuration(
            script: String,
            readinessTimeout: TimeInterval = WebNextServerServiceTests.readyBudget,
            // A quarter second is fast enough to keep local runs snappy while cutting
            // the connection-refused churn a 0.1s poll generates across a whole suite.
            readinessPollInterval: TimeInterval = 0.25,
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

        /// Healthz stub plus a group member that ignores SIGTERM, writing its "armed"
        /// marker only after installing SIG_IGN so tests never race the handler.
        var termIgnoringChildScript: String {
            """
            python3 -c 'import os, signal, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            open(os.environ["WEB_NEXT_DATA_DIR"] + "/term-ignorer-armed", "w").write("1")
            time.sleep(300)' &
            echo $! > "$WEB_NEXT_DATA_DIR/child.pid"
            \(healthzServerScript)
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
                        body = os.environ.get("HEALTHZ_BODY", '{"ok": true, "localMode": true}').encode()
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

    // MARK: - Helpers

    private func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func readPID(at url: URL) -> pid_t? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
            let value = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return value
    }

    /// Runs `body` and stops the service on every exit path — early return, recorded
    /// issue, or thrown error. `defer` cannot `await`, and a fire-and-forget
    /// `Task { await service.stop() }` is not guaranteed to run before the test
    /// process moves on; a missed stop leaves `sleep 300` stubs and Python servers
    /// alive to load the machine for the rest of the run, which is the exact
    /// condition this suite is being hardened against.
    private func withService<T>(
        _ service: WebNextServerService,
        _ body: () async throws -> T
    ) async throws -> T {
        let outcome: Result<T, any Error>
        do {
            outcome = .success(try await body())
        } catch {
            outcome = .failure(error)
        }
        await service.stop()
        return try outcome.get()
    }

    /// True once `url` answers an HTTP response accepted by `accept`. The rejection
    /// tests use this to prove the stub listener really was live while readiness was
    /// being decided — without it, a starved runner that never got the stub up at all
    /// would pass them for the wrong reason.
    private func waitForHTTPResponse(
        at url: URL,
        timeout: TimeInterval,
        accept: @escaping @Sendable (Int, Data) -> Bool = { status, _ in status > 0 }
    ) async -> Bool {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        return await waitUntil(timeout: timeout, pollInterval: 0.1) {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 2
            guard let (data, response) = try? await session.data(for: request),
                let http = response as? HTTPURLResponse
            else { return false }
            return accept(http.statusCode, data)
        }
    }

    // MARK: - Readiness

    @Test("start reaches ready on healthz ok, with PORT/WEB_NEXT_DATA_DIR/cwd injected")
    func startBecomesReady() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = WebNextServerService(configuration: fixture.configuration(script: fixture.healthzServerScript))

        try await withService(service) {
            await service.start()
            guard case .ready(let signInBaseURL) = await service.state else {
                Issue.record("expected .ready, got \(await service.state)")
                return
            }
            #expect(signInBaseURL == fixture.baseURL)

            let observedPort = try String(
                contentsOf: fixture.dataDir.appendingPathComponent("observed-port"), encoding: .utf8)
            #expect(observedPort.trimmingCharacters(in: .whitespacesAndNewlines) == String(fixture.port))

            let observedCwd = try String(
                contentsOf: fixture.dataDir.appendingPathComponent("observed-cwd"), encoding: .utf8)
            #expect(
                URL(fileURLWithPath: observedCwd.trimmingCharacters(in: .whitespacesAndNewlines))
                    .resolvingSymlinksInPath().path == fixture.root.resolvingSymlinksInPath().path
            )
        }
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
            configuration: fixture.configuration(script: script, readinessTimeout: Self.rejectionBudget))

        // Watch the port while readiness is being decided. Asserting only that the
        // service failed would pass just as happily on a runner too loaded to launch
        // the listener at all; the observation is what makes this a rejection test.
        let listenerObserver = Task {
            await waitForHTTPResponse(at: fixture.baseURL, timeout: Self.rejectionBudget)
        }

        await service.start()
        let listenerWasLive = await listenerObserver.value

        #expect(listenerWasLive, "the foreign listener must have been answering while readiness was decided")
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
        // Paid in full on every run, so it stays as tight as the spawn measurement
        // allows — but it must still outlast the stub's own launch, or the kill
        // assertion below would have no process to check.
        let service = WebNextServerService(
            configuration: fixture.configuration(script: script, readinessTimeout: Self.rejectionBudget))

        // Watch for the stub's PID while readiness is being decided, so a stub that
        // never got far enough to be killed reads differently from a supervisor that
        // failed to kill it.
        let pidURL = fixture.dataDir.appendingPathComponent("server.pid")
        let pidObserver = Task {
            await waitUntil(timeout: Self.rejectionBudget) {
                FileManager.default.fileExists(atPath: pidURL.path)
            }
        }

        await service.start()
        #expect(await pidObserver.value, "the stub must have recorded its PID before the budget expired")

        guard case .failed(let reason) = await service.state else {
            Issue.record("expected .failed, got \(await service.state)")
            return
        }
        #expect(reason.contains("Timed out"))

        let serverPID = try #require(readPID(at: pidURL))
        let died = await waitUntil(timeout: Self.eventBudget) { !self.processIsAlive(serverPID) }
        #expect(died, "spawned process should be terminated after readiness timeout")
    }

    @Test("a cancelled activation does not abort the launch — the server still becomes ready")
    func callerCancellationDoesNotPoisonLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // Delay the healthz listener a beat so cancellation lands while the
        // service is mid-readiness, not after it is already healthy.
        let script = """
            sleep 0.4
            \(fixture.healthzServerScript)
            """
        let service = WebNextServerService(configuration: fixture.configuration(script: script))

        try await withService(service) {
            // Trigger start() from a task we cancel almost immediately — mirroring the
            // user closing the embedded pane during a cold build. If the readiness poll
            // were bound to the caller's task it would busy-spin, auto-cancel every
            // health probe, and time out into a process-killing .failed; the launch must
            // instead run to ready in its own context.
            let starter = Task { await service.start() }
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms: inside the readiness loop
            starter.cancel()

            // Outlive the service's own readiness budget rather than racing a shorter
            // deadline against it.
            let ready = await waitUntil(timeout: Self.readyBudget + Self.eventBudget) {
                if case .ready = await service.state { return true }
                return false
            }
            #expect(ready, "caller cancellation must not prevent the server from reaching .ready")
        }

        #expect(await service.state == .idle)
    }

    @Test("early process exit transitions to failed before the timeout")
    func earlyExitFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // The property is that a dead process is noticed immediately instead of waiting
        // out the readiness budget — a relationship between two durations, so both
        // scale with spawn cost and their ordering survives any load. The bound holds
        // until a single spawn costs more than `fastFailBound`'s ceiling, which is two
        // minutes: past that the whole run is already over.
        let readinessTimeout = SpawnBudget.deadline(spawns: 12, floor: 60, ceiling: 360)
        let fastFailBound = SpawnBudget.deadline(spawns: 3, floor: 15, ceiling: 120)
        #expect(
            fastFailBound * 2 < readinessTimeout,
            "the fast-fail bound must stay well under the budget it proves we did not wait out")

        let service = WebNextServerService(
            configuration: fixture.configuration(script: "exit 1", readinessTimeout: readinessTimeout))

        let startedAt = Date()
        await service.start()

        guard case .failed(let reason) = await service.state else {
            Issue.record("expected .failed, got \(await service.state)")
            return
        }
        #expect(reason.contains("exited before becoming ready"))
        let elapsed = Date().timeIntervalSince(startedAt)
        #expect(elapsed < fastFailBound, "early exit should fail fast, took \(elapsed)s")
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
        let service = WebNextServerService(configuration: fixture.configuration(script: script))

        await service.start()

        guard case .failed(let reason) = await service.state else {
            Issue.record("expected .failed, got \(await service.state)")
            return
        }
        #expect(reason.contains("exited before becoming ready"))

        let childPID = try #require(readPID(at: fixture.dataDir.appendingPathComponent("child.pid")))
        let childDied = await waitUntil(timeout: Self.eventBudget) { !self.processIsAlive(childPID) }
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

        let childPID: pid_t? = try await withService(service) {
            await service.start()
            guard case .ready = await service.state else {
                Issue.record("expected .ready, got \(await service.state)")
                return nil
            }
            let pid = try #require(readPID(at: fixture.dataDir.appendingPathComponent("child.pid")))
            #expect(processIsAlive(pid))
            return pid
        }
        guard let childPID else { return }

        let childDied = await waitUntil(timeout: Self.eventBudget) { !self.processIsAlive(childPID) }
        #expect(childDied, "grandchild should die with the process group")
        #expect(await service.state == .idle)

        await service.stop()
        #expect(await service.state == .idle, "stop is idempotent")
    }

    @Test("stop escalates to SIGKILL when the leader dies but a member ignores SIGTERM")
    func stopEscalatesToSIGKILLForTermIgnoringMember() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = WebNextServerService(
            configuration: fixture.configuration(
                script: fixture.termIgnoringChildScript, terminationGracePeriod: 0.5))

        let childPID: pid_t? = try await withService(service) {
            await service.start()
            guard case .ready = await service.state else {
                Issue.record("expected .ready, got \(await service.state)")
                return nil
            }
            return try await armedTermIgnoringChildPID(in: fixture)
        }
        guard let childPID else { return }

        let childDied = await waitUntil(timeout: Self.eventBudget) { !self.processIsAlive(childPID) }
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

        try await withService(service) {
            await service.start()
            guard case .ready = await service.state else {
                Issue.record("expected .ready, got \(await service.state)")
                return
            }

            let serverPID = try #require(readPID(at: fixture.dataDir.appendingPathComponent("server.pid")))
            kill(serverPID, SIGKILL)

            let failed = await waitUntil(timeout: Self.eventBudget) {
                if case .failed = await service.state { return true }
                return false
            }
            #expect(failed, "watchdog should transition to .failed after the server dies")
            #expect(await service.signInURL(redirect: nil) == nil, "no sign-in URLs for a dead server")
        }
    }

    // MARK: - Sign-in URL

    @Test("signInURL builds token + redirect URL from the token file, and the token never reaches logs")
    func signInURLFromTokenFile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = WebNextServerService(configuration: fixture.configuration(script: fixture.healthzServerScript))

        try await withService(service) {
            await service.start()
            guard case .ready = await service.state else {
                Issue.record("expected .ready, got \(await service.state)")
                return
            }

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
        }
    }

    @Test("readiness rejects healthz without localMode true")
    func readinessRequiresLocalMode() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let script = """
            export HEALTHZ_BODY='{"ok": true, "localMode": false}'
            \(fixture.healthzServerScript)
            """
        let service = WebNextServerService(
            configuration: fixture.configuration(script: script, readinessTimeout: Self.rejectionBudget))

        // As in the foreign-listener test: observe that a healthz endpoint really was
        // answering during the readiness window, so `.failed` means "rejected for
        // localMode:false" and not "nothing ever came up".
        let healthzURL = fixture.baseURL.appendingPathComponent("api/healthz")
        let healthzObserver = Task {
            await waitForHTTPResponse(at: healthzURL, timeout: Self.rejectionBudget) { status, data in
                status == 200 && String(decoding: data, as: UTF8.self).contains("\"localMode\": false")
            }
        }

        try await withService(service) {
            await service.start()
            let healthzAnswered = await healthzObserver.value
            #expect(healthzAnswered, "the localMode:false healthz endpoint must have been live and answering")
            guard case .failed = await service.state else {
                Issue.record("localMode:false must not satisfy readiness, got \(await service.state)")
                return
            }
        }
    }

    // MARK: - Log redaction

    @Test("redactSignInToken masks token values, keeps surrounding text")
    func redactsTokenValue() {
        let line = "Local sign-in: http://127.0.0.1:3140/sign-in?token=abc.DEF-123&redirect=/"
        let out = WebNextServerService.redactSignInToken(in: line)
        #expect(out == "Local sign-in: http://127.0.0.1:3140/sign-in?token=<redacted>&redirect=/")
        #expect(!out.contains("abc.DEF-123"))
        #expect(WebNextServerService.redactSignInToken(in: "no tokens here") == "no tokens here")
    }

    @Test("captured server logs redact bearer tokens before they reach disk")
    func serverLogsRedactToken() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let secret = "SECRET-\(UUID().uuidString)"
        let script = """
            echo "Local sign-in: http://127.0.0.1:$PORT/sign-in?token=\(secret)&redirect=/"
            \(fixture.healthzServerScript)
            """
        let service = WebNextServerService(configuration: fixture.configuration(script: script))

        try await withService(service) {
            await service.start()
            guard case .ready = await service.state else {
                Issue.record("expected .ready, got \(await service.state)")
                return
            }

            let logURL = try #require(await service.logFileURL)
            let redacted = await waitUntil(timeout: Self.eventBudget) {
                let contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                return contents.contains("token=<redacted>") && !contents.contains(secret)
            }
            #expect(redacted, "log must show token=<redacted> and never the raw secret")

            // When capturing evidence, emit the real on-disk log so the PR can show
            // the redacted line (never the secret) as proof.
            if let dir = ProcessInfo.processInfo.environment["WORKSPACES_EVIDENCE_DIR"],
                let contents = try? String(contentsOf: logURL, encoding: .utf8)
            {
                try? contents.write(
                    to: URL(fileURLWithPath: dir).appendingPathComponent("redacted-server-log.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }

    // MARK: - Termination budget

    @Test(
        "stopForTermination finishes under the OS terminate budget and still SIGKILLs",
        .disabled(
            if: ProcessInfo.processInfo.environment["CI"] != nil,
            """
            Asserts a hard <4s wall-clock compression against the OS terminate grace period. \
            That ceiling is imposed by the OS and does not scale with runner load, so unlike the \
            rest of this suite the bound cannot be derived from a measured spawn baseline — and \
            loosening it to absorb scheduling noise would hide a real regression in the \
            compression logic itself. Runs locally.
            """
        )
    )
    func stopForTerminationBudget() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // A full 5s grace here; stopForTermination must compress it under budget.
        let service = WebNextServerService(
            configuration: fixture.configuration(
                script: fixture.termIgnoringChildScript, terminationGracePeriod: 5))

        await service.start()
        guard case .ready = await service.state else {
            Issue.record("expected .ready, got \(await service.state)")
            await service.stop()
            return
        }
        guard let childPID = try await armedTermIgnoringChildPID(in: fixture) else {
            await service.stop()
            return
        }

        let started = Date()
        await service.stopForTermination()
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 4, "terminate path must finish under the OS budget, took \(elapsed)s")

        let childDied = await waitUntil(timeout: Self.eventBudget) { !self.processIsAlive(childPID) }
        #expect(childDied, "a SIGTERM-ignoring member must still be SIGKILLed")
        #expect(await service.state == .idle)
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

    /// PID of the SIGTERM-ignoring group member, once it has confirmed its handler is
    /// installed. Waiting on the marker rather than on elapsed time is what keeps the
    /// escalation tests from racing SIGTERM against handler installation.
    private func armedTermIgnoringChildPID(in fixture: Fixture) async throws -> pid_t? {
        let armedURL = fixture.dataDir.appendingPathComponent("term-ignorer-armed")
        let armed = await waitUntil(timeout: Self.eventBudget) {
            FileManager.default.fileExists(atPath: armedURL.path)
        }
        guard armed else {
            Issue.record("the SIGTERM-ignoring child never armed")
            return nil
        }
        let childPID = try #require(readPID(at: fixture.dataDir.appendingPathComponent("child.pid")))
        #expect(processIsAlive(childPID))
        return childPID
    }
}
