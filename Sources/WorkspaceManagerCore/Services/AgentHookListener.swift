//
//  AgentHookListener.swift
//  WorkspaceManagerCore
//
//  Unix domain socket listener for Claude Code's HTTP hook channel.
//  Spec: pasted_text_2026-05-03_22-18-10.txt § Channel 1 ("Listener", "Async by default").
//
//  Routes:
//    POST /event       — hook event, decoded via the registered ClaudeCode adapter
//    POST /statusline  — reserved for PR #2 (status-line forwarder); 200 OK with no-op
//    GET  /healthz     — 200 OK "OK"
//
//  Framing: minimal HTTP/1.1 — request line, headers, body. We respond 200 OK
//  immediately and process the payload off the read path. Hook handlers must be
//  fast (<10ms) per the spec.
//

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
    }

    private let socketURL: URL
    private let registry: any AgentSessionRegistryProtocol
    private let adapterRegistry: AgentAdapterRegistry
    private let logger: @Sendable (String) -> Void
    private var listener: NWListener?
    private var statistics = Statistics()

    public init(
        bundleIdentifier: String,
        registry: any AgentSessionRegistryProtocol,
        adapterRegistry: AgentAdapterRegistry = AgentAdapterRegistry(),
        socketURLOverride: URL? = nil,
        logger: @escaping @Sendable (String) -> Void = { NSLog("[AgentHookListener] %@", $0) }
    ) {
        self.registry = registry
        self.adapterRegistry = adapterRegistry
        self.logger = logger
        if let override = socketURLOverride {
            self.socketURL = override
        } else {
            let appSupport =
                FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first ?? FileManager.default.temporaryDirectory
            let dir = appSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
            self.socketURL = dir.appendingPathComponent("hooks-\(getpid()).sock", isDirectory: false)
        }
    }

    public var socketPath: String { socketURL.path }

    public func currentStatistics() -> Statistics { statistics }

    /// Start the listener. Sweeps stale sibling sockets owned by dead pids,
    /// removes any leftover file at our path, then binds.
    public func start() async throws {
        guard listener == nil else { throw ListenerError.alreadyStarted }

        try ensureParentDirectoryExists()
        try? FileManager.default.removeItem(at: socketURL)
        sweepStaleSiblingSockets()

        let endpoint = NWEndpoint.unix(path: socketURL.path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = endpoint
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
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
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: socketURL)
        logger("listener stopped; socket file removed at \(socketURL.path)")
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
        default:
            return (200, Data())
        }
    }

    private func process(request: HTTPRequest) async {
        switch (request.method.uppercased(), request.path) {
        case ("POST", "/event"):
            await processEvent(body: request.body)
        case ("POST", "/statusline"):
            statistics.unsupportedRoutes += 1
            logger("unsupported route /statusline (reserved for PR #2)")
        default:
            break
        }
    }

    private func processEvent(body: Data) async {
        let adapter = adapterRegistry.adapter(for: .claudeCode)
        let event: AgentEvent?
        do {
            event = try adapter.decodeHookEvent(body)
        } catch {
            statistics.decodeFailures += 1
            logger("decode error: \(error)")
            return
        }
        guard let event else { return }

        // Resolve the host session via the locked contract.
        let cwd: String
        let agentSessionID: String?
        switch event {
        case .sessionStart(let id, let path, _):
            cwd = path
            agentSessionID = id
        case .workingDirectory(let path):
            cwd = path
            agentSessionID = nil
        default:
            // Pull the cwd back out of the raw payload via the decoder common fields.
            // The adapter already consumed the JSON, so re-read for routing only.
            (cwd, agentSessionID) = Self.extractCommon(body: body)
        }

        let hostSessionID = await MainActor.run { [registry] in
            registry.resolveHostSession(cwd: cwd, agentSessionID: agentSessionID)
        }

        guard let hostSessionID else {
            logger("no host session for cwd=\(cwd) agentSession=\(agentSessionID ?? "nil")")
            return
        }

        await MainActor.run { [registry, event] in
            registry.ingest(event, for: hostSessionID, origin: .hook)
        }
        statistics.ingestedEvents += 1
    }

    private static func extractCommon(body: Data) -> (cwd: String, agentSessionID: String?) {
        guard let raw = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ("", nil)
        }
        let cwd =
            (raw["cwd"] as? String)
            ?? (raw["working_directory"] as? String)
            ?? (raw["workingDirectory"] as? String)
            ?? ""
        let sessionID =
            (raw["session_id"] as? String)
            ?? (raw["sessionId"] as? String)
            ?? (raw["sessionID"] as? String)
        return (cwd, sessionID)
    }

    // MARK: - Filesystem hygiene

    private func ensureParentDirectoryExists() throws {
        let dir = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }

    private func sweepStaleSiblingSockets() {
        let dir = socketURL.deletingLastPathComponent()
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            )
        else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("hooks-"), name.hasSuffix(".sock") else { continue }
            let pidString = name.dropFirst("hooks-".count).dropLast(".sock".count)
            guard let pid = pid_t(pidString) else {
                try? FileManager.default.removeItem(at: entry)
                continue
            }
            // kill(pid, 0) returns 0 if alive, -1 with errno=ESRCH if dead.
            if kill(pid, 0) == -1 && errno == ESRCH {
                try? FileManager.default.removeItem(at: entry)
                logger("swept stale sibling socket pid=\(pid)")
            }
        }
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
