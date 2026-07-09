//
//  WebNextServerService.swift
//  WorkspaceManagerCore
//
//  Spawns and supervises the local-mode web-next server (`pnpm run start:local`)
//  in its own process group, polls the port for readiness, and builds
//  token-bearing sign-in URLs for the embedded web UI. The entrypoint does not
//  forward signals to its `next start` child, so shutdown terminates the whole
//  process group (SIGTERM → bounded grace → SIGKILL).
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
    /// How long `stop()` waits after SIGTERM before escalating to SIGKILL.
    public var terminationGracePeriod: TimeInterval

    public init(
        webNextRoot: URL,
        port: Int = 3140,
        dataDir: URL? = nil,
        logDirectory: URL? = nil,
        launchCommand: WebNextLaunchCommand = .default,
        readinessTimeout: TimeInterval = 30,
        readinessPollInterval: TimeInterval = 0.5,
        terminationGracePeriod: TimeInterval = 5
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
    /// Bumped by every `start()`/`stop()`; in-flight readiness polls compare
    /// against it so a superseded launch never overwrites current state.
    private var generation: UInt64 = 0

    private static let signInTokenFilename = "local-sign-in-token"

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

    /// Spawn the server and wait until it answers on the port or the readiness
    /// timeout elapses. Returns immediately when already starting or ready.
    public func start() async {
        switch state {
        case .starting, .ready:
            return
        case .idle, .failed:
            break
        }

        generation &+= 1
        let launchGeneration = generation
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
                processID = nil
                state = .failed(
                    reason: "web-next server exited before becoming ready; see \(logFileURL?.path ?? "logs")"
                )
                return
            }

            if await serverAnswersHTTP() {
                guard generation == launchGeneration else { return }
                state = .ready(signInBaseURL: baseURL)
                return
            }

            try? await Task.sleep(nanoseconds: UInt64(configuration.readinessPollInterval * 1_000_000_000))
        }

        guard generation == launchGeneration else { return }
        await terminateProcessGroup(pid)
        processID = nil
        state = .failed(
            reason:
                "Timed out after \(Int(configuration.readinessTimeout))s waiting for web-next on port \(configuration.port)."
        )
    }

    /// Terminate the whole process group: SIGTERM, bounded grace, SIGKILL.
    /// Idempotent — safe to call in any state, including mid-start.
    public func stop() async {
        generation &+= 1
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
        var queryItems = [URLQueryItem(name: "token", value: token)]
        if let redirect {
            queryItems.append(URLQueryItem(name: "redirect", value: redirect))
        }
        components?.queryItems = queryItems
        return components?.url
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
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
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

    /// True once the child has exited (reaping it as a side effect). ECHILD —
    /// already reaped by an earlier check — also counts as exited.
    private func processHasExited(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return true }
        return result == -1 && errno == ECHILD
    }

    private func terminateProcessGroup(_ pid: pid_t) async {
        kill(-pid, SIGTERM)

        let deadline = Date().addingTimeInterval(configuration.terminationGracePeriod)
        while Date() < deadline {
            if processHasExited(pid) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        kill(-pid, SIGKILL)
        for _ in 0..<40 where !processHasExited(pid) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: Readiness

    /// Any HTTP response on the port means the server is up — connection
    /// refused means it is still starting. When `/api/healthz` answers 200
    /// with a JSON `ok` field (the endpoint ships in a parallel PR), that
    /// field is authoritative.
    private func serverAnswersHTTP() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/healthz"))
        request.timeoutInterval = 2

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return true }
            if httpResponse.statusCode == 200,
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ok = object["ok"] as? Bool
            {
                return ok
            }
            return true
        } catch {
            return false
        }
    }
}
