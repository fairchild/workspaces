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
//  Ingest is coalesced (#1347): decoded events accumulate per host session and
//  flush to the main actor at most once per coalescing interval — one
//  main-actor hop and one `apply(events:)` per session per window, instead of
//  one per event.
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
        /// Coalesced main-actor flushes performed; with N events in one window
        /// this advances once while `ingestedEvents` advances N times.
        public var flushCount: Int = 0
    }

    /// Default accumulation window before pending events flush to the main
    /// actor. Bounded so attention states (awaiting input, permission
    /// prompts) surface with imperceptible delay.
    public static let defaultCoalescingInterval: TimeInterval = 0.15

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
    private let coalescingInterval: TimeInterval
    private var pendingEvents: [UUID: [(event: AgentEvent, origin: AgentEventOrigin)]] = [:]
    private var drainTask: Task<Void, Never>?
    private var isStopped = false

    public init(
        bundleIdentifier: String,
        registry: any AgentSessionRegistryProtocol,
        commandStatusRegistry: LastCommandStatusRegistry? = nil,
        coalescingInterval: TimeInterval = AgentHookListener.defaultCoalescingInterval,
        socketURLOverride: URL? = nil,
        logger: @escaping @Sendable (String) -> Void = { message in
            let logger = Logger(subsystem: "com.cloudcompute.workspaces", category: "AgentHookListener")
            // This sink carries mixed-severity text from call sites throughout the actor, not just this
            // default's own messages — approximate severity from wording rather than misclassifying
            // failures/drops as routine.
            if message.localizedCaseInsensitiveContains("fail") || message.localizedCaseInsensitiveContains("error")
                || message.localizedCaseInsensitiveContains("drop")
            {
                logger.error("[AgentHookListener] \(message, privacy: .public)")
            } else {
                logger.info("[AgentHookListener] \(message, privacy: .public)")
            }
        }
    ) {
        self.registry = registry
        self.commandStatusRegistry = commandStatusRegistry
        self.coalescingInterval = coalescingInterval
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
        // Drain boundary: no new events are accepted past this line, the
        // coalescing sleep is cut short, and the active drain (if any) is
        // awaited — so no buffered batch can reach the registry after stop()
        // returns.
        isStopped = true
        let hadListener = listener != nil
        listener?.cancel()
        listener = nil
        await flushPendingEvents()
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

        let event: AgentEvent?
        do {
            event = try AgentUpdateIntake.decodeHookEvent(from: request.body)
        } catch {
            statistics.decodeFailures += 1
            logger("decode error: \(error)")
            return
        }
        guard let event else { return }

        enqueue(event, origin: .hook, for: hostSessionID)
    }

    private func processStatusLine(request: HTTPRequest) async {
        guard let hostSessionID = Self.hostSessionID(from: request.headers) else {
            return
        }

        guard let fields = AgentUpdateIntake.decodeStatusFields(from: request.body) else {
            statistics.decodeFailures += 1
            logger("statusline decode failed")
            return
        }

        enqueue(.statusFields(fields), origin: .statusLine, for: hostSessionID)
    }

    // MARK: - Coalesced ingest

    private func enqueue(_ event: AgentEvent, origin: AgentEventOrigin, for hostSessionID: UUID) {
        guard !isStopped else {
            logger("dropping event received after listener stop for \(hostSessionID.uuidString)")
            return
        }
        pendingEvents[hostSessionID, default: []].append((event, origin))
        guard drainTask == nil else { return }
        drainTask = Task { [weak self, coalescingInterval] in
            if coalescingInterval > 0 {
                // A cancelled sleep means stop() or a test wants the buffer
                // drained now, not skipped — fall through either way.
                try? await Task.sleep(nanoseconds: UInt64(coalescingInterval * 1_000_000_000))
            }
            await self?.drainPendingEvents()
        }
    }

    /// Test seam: number of decoded events currently buffered awaiting flush.
    func pendingEventCount() -> Int {
        pendingEvents.values.reduce(0) { $0 + $1.count }
    }

    /// Cut the coalescing window short and wait until the buffer is fully
    /// drained. Used by `stop()` and tests; safe to call at any point in the
    /// drain lifecycle.
    func flushPendingEvents() async {
        if let task = drainTask {
            task.cancel()
            await task.value
        } else if !pendingEvents.isEmpty {
            await drainPendingEvents()
        }
    }

    /// The single drainer: loops until the buffer is empty — events enqueued
    /// while a batch is on the main actor are picked up by the next
    /// iteration, so batches never interleave and delivery order per session
    /// is the arrival order. One main-actor hop per iteration, one
    /// `apply(events:)` per contiguous same-origin run per session.
    /// Registration is checked at flush time so an unregistered session's
    /// burst drops as a unit. Only the task stored in `drainTask` runs this,
    /// which is what makes the drainer single.
    private func drainPendingEvents() async {
        while !pendingEvents.isEmpty {
            let batches = pendingEvents
            pendingEvents = [:]

            let outcome = await MainActor.run {
                [registry] () -> (hookEvents: Int, statusLineEvents: Int, droppedSessions: [UUID]) in
                var hookEvents = 0
                var statusLineEvents = 0
                var droppedSessions: [UUID] = []
                for (hostSessionID, entries) in batches {
                    guard registry.status(for: hostSessionID) != nil else {
                        droppedSessions.append(hostSessionID)
                        continue
                    }
                    var index = entries.startIndex
                    while index < entries.endIndex {
                        let origin = entries[index].origin
                        var events: [AgentEvent] = []
                        while index < entries.endIndex, entries[index].origin == origin {
                            events.append(entries[index].event)
                            index += 1
                        }
                        registry.apply(events: events, for: hostSessionID, origin: origin)
                        if origin == .statusLine {
                            statusLineEvents += events.count
                        } else {
                            hookEvents += events.count
                        }
                    }
                }
                return (hookEvents, statusLineEvents, droppedSessions)
            }

            statistics.flushCount += 1
            statistics.ingestedEvents += outcome.hookEvents
            statistics.statusLineUpdates += outcome.statusLineEvents
            for hostSessionID in outcome.droppedSessions {
                logger("dropping events for unregistered host session \(hostSessionID.uuidString)")
            }
        }
        drainTask = nil
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
            guard registry.status(for: hostSessionID) != nil else { return false }
            commandStatusRegistry.ingest(markers: markers, for: hostSessionID)
            return true
        }
        guard ingested else {
            logger("dropping command markers for unregistered host session \(hostSessionID.uuidString)")
            return
        }
        statistics.commandMarkerUpdates += 1
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
