//
//  AgentHookListener.swift
//  WorkspaceManagerCore
//
//  Unix domain socket listener for Claude Code's HTTP hook channel.
//  Spec: pasted_text_2026-05-03_22-18-10.txt § Channel 1 ("Listener", "Async by default").
//
//  Routes:
//    POST /event       — hook event, decoded via ClaudeHookTranslator
//    POST /statusline  — Channel 2 status-line forwarder; decodes StatusLinePayload
//                        and applies status fields for the header-routed session
//    POST /command-markers
//                      — raw OSC 133 command markers for LastCommandStatusRegistry
//    GET  /healthz     — 200 OK "OK"
//
//  Framing: minimal HTTP/1.1 — request line, headers, body. We respond 200 OK
//  immediately and process the payload off the read path. Hook handlers must be
//  fast (<10ms) per the spec.
//

import Darwin
import Foundation
import Network

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

    public init(
        bundleIdentifier: String,
        registry: any AgentSessionRegistryProtocol,
        commandStatusRegistry: LastCommandStatusRegistry? = nil,
        socketURLOverride: URL? = nil,
        logger: @escaping @Sendable (String) -> Void = { NSLog("[AgentHookListener] %@", $0) }
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
                NSLog("[AgentHookListener] read error: %@", "\(error)")
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
                NSLog("[AgentHookListener] oversized request, dropping")
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
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            })

        // Process payload off the response path so the hook caller never blocks on us.
        Task { [request] in
            await self.process(request: request)
        }
    }

    private func route(_ request: HTTPRequest) -> (Int, Data) {
        switch (request.method.uppercased(), request.path) {
        case ("GET", "/healthz"):
            return (200, Data("OK".utf8))
        case ("POST", "/event"):
            return (200, Data())
        case ("POST", "/statusline"):
            return (200, Data())
        case ("POST", "/command-markers"):
            return (200, Data())
        default:
            return (200, Data())
        }
    }

    private func process(request: HTTPRequest) async {
        switch (request.method.uppercased(), request.path) {
        case ("POST", "/event"):
            await processEvent(request: request)
        case ("POST", "/statusline"):
            await processStatusLine(request: request)
        case ("POST", "/command-markers"):
            await processCommandMarkers(request: request)
        default:
            break
        }
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
            event = try ClaudeHookTranslator.decodeAgentEvent(from: request.body)
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

        guard let payload = StatusLinePayload.decode(from: request.body) else {
            statistics.decodeFailures += 1
            logger("statusline decode failed")
            return
        }

        let fields = payload.toStatusFields()
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
        guard await isRegisteredHostSession(hostSessionID) else {
            logger("dropping command markers for unregistered host session \(hostSessionID.uuidString)")
            return
        }
        guard !request.body.isEmpty else {
            statistics.decodeFailures += 1
            logger("command marker decode failed: empty body")
            return
        }

        let markers = CommandMarkerParser.parse(request.body)
        guard !markers.isEmpty else {
            statistics.decodeFailures += 1
            logger("command marker decode failed: no OSC 133 markers")
            return
        }

        guard let commandStatusRegistry else {
            logger("dropping command markers; command status registry unavailable")
            return
        }

        await MainActor.run { [commandStatusRegistry, markers] in
            commandStatusRegistry.ingest(markers: markers, for: hostSessionID)
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
