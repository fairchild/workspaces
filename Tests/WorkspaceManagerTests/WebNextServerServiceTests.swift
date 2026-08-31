//
//  WebNextServerServiceTests.swift
//  WorkspaceManagerTests
//
//  Behavior tests for the local-mode web-next supervisor: state transitions,
//  strict healthz readiness, process-group termination, post-ready watchdog,
//  and sign-in URL construction — all against stub shell commands so no test
//  needs pnpm or a web-next checkout.
//
//  Deadlines here are multiples of `LaunchBudget`'s measured launch-to-first-response
//  cost rather than fixed wall clocks, because that cost is the term that varies by two
//  orders of magnitude between a laptop and a loaded hosted runner — ~0.3s here against
//  ~35s on the runner that produced this suite's third gating.
//

import Darwin
import Foundation
import Testing

@testable import WorkspaceManagerCore

/// `.serialized` because these tests are launch-bound rather than CPU-bound: run
/// concurrently, the suite becomes its own largest source of load, and `LaunchBudget`'s
/// serially-measured baseline then under-predicts what each test actually pays. One
/// stub process group at a time keeps the measurement honest and the budgets derived
/// from it meaningful.
@Suite("WebNextServerService", .serialized)
struct WebNextServerServiceTests {
    // MARK: - Budgets
    //
    // Each is a multiple of one measured launch: `/bin/sh`, `python3`, the imports, the
    // bind, and the first successful HTTP response. Read at use time rather than cached
    // in a `static let`, so a baseline that grew mid-run widens the budgets after it.

    /// Reaching `.ready` is one whole launch — the same round trip the baseline
    /// measures — so 3x is the margin, not the estimate. Used where readiness is a
    /// precondition rather than the property under test.
    private static func readyBudget() async -> TimeInterval {
        await LaunchBudget.deadline(launches: 3, floor: 45, ceiling: 360)
    }

    /// Budget for a side effect of an already-running process — a signal landing, a
    /// process group draining, a marker file appearing. Cheaper than a launch, though
    /// the SIGTERM-ignoring child does have to start, and the scheduler that starves
    /// launches delays the rest.
    private static func eventBudget() async -> TimeInterval {
        await LaunchBudget.deadline(launches: 1.5, floor: 20, ceiling: 240)
    }

    /// Budget for the rejection tests, which wait for their stub's listener to answer
    /// and then assert the service refused it. One launch plus margin, and being
    /// generous costs nothing because the observation ends the wait, not the clock.
    private static func rejectionBudget() async -> TimeInterval {
        await LaunchBudget.deadline(launches: 3, floor: 60, ceiling: 360)
    }

    /// Window a rejected server is watched for a late transition to `.ready` after its
    /// endpoint started answering — at least eight readiness polls wide, so the service
    /// has demonstrably seen the listener and declined it rather than not looked yet.
    /// It waits on scheduling rather than on a launch, so it is a fraction of the
    /// baseline; it is also the only budget paid in full on a passing run, since
    /// nothing is expected to happen during it.
    private static func settleBudget() async -> TimeInterval {
        await LaunchBudget.deadline(launches: 0.2, floor: 2, ceiling: 15)
    }

