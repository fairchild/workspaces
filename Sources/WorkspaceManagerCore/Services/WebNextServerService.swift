//
//  WebNextServerService.swift
//  WorkspaceManagerCore
//
//  Spawns and supervises the local-mode web-next server (`pnpm run start:local`)
//  in its own process group, requires a healthy `/api/healthz` for readiness,
//  watches the server after it becomes ready, and builds token-bearing sign-in
//  URLs for the embedded web UI. The entrypoint does not forward signals to its
//  `next start` child, so shutdown terminates the whole process group
//  (SIGTERM → bounded grace → SIGKILL until the group is empty).
//

import Foundation

// MARK: - State

public enum WebNextServerState: Sendable, Equatable {
    case idle
    case starting
    case ready(signInBaseURL: URL)
    case failed(reason: String)

    public var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .starting:
            return "Starting"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed"
        }
    }
}

// MARK: - Configuration

/// The command that launches the server, injectable so tests can substitute a
/// stub script and never require pnpm or a web-next checkout.
public struct WebNextLaunchCommand: Sendable, Equatable {
    public var executablePath: String
    public var arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }

    public static let `default` = WebNextLaunchCommand(
        executablePath: "/usr/bin/env",
        arguments: ["pnpm", "run", "start:local"]
    )
}

public struct WebNextServerConfiguration: Sendable {
    /// Checkout containing the web-next app; the launch command's working directory.
    public var webNextRoot: URL
    public var port: Int
    /// App-managed directory passed as `WEB_NEXT_DATA_DIR`; the server creates
    /// `local-sign-in-token` (0600) inside it once ready.
    public var dataDir: URL
    /// Where per-launch server logs (captured child stdout/stderr) are written.
    public var logDirectory: URL
    public var launchCommand: WebNextLaunchCommand
    /// Extra exact-match origins forwarded to the child as
    /// `WEB_NEXT_EXTRA_LOCAL_ORIGINS`, so a trusted reverse proxy
    /// (`tailscale serve`) can front the loopback bind for mobile pairing.
    /// A provider, not a value: resolution can shell out (Tailscale CLI),
    /// so it runs at spawn time — off the launch path, and fresh for every
    /// relaunch — never at configuration time.
    public var extraLocalOriginsProvider: @Sendable () -> [String]
    /// How long to wait for `/api/healthz` after spawn before declaring failure.
    /// Sized for a cold first run: `start:local` builds web-next when
    /// `.next/BUILD_ID` is absent, which takes one to two minutes. A generous
    /// budget is safe because a process that dies mid-build is detected
    /// independently and fails fast (see `start()`); this only bounds the
    /// alive-but-not-yet-serving window, which is precisely the build.
    public var readinessTimeout: TimeInterval
    public var readinessPollInterval: TimeInterval
    /// How long termination waits after SIGTERM before escalating to SIGKILL.
    public var terminationGracePeriod: TimeInterval
    /// How often the post-ready watchdog checks process liveness and health.
    public var watchdogInterval: TimeInterval
    /// Consecutive failed health checks before the watchdog declares the server dead.
    public var watchdogFailureThreshold: Int

    public init(
        webNextRoot: URL,
        port: Int = 3140,
        dataDir: URL? = nil,
        logDirectory: URL? = nil,
        launchCommand: WebNextLaunchCommand = .default,
        extraLocalOriginsProvider: @escaping @Sendable () -> [String] = { [] },
        readinessTimeout: TimeInterval = 180,
        readinessPollInterval: TimeInterval = 0.5,
        terminationGracePeriod: TimeInterval = 5,
        watchdogInterval: TimeInterval = 5,
        watchdogFailureThreshold: Int = 3
    ) {
        precondition((1...65535).contains(port), "port must be a valid TCP port, got \(port)")
        let resolvedDataDir = dataDir ?? Self.defaultDataDirectory()
        self.webNextRoot = webNextRoot
        self.port = port
        self.dataDir = resolvedDataDir
        self.logDirectory = logDirectory ?? resolvedDataDir.appendingPathComponent("logs", isDirectory: true)
        self.launchCommand = launchCommand
        self.extraLocalOriginsProvider = extraLocalOriginsProvider
        self.readinessTimeout = readinessTimeout
        self.readinessPollInterval = readinessPollInterval
        self.terminationGracePeriod = terminationGracePeriod
        self.watchdogInterval = watchdogInterval
        self.watchdogFailureThreshold = watchdogFailureThreshold
    }

