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
    private var listener: NWListener?
    private var lockFileDescriptor: Int32?
    private var statistics = Statistics()
    private var healthServer: AutomationServerDescriptor?

    public init(
        bundleIdentifier: String,
        controller: any AutomationControlling,
        socketURLOverride: URL? = nil,
        auditLogger: AutomationAuditLogger? = nil,
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
        let appSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
        return dir.appendingPathComponent("automation.sock", isDirectory: false)
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
        self.healthServer = makeHealthServer(Date())
        hardenSocketFileIfPresent()
        logger("listener started at \(socketURL.path)")
    }

    public func stop() async {
        let hadListener = listener != nil
        listener?.cancel()
        listener = nil
        healthServer = nil
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

    private func accept(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        readRequest(connection: connection, accumulated: Data())
    }

    private nonisolated func readRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let error {
                log.error("[AutomationListener] read error: \(String(describing: error), privacy: .public)")
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data { buffer.append(data) }

            if let request = HTTPRequest.parse(buffer) {
                Task { [weak connection] in
                    guard let connection else { return }
                    await self.respond(request: request, connection: connection)
                }
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            if buffer.count > 1_048_576 {
                log.error("[AutomationListener] oversized request, dropping")
                connection.cancel()
                return
            }

            self.readRequest(connection: connection, accumulated: buffer)
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
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
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