    /// Budget for the one test whose property *is* the readiness timeout, so it waits
    /// the whole thing out by construction. Its stub only needs `/bin/sh` — no
    /// interpreter, no listener — so it is a fraction of a full launch.
    private static func timeoutBudget() async -> TimeInterval {
        await LaunchBudget.deadline(launches: 0.5, floor: 8, ceiling: 240, refreshing: true)
    }

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
            port = try LaunchBudget.findFreePort()
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
            readinessTimeout: TimeInterval,
            // A quarter second is fast enough to keep local runs snappy while cutting
            // the connection-refused churn a 0.1s poll generates across a whole suite.
            readinessPollInterval: TimeInterval = 0.25,
            terminationGracePeriod: TimeInterval = 1,
            watchdogInterval: TimeInterval = 5,
            watchdogFailureThreshold: Int = 3,
            extraLocalOrigins: [String] = []
        ) -> WebNextServerConfiguration {
            WebNextServerConfiguration(
                webNextRoot: root,
                port: port,
                dataDir: dataDir,
                logDirectory: root.appendingPathComponent("logs", isDirectory: true),
                launchCommand: WebNextLaunchCommand(executablePath: "/bin/sh", arguments: ["-c", script]),
                extraLocalOriginsProvider: { extraLocalOrigins },
                readinessTimeout: readinessTimeout,
                readinessPollInterval: readinessPollInterval,
                terminationGracePeriod: terminationGracePeriod,
                watchdogInterval: watchdogInterval,
                watchdogFailureThreshold: watchdogFailureThreshold
            )
        }

        /// Stub server: records env/cwd the service injected and its own PID, then
        /// answers `/api/healthz` with `200 {"ok": true}` on the configured port.
        /// `exec` keeps that PID, so `server.pid` identifies the listening process —
        /// which is what lets a test tie an observed HTTP response to the stub it
        /// launched, and reap the process if a teardown assertion fails.
        var healthzServerScript: String {
            """
            echo "$PORT" > "$WEB_NEXT_DATA_DIR/observed-port"
            pwd > "$WEB_NEXT_DATA_DIR/observed-cwd"
            echo $$ > "$WEB_NEXT_DATA_DIR/server.pid"
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

    /// Last-resort reap. The assertion that a process should already be gone has
    /// been recorded by the time this runs; killing the survivor anyway keeps one
    /// failure from becoming many, since a leaked `sleep 300` or Python server loads
    /// the machine for every test that follows it.
    private func reapIfAlive(_ pid: pid_t?) {
        guard let pid, processIsAlive(pid) else { return }
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
    }

    /// Waits for a PID file the stub writes, then reads it. Waiting rather than
    /// reading immediately is what separates "the stub never got far enough" from
    /// "the supervisor failed to act on it".
    private func awaitPID(at url: URL) async -> pid_t? {
        let appeared = await waitUntilLaunchScaled(launches: 1.5, floor: 20, ceiling: 240) {
            FileManager.default.fileExists(atPath: url.path)
        }
        guard appeared else { return nil }
        return readPID(at: url)
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

    /// True once the rejection stubs' listener is answering a response `accept` agrees
    /// is theirs. The rejection tests use this to prove the stub really was live while
    /// readiness was being decided — without it, a runner too loaded to get the stub up
    /// at all would pass them for the wrong reason. Launch-scaled and re-measuring on a
    /// miss, because everything before the first response is process launch: `/bin/sh`,
    /// then `python3`, then the bind.
    private func rejectedListenerIsLive(
        at url: URL,
        accept: @escaping @Sendable (Int, Data) -> Bool = { status, _ in status > 0 }
    ) async -> Bool {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        return await waitUntilLaunchScaled(launches: 3, floor: 60, ceiling: 360) {
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
        let service = WebNextServerService(
            configuration: fixture.configuration(
                script: fixture.healthzServerScript, readinessTimeout: await Self.readyBudget()))

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

    @Test("configured extra local origins reach the child as WEB_NEXT_EXTRA_LOCAL_ORIGINS")
    func extraLocalOriginsInjected() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let script = """
            echo "${WEB_NEXT_EXTRA_LOCAL_ORIGINS:-unset}" > "$WEB_NEXT_DATA_DIR/observed-origins"
            \(fixture.healthzServerScript)
            """
        let service = WebNextServerService(
            configuration: fixture.configuration(
                script: script,
                readinessTimeout: await Self.readyBudget(),
                extraLocalOrigins: ["https://mac.tail.ts.net", "https://second.example"]))

        try await withService(service) {
            await service.start()
            guard case .ready = await service.state else {
                Issue.record("expected .ready, got \(await service.state)")
                return
            }
            let observed = try String(
                contentsOf: fixture.dataDir.appendingPathComponent("observed-origins"),
                encoding: .utf8)
            #expect(
                observed.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "https://mac.tail.ts.net,https://second.example")
        }
    }

    @Test("an HTTP listener without healthz never becomes ready — stale/foreign ports are rejected")
    func readinessRejectsNonHealthzListener() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // python http.server answers every path (404 for /api/healthz) — an HTTP
        // response, but not a healthy web-next. Must not satisfy readiness.
        // `exec` keeps the recorded PID, so the listener is identifiably ours.
        let script = """
            echo $$ > "$WEB_NEXT_DATA_DIR/server.pid"
            exec python3 -m http.server "$PORT" --bind 127.0.0.1
            """
        let service = WebNextServerService(
            configuration: fixture.configuration(script: script, readinessTimeout: await Self.rejectionBudget()))

        // The property is the refusal, so the test ends when the refusal is observable
        // — once the listener answers and the service has polled it without going
        // ready. Waiting out the readiness timeout instead would prove the same thing
        // far more slowly, and would pass just as happily on a runner too loaded to
        // launch the listener at all.
        let starter = Task { await service.start() }
        let listenerWasLive = await rejectedListenerIsLive(at: fixture.baseURL)

        let serverPID = readPID(at: fixture.dataDir.appendingPathComponent("server.pid"))
        #expect(listenerWasLive, "the foreign listener must have been answering while readiness was decided")
        #expect(serverPID != nil, "the answering listener must be the process this service launched")

        let wentReady = await waitUntil(timeout: await Self.settleBudget()) {
            if case .ready = await service.state { return true }
            return false
        }
        #expect(!wentReady, "a listener with no healthz must never satisfy readiness")

        // `stop()` bumps the generation the launch checks each poll, so awaiting the
        // starter here ends it rather than leaving it running past the test.
        await service.stop()
        await starter.value
        reapIfAlive(serverPID)
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
            configuration: fixture.configuration(
                script: script, readinessTimeout: await Self.timeoutBudget()))

        await service.start()

        guard case .failed(let reason) = await service.state else {
            Issue.record("expected .failed, got \(await service.state)")
            return
        }
        #expect(reason.contains("Timed out"))

        let serverPID = try #require(
            readPID(at: fixture.dataDir.appendingPathComponent("server.pid")),
            "the stub must have recorded its PID before the readiness budget expired")
        defer { reapIfAlive(serverPID) }
        let died = await waitUntilLaunchScaled(launches: 1.5, floor: 20, ceiling: 240) {
            !self.processIsAlive(serverPID)
        }
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
        let service = WebNextServerService(
            configuration: fixture.configuration(script: script, readinessTimeout: await Self.readyBudget()))

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
            // deadline against it — the extra `sleep 0.4` plus its shell put this
            // launch one step behind the plain healthz stub.
            let ready = await waitUntilLaunchScaled(launches: 4, floor: 65, ceiling: 480) {
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
        // scale with launch cost and their ordering survives any load.
        let readinessTimeout = await LaunchBudget.deadline(launches: 4, floor: 60, ceiling: 600)
        var fastFailBound = await LaunchBudget.deadline(launches: 1, floor: 15, ceiling: 180)
        #expect(
            fastFailBound * 2 < readinessTimeout,
            "the fast-fail bound must stay well under the budget it proves we did not wait out")

        let script = """
            echo 1 > "$WEB_NEXT_DATA_DIR/script-ran"
            exit 1
            """
        let service = WebNextServerService(
            configuration: fixture.configuration(script: script, readinessTimeout: readinessTimeout))

        let startedAt = Date()
        await service.start()
        let elapsed = Date().timeIntervalSince(startedAt)

        guard case .failed(let reason) = await service.state else {
            Issue.record("expected .failed, got \(await service.state)")
            return
        }
        #expect(reason.contains("exited before becoming ready"))
        #expect(
            FileManager.default.fileExists(atPath: fixture.dataDir.appendingPathComponent("script-ran").path),
            "the failure must come from the script running and exiting, not from a launch that never ran it")

        // Missing the bound may mean the machine slowed down since the baseline was
        // taken rather than that detection regressed. Re-measure before calling it a
        // regression, capped so the comparison cannot widen into vacuity.
        if elapsed >= fastFailBound {
            fastFailBound = min(
                readinessTimeout * 0.75,
                await LaunchBudget.deadline(launches: 1, floor: 15, ceiling: 180, refreshing: true))
        }
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
        let service = WebNextServerService(
            configuration: fixture.configuration(script: script, readinessTimeout: await Self.readyBudget()))

        await service.start()

        guard case .failed(let reason) = await service.state else {
            Issue.record("expected .failed, got \(await service.state)")
            return
        }
        #expect(reason.contains("exited before becoming ready"))

        let childPID = try #require(readPID(at: fixture.dataDir.appendingPathComponent("child.pid")))
        defer { reapIfAlive(childPID) }
        let childDied = await waitUntilLaunchScaled(launches: 1.5, floor: 20, ceiling: 240) {
            !self.processIsAlive(childPID)
        }
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
        let service = WebNextServerService(
            configuration: fixture.configuration(script: script, readinessTimeout: await Self.readyBudget()))

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
        defer { reapIfAlive(childPID) }

        let childDied = await waitUntilLaunchScaled(launches: 1.5, floor: 20, ceiling: 240) {
            !self.processIsAlive(childPID)
        }
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
                script: fixture.termIgnoringChildScript,
                readinessTimeout: await Self.readyBudget(),
                terminationGracePeriod: 0.5))

        let childPID: pid_t? = try await withService(service) {
            await service.start()
            guard case .ready = await service.state else {
                Issue.record("expected .ready, got \(await service.state)")
                return nil
            }
            return await armedTermIgnoringChildPID(in: fixture)
        }
        guard let childPID else { return }
        defer { reapIfAlive(childPID) }

        let childDied = await waitUntilLaunchScaled(launches: 1.5, floor: 20, ceiling: 240) {
            !self.processIsAlive(childPID)
        }
        #expect(childDied, "a SIGTERM-ignoring group member must be SIGKILLed even after the leader exits")
        #expect(await service.state == .idle)
    }

    // MARK: - Watchdog

    @Test("watchdog fails the state when the server dies after becoming ready")
    func watchdogDetectsServerDeath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = WebNextServerService(
            configuration: fixture.configuration(
                script: fixture.healthzServerScript,
                readinessTimeout: await Self.readyBudget(),
                watchdogInterval: 0.15))

        try await withService(service) {
            await service.start()
            guard case .ready = await service.state else {
                Issue.record("expected .ready, got \(await service.state)")
                return
            }

            let serverPID = try #require(readPID(at: fixture.dataDir.appendingPathComponent("server.pid")))
            kill(serverPID, SIGKILL)

            let failed = await waitUntilLaunchScaled(launches: 1.5, floor: 20, ceiling: 240) {
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
        let service = WebNextServerService(
            configuration: fixture.configuration(
                script: fixture.healthzServerScript, readinessTimeout: await Self.readyBudget()))

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
            configuration: fixture.configuration(script: script, readinessTimeout: await Self.rejectionBudget()))

        // As in the foreign-listener test: the refusal is the property, and it becomes
        // observable as soon as a healthz endpoint is answering and the service has
        // polled it without going ready. Requiring the body distinguishes "rejected for
        // localMode:false" from "nothing ever came up".
        let healthzURL = fixture.baseURL.appendingPathComponent("api/healthz")
        let starter = Task { await service.start() }
        let healthzAnswered = await rejectedListenerIsLive(at: healthzURL) { status, data in
            status == 200 && String(decoding: data, as: UTF8.self).contains("\"localMode\": false")
        }

        let serverPID = readPID(at: fixture.dataDir.appendingPathComponent("server.pid"))
        #expect(healthzAnswered, "the localMode:false healthz endpoint must have been live and answering")
        #expect(serverPID != nil, "the answering endpoint must be the process this service launched")

        let wentReady = await waitUntil(timeout: await Self.settleBudget()) {
            if case .ready = await service.state { return true }
            return false
        }
        #expect(!wentReady, "localMode:false must not satisfy readiness")

        await service.stop()
        await starter.value
        reapIfAlive(serverPID)
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
        let service = WebNextServerService(
            configuration: fixture.configuration(script: script, readinessTimeout: await Self.readyBudget()))

        try await withService(service) {
            await service.start()
            guard case .ready = await service.state else {
                Issue.record("expected .ready, got \(await service.state)")
                return
            }

            let logURL = try #require(await service.logFileURL)
            let redacted = await waitUntilLaunchScaled(launches: 1.5, floor: 20, ceiling: 240) {
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
            rest of this suite the bound cannot be derived from a measured launch baseline — and \
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
                script: fixture.termIgnoringChildScript,
                readinessTimeout: await Self.readyBudget(),
                terminationGracePeriod: 5))

        // `withService`'s trailing stop is a no-op after `stopForTermination` succeeds
        // and the guaranteed teardown when anything above it exits early.
        let childPID: pid_t? = try await withService(service) {
            await service.start()
            guard case .ready = await service.state else {
                Issue.record("expected .ready, got \(await service.state)")
                return nil
            }
            guard let childPID = await armedTermIgnoringChildPID(in: fixture) else { return nil }

            let started = Date()
            await service.stopForTermination()
            let elapsed = Date().timeIntervalSince(started)
            #expect(elapsed < 4, "terminate path must finish under the OS budget, took \(elapsed)s")
            return childPID
        }
        guard let childPID else { return }
        defer { reapIfAlive(childPID) }

        let childDied = await waitUntilLaunchScaled(launches: 1.5, floor: 20, ceiling: 240) {
            !self.processIsAlive(childPID)
        }
        #expect(childDied, "a SIGTERM-ignoring member must still be SIGKILLed")
        #expect(await service.state == .idle)
    }

    @Test("signInURL is nil while not ready")
    func signInURLNilWhenNotReady() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = WebNextServerService(
            configuration: fixture.configuration(script: "exit 0", readinessTimeout: 1))

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
    /// escalation tests from racing SIGTERM against handler installation. Returns nil
    /// rather than throwing so a caller mid-teardown always reaches its own cleanup.
    private func armedTermIgnoringChildPID(in fixture: Fixture) async -> pid_t? {
        let armedURL = fixture.dataDir.appendingPathComponent("term-ignorer-armed")
        let armed = await waitUntilLaunchScaled(launches: 1.5, floor: 20, ceiling: 240) {
            FileManager.default.fileExists(atPath: armedURL.path)
        }
        guard armed else {
            Issue.record("the SIGTERM-ignoring child never armed")
            return nil
        }
        guard let childPID = await awaitPID(at: fixture.dataDir.appendingPathComponent("child.pid")) else {
            Issue.record("the SIGTERM-ignoring child never recorded its PID")
            return nil
        }
        #expect(processIsAlive(childPID))
        return childPID
    }
}