    public static func defaultDataDirectory(fileManager: FileManager = .default) -> URL {
        let appSupport =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return
            appSupport
            .appendingPathComponent("WorkspaceManager", isDirectory: true)
            .appendingPathComponent("web-next", isDirectory: true)
    }
}

// MARK: - Service

public actor WebNextServerService: WebNextServerServiceProtocol {
    public private(set) var state: WebNextServerState = .idle
    /// Log file for the current (or most recent) launch, for the UI slice to surface.
    public private(set) var logFileURL: URL?

    private let configuration: WebNextServerConfiguration
    private let urlSession: URLSession
    private let fileManager: FileManager
    private var processID: pid_t?
    /// Bumped by every `start()`/`stop()`; in-flight readiness polls and the
    /// watchdog compare against it so a superseded launch never overwrites
    /// current state or another launch's process handle.
    private var generation: UInt64 = 0
    private var watchdogTask: Task<Void, Never>?
    /// Pumps captured child stdout/stderr through token redaction onto disk.
    private var logReaderTask: Task<Void, Never>?

    private static let signInTokenFilename = "local-sign-in-token"

    /// Query-value encoding for the sign-in URL. `URLQueryItem` leaves `+`
    /// literal, which servers commonly decode as a space — encode it (and the
    /// query structure characters) so redirect paths round-trip exactly.
    private static let queryValueAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return allowed
    }()

    public init(
        configuration: WebNextServerConfiguration,
        urlSession: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.fileManager = fileManager
    }

    public var baseURL: URL {
        // swift-format-ignore: NeverForceUnwrap
        // Safe: fixed scheme/host plus WebNextServerConfiguration's init-validated port
        // (1...65535) always forms a valid URL — an out-of-range port can't reach here.
        URL(string: "http://127.0.0.1:\(configuration.port)")!
    }

    // MARK: Lifecycle

    /// Spawn the server and wait until `/api/healthz` reports healthy or the
    /// readiness timeout elapses. Returns immediately when already starting or
    /// ready. Cancelling the caller does not abort the launch: the server is a
    /// process-wide resource whose bring-up is owned by the actor, so a cancelled
    /// activation leaves it coming up (and available on reopen) rather than
    /// killing a build in flight.
    public func start() async {
        switch state {
        case .starting, .ready:
            return
        case .idle, .failed:
            break
        }

        generation &+= 1
        let launchGeneration = generation
        cancelWatchdog()
        state = .starting

        let pid: pid_t
        do {
            try prepareDirectories()
            pid = try spawnServer()
        } catch {
            state = .failed(reason: "Failed to launch web-next server: \(error.localizedDescription)")
            return
        }
        processID = pid

        // Own the readiness poll as an unstructured task so it runs in a fresh,
        // non-cancelled context. If the triggering caller is cancelled mid-launch
        // (e.g. the user closes the pane during a cold build), an inline poll would
        // busy-spin and its health probes would auto-cancel — never observing
        // readiness and forcing a spurious timeout-kill of a live build. The
        // launch's lifetime is owned by the actor + generation, not the caller;
        // `await launch.value` keeps start()'s "blocks until terminal" contract.
        let launch = Task { await self.awaitReadiness(pid: pid, launchGeneration: launchGeneration) }
        await launch.value
    }

    /// Poll `/api/healthz` until it reports healthy, the process exits, or the
    /// readiness timeout elapses — then transition state. Runs as an unstructured
    /// task (see `start()`) so caller cancellation cannot poison the launch;
    /// generation guards drop the outcome if a newer `start()`/`stop()`
    /// superseded it.
    private func awaitReadiness(pid: pid_t, launchGeneration: UInt64) async {
        let deadline = Date().addingTimeInterval(configuration.readinessTimeout)
        while Date() < deadline {
            guard generation == launchGeneration else { return }

            if processHasExited(pid) {
                // The leader may have left group members behind (e.g. a child
                // holding the port) — clean up the whole group before failing.
                await terminateProcessGroup(pid)
                guard generation == launchGeneration else { return }
                if processID == pid { processID = nil }
                state = .failed(
                    reason: "web-next server exited before becoming ready; see \(logFileURL?.path ?? "logs")"
                )
                return
            }

            if await serverIsHealthy() {
                guard generation == launchGeneration else { return }
                state = .ready(signInBaseURL: baseURL)
                startWatchdog(pid: pid, launchGeneration: launchGeneration)
                return
            }

            try? await Task.sleep(nanoseconds: UInt64(configuration.readinessPollInterval * 1_000_000_000))
        }

        guard generation == launchGeneration else { return }
        await terminateProcessGroup(pid)
        guard generation == launchGeneration else { return }
        if processID == pid { processID = nil }
        state = .failed(
            reason:
                "Timed out after \(Int(configuration.readinessTimeout))s waiting for web-next health on port \(configuration.port)."
        )
    }

    /// Terminate the whole process group: SIGTERM, bounded grace, SIGKILL.
    /// Idempotent — safe to call in any state, including mid-start.
    public func stop() async {
        await stopInternal(gracePeriod: configuration.terminationGracePeriod)
    }

    /// Shutdown variant for the app-termination hook, which runs inside the OS's
    /// ~5s terminate budget. Uses a compressed SIGTERM grace so the full
    /// SIGTERM → grace → SIGKILL → reap path completes well under that budget;
    /// the default `stop()` grace would risk the app being killed mid-cleanup,
    /// orphaning the child the hook exists to reap.
    public func stopForTermination() async {
        await stopInternal(gracePeriod: min(configuration.terminationGracePeriod, 1.5))
    }

    private func stopInternal(gracePeriod: TimeInterval) async {
        generation &+= 1
        cancelWatchdog()
        let pid = processID
        processID = nil
        if let pid {
            await terminateProcessGroup(pid, gracePeriod: gracePeriod)
        }
        state = .idle
    }

    // MARK: Sign-in

    /// Sign-in URL carrying the server-minted bearer token, or nil while the
    /// server is not ready or the token file has not been written yet. The
    /// token stays in the returned URL only — it is never logged.
    public func signInURL(redirect: String?) -> URL? {
        guard case .ready(let signInBaseURL) = state else { return nil }
        let tokenFileURL = configuration.dataDir.appendingPathComponent(Self.signInTokenFilename)
        guard let rawToken = try? String(contentsOf: tokenFileURL, encoding: .utf8) else { return nil }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        var components = URLComponents(
            url: signInBaseURL.appendingPathComponent("sign-in"),
            resolvingAgainstBaseURL: false
        )
        var query = "token=\(Self.encodeQueryValue(token))"
        if let redirect {
            query += "&redirect=\(Self.encodeQueryValue(redirect))"
        }
        components?.percentEncodedQuery = query
        return components?.url
    }

    private static func encodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowedCharacters) ?? value
    }

    // MARK: Spawning

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: configuration.dataDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: configuration.logDirectory, withIntermediateDirectories: true)
    }

    private func spawnServer() throws -> pid_t {
        let logURL = makeLogFileURL()
        logFileURL = logURL

        let logFD = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard logFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        // The child writes to the pipe, not straight to the log file, so a
        // reader can redact bearer tokens (`start:local` prints the sign-in URL,
        // token and all) before they land on disk.
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            close(logFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let readEnd = pipeFDs[0]
        let writeEnd = pipeFDs[1]

        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = String(configuration.port)
        environment["WEB_NEXT_DATA_DIR"] = configuration.dataDir.path
        let extraLocalOrigins = configuration.extraLocalOriginsProvider()
        if !extraLocalOrigins.isEmpty {
            environment["WEB_NEXT_EXTRA_LOCAL_ORIGINS"] =
                extraLocalOrigins.joined(separator: ",")
        }

        let pid: pid_t
        do {
            pid = try Self.spawnInNewProcessGroup(
                executablePath: configuration.launchCommand.executablePath,
                arguments: configuration.launchCommand.arguments,
                environment: environment,
                workingDirectory: configuration.webNextRoot.path,
                outputFD: writeEnd
            )
        } catch {
            close(readEnd)
            close(writeEnd)
            close(logFD)
            throw error
        }

        // Only the child writes; drop the parent's write end so the reader sees
        // EOF once the child group exits. The reader owns `readEnd` and `logFD`.
        close(writeEnd)
        startLogRedactionReader(readEnd: readEnd, logFD: logFD)
        return pid
    }

    /// Streams `readEnd` to `logFD`, redacting any `token=<value>` occurrence
    /// line by line. Ends at EOF (child group gone); the detached task never
    /// touches actor state, so it needs no isolation.
    private func startLogRedactionReader(readEnd: Int32, logFD: Int32) {
        logReaderTask?.cancel()
        logReaderTask = Task.detached(priority: .utility) {
            Self.pumpRedactedLog(readEnd: readEnd, logFD: logFD)
        }
    }

    private nonisolated static func pumpRedactedLog(readEnd: Int32, logFD: Int32) {
        defer {
            close(readEnd)
            close(logFD)
        }
        var pending: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(readEnd, &chunk, chunk.count)
            if count <= 0 { break }
            pending.append(contentsOf: chunk[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                writeRedactedLine(Array(pending[0...newline]), to: logFD)
                pending.removeSubrange(0...newline)
            }
        }
        if !pending.isEmpty {
            writeRedactedLine(pending, to: logFD)
        }
    }

    private nonisolated static func writeRedactedLine(_ line: [UInt8], to logFD: Int32) {
        let bytes = Array(redactSignInToken(in: String(decoding: line, as: UTF8.self)).utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer in
                write(logFD, buffer.baseAddress, buffer.count)
            }
            if written <= 0 { break }
            offset += written
        }
    }

    /// Replace any `token=<value>` with `token=<redacted>` so a captured
    /// `Local sign-in: …?token=<bearer>` line never persists the secret.
    nonisolated static func redactSignInToken(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "token=[^\\s&\"']+") else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "token=<redacted>"
        )
    }

    private func makeLogFileURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let stamp = formatter.string(from: Date())
        return configuration.logDirectory.appendingPathComponent("web-next-server-\(stamp).log")
    }

    /// posix_spawn with `POSIX_SPAWN_SETPGROUP` so the child leads a fresh
    /// process group (pgid == pid). Foundation's `Process` cannot express this,
    /// and without it a group signal cannot reach the entrypoint's `next start`
    /// child. stdout/stderr are redirected to `outputFD`; stdin to /dev/null.
    private static func spawnInNewProcessGroup(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        outputFD: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, outputFD, 1)
        posix_spawn_file_actions_adddup2(&fileActions, outputFD, 2)
        posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // SETSIGDEF/SETSIGMASK reset the child's signal state: ignored
        // dispositions (SIG_IGN survives exec) and masked signals would
        // otherwise leak from the parent and make the server deaf to the
        // SIGTERM this supervisor relies on for graceful shutdown.
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)
        posix_spawnattr_setsigmask(&attributes, &emptySignalMask)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        posix_spawnattr_setpgroup(&attributes, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = ([executablePath] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv { free(pointer) } }

        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { for pointer in envp { free(pointer) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executablePath, &fileActions, &attributes, argv, envp)
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        return pid
    }

    // MARK: Supervision

    /// True once the leader has exited (reaping it as a side effect). ECHILD —
    /// already reaped by an earlier check — also counts as exited. Says nothing
    /// about other group members; use `processGroupIsEmpty` for that.
    private func processHasExited(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return true }
        return result == -1 && errno == ECHILD
    }

    /// True when no member of the child's process group remains. Reaps the
    /// leader first so a zombie leader doesn't count as a live member, then
    /// probes the group with signal 0 (ESRCH = empty).
    private func processGroupIsEmpty(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        _ = waitpid(pid, &status, WNOHANG)
        if kill(-pid, 0) == 0 { return false }
        return errno == ESRCH
    }

    /// SIGTERM the group, wait for the *group* — not just the leader — to be
    /// empty within the grace period, then SIGKILL the group. The leader dying
    /// while a member (e.g. `next start` ignoring SIGTERM) survives must still
    /// escalate.
    private func terminateProcessGroup(_ pid: pid_t, gracePeriod: TimeInterval? = nil) async {
        kill(-pid, SIGTERM)

        let deadline = Date().addingTimeInterval(gracePeriod ?? configuration.terminationGracePeriod)
        while Date() < deadline {
            if processGroupIsEmpty(pid) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        kill(-pid, SIGKILL)
        for _ in 0..<40 where !processGroupIsEmpty(pid) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: Watchdog

    /// Post-ready supervision: without it, a server that dies after one
    /// successful health check would stay `.ready` forever and `signInURL()`
    /// would keep vending URLs for a dead server.
    private func startWatchdog(pid: pid_t, launchGeneration: UInt64) {
        cancelWatchdog()
        watchdogTask = Task { [weak self] in
            await self?.runWatchdog(pid: pid, launchGeneration: launchGeneration)
        }
    }

    private func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func runWatchdog(pid: pid_t, launchGeneration: UInt64) async {
        var consecutiveHealthFailures = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(configuration.watchdogInterval * 1_000_000_000))
            guard generation == launchGeneration, !Task.isCancelled else { return }

            if processHasExited(pid) {
                await failFromWatchdog(
                    pid: pid,
                    launchGeneration: launchGeneration,
                    reason: "web-next server exited after becoming ready; see \(logFileURL?.path ?? "logs")"
                )
                return
            }

            if await serverIsHealthy() {
                consecutiveHealthFailures = 0
            } else {
                consecutiveHealthFailures += 1
                if consecutiveHealthFailures >= configuration.watchdogFailureThreshold {
                    await failFromWatchdog(
                        pid: pid,
                        launchGeneration: launchGeneration,
                        reason: "web-next server stopped answering on port \(configuration.port)."
                    )
                    return
                }
            }
        }
    }

    private func failFromWatchdog(pid: pid_t, launchGeneration: UInt64, reason: String) async {
        await terminateProcessGroup(pid)
        guard generation == launchGeneration else { return }
        if processID == pid { processID = nil }
        state = .failed(reason: reason)
    }

    // MARK: Readiness

    /// Strict readiness per embedded-native-contract.md § 2: `.ready` requires
    /// `GET /api/healthz` to answer 200 with JSON `ok == true` AND
    /// `localMode == true`. Requiring `localMode` keeps a foreign or
    /// non-local-mode server that merely answers `{ok:true}` on the port from
    /// satisfying readiness (the WKWebView would otherwise send its session
    /// cookie to it). Any other HTTP response is not ready; connection refused
    /// means still starting.
    private func serverIsHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/healthz"))
        request.timeoutInterval = 2

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200,
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["ok"] as? Bool == true,
                object["localMode"] as? Bool == true
            else { return false }
            return true
        } catch {
            return false
        }
    }
}
