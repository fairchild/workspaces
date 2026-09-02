import Darwin
import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "AutomationListener")

public actor AutomationListener {
    public enum ListenerError: Error, Sendable {
        case alreadyStarted
        case socketAlreadyOwned(String)
        case socketBindFailed(String)
    }

    public struct Statistics: Sendable, Equatable {
        public var requestCount: Int = 0
        public var unsupportedRoutes: Int = 0
        public var deniedRequests: Int = 0
    }

    private let socketURL: URL
    private let lockURL: URL
    private let controller: any AutomationControlling
    private let isEnabled: @Sendable () -> Bool
    private let makeHealthServer: @Sendable (Date) -> AutomationServerDescriptor
    private let auditLogger: AutomationAuditLogger?
    private let logger: @Sendable (String) -> Void
    private let maxConcurrentConnections: Int
    private let readDeadline: Duration
    private let writeDeadline: Duration
    private var listener: NWListener?
    private var lockFileDescriptor: Int32?
    private var statistics = Statistics()
    /// When this listener came up — the one part of the health descriptor that is fixed at
    /// start. Everything else is read when a request asks (below).
    private var launchedAt: Date?
    private var activeConnectionIDs: Set<ObjectIdentifier> = []

    /// The descriptor `/v1/health` answers with, built per request.
    ///
    /// It was built once at `start()` and served from a stored property, which made the health
    /// answer a snapshot of a moment barely a millisecond wide: operator provisioning runs
    /// immediately *after* the listener is up, so the credential outcome was always read before
    /// it was written and the field was nil for the life of the process (#1400). The same held
    /// for any other fact that settles after start, the experiment set among them.
    ///
    /// `makeHealthServer` was already written for this — the lifecycle's closure reads a
    /// lock-guarded box precisely because it expects to run off the MainActor, per request.
    /// Building the descriptor is a bundle lookup and a date format, which is not a cost worth
    /// serving a stale answer to avoid.
    private var healthServer: AutomationServerDescriptor? {
        launchedAt.map(makeHealthServer)
    }

    public init(
        bundleIdentifier: String,
        controller: any AutomationControlling,
        socketURLOverride: URL? = nil,
        auditLogger: AutomationAuditLogger? = nil,
        maxConcurrentConnections: Int = 8,
        readDeadline: Duration = .seconds(10),
        writeDeadline: Duration = .seconds(10),
        isEnabled: @escaping @Sendable () -> Bool = { true },
        makeHealthServer: @escaping @Sendable (Date) -> AutomationServerDescriptor = {
            AutomationServerDescriptor.current(launchedAt: $0, experiments: [])
        },
        logger: @escaping @Sendable (String) -> Void = { message in
            let logger = Logger(subsystem: "com.cloudcompute.workspaces", category: "AutomationListener")
            // This sink carries mixed-severity text from call sites throughout the actor, not just this
            // default's own messages — approximate severity from wording rather than misclassifying
            // failures/drops as routine.
            if message.localizedCaseInsensitiveContains("fail") || message.localizedCaseInsensitiveContains("error")
                || message.localizedCaseInsensitiveContains("drop")
            {
                logger.error("[AutomationListener] \(message, privacy: .public)")
            } else {
                logger.info("[AutomationListener] \(message, privacy: .public)")
            }
        }
    ) {
        self.controller = controller
        self.auditLogger = auditLogger
        self.maxConcurrentConnections = maxConcurrentConnections
        self.readDeadline = readDeadline
        self.writeDeadline = writeDeadline
        self.isEnabled = isEnabled
        self.makeHealthServer = makeHealthServer
        self.logger = logger
        if let socketURLOverride {
            self.socketURL = socketURLOverride
        } else {
            self.socketURL = Self.defaultSocketURL(bundleIdentifier: bundleIdentifier)
        }
        self.lockURL = socketURL.deletingPathExtension().appendingPathExtension("lock")
    }

    public nonisolated var socketPath: String { socketURL.path }

    public nonisolated static func defaultSocketURL(bundleIdentifier: String) -> URL {
        AutomationSupportDirectory.fileURL(named: "automation.sock", bundleIdentifier: bundleIdentifier)
    }

    public func currentStatistics() -> Statistics { statistics }

    public func start() async throws {
        guard listener == nil else { throw ListenerError.alreadyStarted }

        try ensureParentDirectoryExists()
        guard try acquireSocketLock() else {
            logger("listener dormant; another process owns \(socketURL.path)")
            throw ListenerError.socketAlreadyOwned(socketURL.path)
        }
        try? FileManager.default.removeItem(at: socketURL)

        let endpoint = NWEndpoint.unix(path: socketURL.path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = endpoint
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            releaseSocketLock()
            throw ListenerError.socketBindFailed("\(error)")
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.accept(connection: connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleListenerState(state) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        self.launchedAt = Date()
        hardenSocketFileIfPresent()
        logger("listener started at \(socketURL.path)")
    }

    public func stop() async {
        let hadListener = listener != nil
        listener?.cancel()
        listener = nil
        launchedAt = nil
        if hadListener {
            try? FileManager.default.removeItem(at: socketURL)
            logger("listener stopped; socket file removed at \(socketURL.path)")
        }
        releaseSocketLock()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            hardenSocketFileIfPresent()
            logger("listener ready")
        case .failed(let error):
            logger("listener failed: \(error)")
        case .cancelled:
            logger("listener cancelled")
        default:
            break
        }
    }

    /// Connections currently occupying a cap slot. Exists for tests that must observe the cap
    /// engaging — a test that sends its own request before the server has registered the
    /// connection meant to hold the slot gets the slot itself, and hangs up the holder as busy.
    var activeConnectionCount: Int { activeConnectionIDs.count }

    private func accept(connection: NWConnection) {
        guard activeConnectionIDs.count < maxConcurrentConnections else {
            rejectBusy(connection: connection)
            return
        }
        let id = ObjectIdentifier(connection)
        activeConnectionIDs.insert(id)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                guard let self else { return }
                Task { await self.forgetConnection(id) }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        let deadline = Self.deadlineWatchdog(connection: connection, after: readDeadline, label: "read")
        readRequest(connection: connection, accumulated: Data(), deadline: deadline)
    }

    private func forgetConnection(_ id: ObjectIdentifier) {
        activeConnectionIDs.remove(id)
    }

    /// Answers a connection over the concurrency cap with a typed `busy` envelope instead of
    /// letting it queue behind hung peers; the caller can retry once in-flight work drains.
    private func rejectBusy(connection: NWConnection) {
        logger("connection rejected: concurrent connection cap (\(maxConcurrentConnections)) reached")
        connection.start(queue: .global(qos: .userInitiated))
        let error = AutomationErrorResponse(
            code: .busy,
            message: "Too many concurrent automation connections; retry shortly."
        )
        let envelope = AutomationResponseEnvelope<AutomationEmptyResult>(error: error)
        let body = (try? AutomationJSON.encoder.encode(envelope)) ?? Data()
        let response = Self.httpResponse(status: 503, body: body)
        let writeDeadline = self.writeDeadline
        let watchdog = Self.deadlineWatchdog(connection: connection, after: writeDeadline, label: "busy-write")
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                watchdog.cancel()
                Self.drainThenCancel(connection: connection, after: writeDeadline)
            })
    }

    /// Hang up only once the peer's request has arrived, or the deadline passes.
    ///
    /// The rejection answers without ever reading the request, so cancelling the moment
    /// the 503 is written can close the socket while the client is still mid-`write`.
    /// The client then gets `EPIPE` instead of the typed busy envelope it is owed —
    /// seen as `.writeFailed(32)` (#1370). One bounded receive closes that window: the
    /// request is small and already in flight, so this returns as soon as it lands.
    private nonisolated static func drainThenCancel(connection: NWConnection, after limit: Duration) {
        let watchdog = deadlineWatchdog(connection: connection, after: limit, label: "busy-drain")
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
            watchdog.cancel()
            connection.cancel()
        }
    }

    /// Cancels `connection` if it is still alive when the deadline elapses, so a hung peer cannot
    /// pin an NWConnection (and a cap slot) until app exit. Cancel the returned task on completion.
    private nonisolated static func deadlineWatchdog(
        connection: NWConnection,
        after limit: Duration,
        label: String
    ) -> Task<Void, Never> {
        Task { [weak connection] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            log.error("[AutomationListener] \(label, privacy: .public) deadline exceeded; cancelling connection")
            connection?.cancel()
        }
    }

    private nonisolated func readRequest(connection: NWConnection, accumulated: Data, deadline: Task<Void, Never>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let error {
                log.error("[AutomationListener] read error: \(String(describing: error), privacy: .public)")
                deadline.cancel()
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data { buffer.append(data) }

            if let request = HTTPRequest.parse(buffer) {
                deadline.cancel()
                Task { [weak connection] in
                    guard let connection else { return }
                    await self.respond(request: request, connection: connection)
                }
                return
            }

            if isComplete {
                deadline.cancel()
                connection.cancel()
                return
            }

            if buffer.count > 1_048_576 {
                log.error("[AutomationListener] oversized request, dropping")
                deadline.cancel()
                connection.cancel()
                return
            }

            self.readRequest(connection: connection, accumulated: buffer, deadline: deadline)
        }
    }

    private func respond(request: HTTPRequest, connection: NWConnection) async {
        let result = await AutomationHTTPRouter.route(
            request,
            controller: controller,
            enabled: isEnabled(),
            healthServer: healthServer
        )
        statistics.requestCount += 1
        if result.status == 404 {
            statistics.unsupportedRoutes += 1
        }
        if result.status >= 400 {
            statistics.deniedRequests += 1
        }

        let response = Self.httpResponse(status: result.status, body: result.body)
        // Classify the caller's handle against the live registry so the audit event can tell an
        // operator call from a tile call; a missing/unresolvable handle is not an operator handle.
        let operatorHandle: Bool
        if let handleValue = request.headers[AutomationAPI.handleHeader], !handleValue.isEmpty {
            operatorHandle = await controller.automationHandleIsOperator(handleValue)
        } else {
            operatorHandle = false
        }
        await auditLogger?.record(
            method: request.method,
            path: request.path,
            headers: request.headers,
            requestBody: request.body,
            responseBody: result.body,
            operatorHandle: operatorHandle
        )
        // The request above already ran; if the peer disconnected (or the write stalls past the
        // deadline), append a best-effort marker for the response whose delivery failed, carrying
        // that response's outcome so an undelivered denial still audits as denied.
        let auditLogger = auditLogger
        let method = request.method
        let path = request.path
        let handlePresent = request.headers[AutomationAPI.handleHeader]?.isEmpty == false
        let outcome = AutomationAuditLogger.responseOutcome(from: result.body)
        let watchdog = Self.deadlineWatchdog(connection: connection, after: writeDeadline, label: "write")
        connection.send(
            content: response,
            completion: .contentProcessed { error in
                watchdog.cancel()
                if error != nil, let auditLogger {
                    let route = "\(method) \(path)"
                    log.error("[AutomationListener] response undelivered for \(route, privacy: .public)")
                    Task {
                        await auditLogger.recordResponseUndelivered(
                            method: method,
                            path: path,
                            handlePresent: handlePresent,
                            operatorHandle: operatorHandle,
                            allowed: outcome.allowed,
                            errorCode: outcome.errorCode
                        )
                    }
                }
                connection.cancel()
            })
    }

    private func ensureParentDirectoryExists() throws {
        let dir = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(dir.path, S_IRWXU)
    }

    private func acquireSocketLock() throws -> Bool {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw ListenerError.socketBindFailed("could not open lock \(lockURL.path): errno=\(errno)")
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }

        lockFileDescriptor = fd
        return true
    }

    private func releaseSocketLock() {
        guard let fd = lockFileDescriptor else { return }
        flock(fd, LOCK_UN)
        close(fd)
        lockFileDescriptor = nil
    }

    private nonisolated func hardenSocketFileIfPresent() {
        guard FileManager.default.fileExists(atPath: socketURL.path) else { return }
        chmod(socketURL.path, S_IRUSR | S_IWUSR)
    }

    private static func httpResponse(status: Int, body: Data) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 409: reason = "Conflict"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }

        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}
