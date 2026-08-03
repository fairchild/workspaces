//
//  AgentHookListener.swift
//  WorkspaceManagerCore
//
//  Unix domain socket listener for Agent update forwarders.
//
//  Routes:
//    POST /event       — command hook forwarder, decoded via AgentUpdateIntake
//    POST /statusline  — status-line forwarder, decoded via AgentUpdateIntake
//    POST /command-markers
//                      — command-status producer for LastCommandStatusRegistry
//    GET  /healthz     — 200 OK "OK"
//
//  Framing: minimal HTTP/1.1 — request line, headers, body. We respond 200 OK
//  immediately and process the payload off the read path. Hook handlers must be
//  fast (<10ms) per the spec.
//

import Darwin
import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "AgentHookListener")

public actor AgentHookListener {
    public enum ListenerError: Error, Sendable {
        case alreadyStarted
        case socketBindFailed(String)
        case listenerCancelled
    }

    public struct Statistics: Sendable, Equatable {
        public var requestCount: Int = 0
        public var decodeFailures: Int = 0
        public var unsupportedRoutes: Int = 0
        public var ingestedEvents: Int = 0
        public var statusLineUpdates: Int = 0
        public var commandMarkerUpdates: Int = 0
    }

    private let socketURL: URL
    private let lockURL: URL
    private let registry: any AgentSessionRegistryProtocol
    private let commandStatusRegistry: LastCommandStatusRegistry?
    private let logger: @Sendable (String) -> Void
    private var listener: NWListener?
    private var lockFileDescriptor: Int32?
    private var statistics = Statistics()
    private var commandMarkerRequestQueue: [HTTPRequest] = []
    private var isDrainingCommandMarkerRequests = false

    public init(
        bundleIdentifier: String,
        registry: any AgentSessionRegistryProtocol,
        commandStatusRegistry: LastCommandStatusRegistry? = nil,
        socketURLOverride: URL? = nil,
        logger: @escaping @Sendable (String) -> Void = { message in
            Logger(subsystem: "com.cloudcompute.workspaces", category: "AgentHookListener")
                .info("[AgentHookListener] \(message, privacy: .public)")
        }
    ) {
        self.registry = registry
        self.commandStatusRegistry = commandStatusRegistry
        self.logger = logger
        if let override = socketURLOverride {
            self.socketURL = override
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
        return dir.appendingPathComponent("hooks.sock", isDirectory: false)
    }

    public func currentStatistics() -> Statistics { statistics }

    /// Start the listener. A stable socket path is guarded by a sibling lock
    /// file so concurrent app instances do not race each other.
    public func start() async throws {
        guard listener == nil else { throw ListenerError.alreadyStarted }

        try ensureParentDirectoryExists()
        guard try acquireSocketLock() else {
            logger("listener dormant; another process owns \(socketURL.path)")
            return
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
        logger("listener started at \(socketURL.path)")
    }

    public func stop() async {
        let hadListener = listener != nil
        listener?.cancel()
        listener = nil
        if hadListener {
            try? FileManager.default.removeItem(at: socketURL)
            logger("listener stopped; socket file removed at \(socketURL.path)")
        } else {
            logger("listener stopped")
        }
        releaseSocketLock()
    }

    // MARK: - Connection handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger("listener ready")
        case .failed(let err):
            logger("listener failed: \(err)")
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
                log.error("[AgentHookListener] read error: \(String(describing: error), privacy: .public)")
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data { buffer.append(data) }

            if let request = HTTPRequest.parse(buffer) {
                Task { [weak connection] in
                    guard let connection else { return }
                    await self.respondAndProcess(request: request, connection: connection)
                }
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            if buffer.count > 1_048_576 {
                log.error("[AgentHookListener] oversized request, dropping")
                connection.cancel()
                return
            }

            self.readRequest(connection: connection, accumulated: buffer)
        }
    }

    private func respondAndProcess(request: HTTPRequest, connection: NWConnection) {
        let (status, body) = route(request)
        statistics.requestCount += 1
        let response = Self.httpResponse(status: status, body: body)
        let isCommandMarkerRequest = Self.isCommandMarkerRequest(request)
        if isCommandMarkerRequest {
            enqueueCommandMarkerRequest(request)
        }
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            })

        // Process payload off the response path so the hook caller never blocks on us.
        if !isCommandMarkerRequest {
            Task { [request] in
                await self.process(request: request)
            }
        }
    }

    private func route(_ request: HTTPRequest) -> (Int, Data) {
        let route = AgentUpdateIntake.httpRoute(method: request.method, path: request.path)
        return (200, route?.responseBody ?? Data())
    }

    private func process(request: HTTPRequest) async {
        switch AgentUpdateIntake.httpRoute(method: request.method, path: request.path)?.purpose {
        case .commandHookForwarder:
            await processEvent(request: request)
        case .statusLineForwarder:
            await processStatusLine(request: request)
        default:
            break
        }
    }

    private static func isCommandMarkerRequest(_ request: HTTPRequest) -> Bool {
        AgentUpdateIntake.httpRoute(method: request.method, path: request.path)?.purpose
            == .commandStatusProducer
    }

    private func enqueueCommandMarkerRequest(_ request: HTTPRequest) {
        commandMarkerRequestQueue.append(request)
        guard !isDrainingCommandMarkerRequests else { return }

        isDrainingCommandMarkerRequests = true
        Task {
            await self.drainCommandMarkerRequests()
        }
    }

    private func drainCommandMarkerRequests() async {
        while !commandMarkerRequestQueue.isEmpty {
            let request = commandMarkerRequestQueue.removeFirst()
            await processCommandMarkers(request: request)
        }
        isDrainingCommandMarkerRequests = false
    }

    private func processEvent(request: HTTPRequest) async {
        guard let hostSessionID = Self.hostSessionID(from: request.headers) else {
            logger("dropping hook event without valid host session header")
            return
        }
        guard await isRegisteredHostSession(hostSessionID) else {
            logger("dropping hook event for unregistered host session \(hostSessionID.uuidString)")
            return
        }

        let event: AgentEvent?
        do {
            event = try AgentUpdateIntake.decodeHookEvent(from: request.body)
        } catch {
            statistics.decodeFailures += 1
            logger("decode error: \(error)")
            return
        }
        guard let event else { return }

        await MainActor.run { [registry, event] in
            registry.apply(events: [event], for: hostSessionID, origin: .hook)
        }
        statistics.ingestedEvents += 1
    }

    private func processStatusLine(request: HTTPRequest) async {
        guard let hostSessionID = Self.hostSessionID(from: request.headers) else {
            return
        }
        guard await isRegisteredHostSession(hostSessionID) else {
            return
        }

        guard let fields = AgentUpdateIntake.decodeStatusFields(from: request.body) else {
            statistics.decodeFailures += 1
            logger("statusline decode failed")
            return
        }

        await MainActor.run { [registry] in
            registry.apply(events: [.statusFields(fields)], for: hostSessionID, origin: .statusLine)
        }
        statistics.statusLineUpdates += 1
    }

    private func processCommandMarkers(request: HTTPRequest) async {
        guard let hostSessionID = Self.hostSessionID(from: request.headers) else {
            logger("dropping command markers without valid host session header")
            return
        }
        guard !request.body.isEmpty else {
            statistics.decodeFailures += 1
            logger("command marker decode failed: empty body")
            return
        }

        let markers = AgentUpdateIntake.decodeCommandMarkers(from: request.body)
        guard !markers.isEmpty else {
            statistics.decodeFailures += 1
            logger("command marker decode failed: no OSC 133 markers")
            return
        }

        guard let commandStatusRegistry else {
            logger("dropping command markers; command status registry unavailable")
            return
        }

        let ingested = await MainActor.run { [registry, commandStatusRegistry, markers] in
            guard registry.statuses[hostSessionID] != nil else { return false }
            commandStatusRegistry.ingest(markers: markers, for: hostSessionID)
            return true
        }
        guard ingested else {
            logger("dropping command markers for unregistered host session \(hostSessionID.uuidString)")
            return
        }
        statistics.commandMarkerUpdates += 1
    }

    private func isRegisteredHostSession(_ hostSessionID: UUID) async -> Bool {
        await MainActor.run { [registry] in
            registry.statuses[hostSessionID] != nil
        }
    }

    private static func hostSessionID(from headers: [String: String]) -> UUID? {
        guard let raw = headers["x-workspaces-host-session-id"] else { return nil }
        return UUID(uuidString: raw)
    }

    // MARK: - Filesystem hygiene

    private func ensureParentDirectoryExists() throws {
        let dir = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
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

    // MARK: - HTTP framing

    private static func httpResponse(status: Int, body: Data) -> Data {
        let reason = status == 200 ? "OK" : "Bad"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}

// MARK: - Minimal HTTP/1.1 request parser

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        // Look for the end of headers.
        guard let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = data.subdata(in: 0..<headerEndRange.lowerBound)
        let bodyStart = headerEndRange.upperBound

        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty else { continue }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let available = data.count - bodyStart
        if contentLength > 0 && available < contentLength {
            return nil  // need more bytes
        }

        let body = data.subdata(in: bodyStart..<min(bodyStart + max(contentLength, 0), data.count))

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}
