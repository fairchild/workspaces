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
        readinessTimeout: TimeInterval = 30,
        readinessPollInterval: TimeInterval = 0.5,
        terminationGracePeriod: TimeInterval = 5,
        watchdogInterval: TimeInterval = 5,
        watchdogFailureThreshold: Int = 3
    ) {
        let resolvedDataDir = dataDir ?? Self.defaultDataDirectory()
        self.webNextRoot = webNextRoot
        self.port = port
        self.dataDir = resolvedDataDir
        self.logDirectory = logDirectory ?? resolvedDataDir.appendingPathComponent("logs", isDirectory: true)
        self.launchCommand = launchCommand
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
        URL(string: "http://127.0.0.1:\(configuration.port)")!
    }

    // MARK: Lifecycle

    /// Spawn the server and wait until `/api/healthz` reports healthy or the
    /// readiness timeout elapses. Returns immediately when already starting or ready.
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
        generation &+= 1
        cancelWatchdog()
        let pid = processID
        processID = nil
        if let pid {
            await terminateProcessGroup(pid)
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
        defer { close(logFD) }

        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = String(configuration.port)
        environment["WEB_NEXT_DATA_DIR"] = configuration.dataDir.path

        return try Self.spawnInNewProcessGroup(
            executablePath: configuration.launchCommand.executablePath,
            arguments: configuration.launchCommand.arguments,
            environment: environment,
            workingDirectory: configuration.webNextRoot.path,
            outputFD: logFD
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
    private func terminateProcessGroup(_ pid: pid_t) async {
        kill(-pid, SIGTERM)

        let deadline = Date().addingTimeInterval(configuration.terminationGracePeriod)
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
    /// `GET /api/healthz` to answer 200 with JSON `ok == true`. Any other HTTP
    /// response — including a stale or foreign listener on the port — is not
    /// ready; connection refused means still starting.
    private func serverIsHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/healthz"))
        request.timeoutInterval = 2

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200,
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ok = object["ok"] as? Bool
            else { return false }
            return ok
        } catch {
            return false
        }
    }
}
