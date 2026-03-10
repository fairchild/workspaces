import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "EventStream")

public actor EventStreamService: EventStreamServiceProtocol {
    private let baseURL: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<WebhookEvent>.Continuation?
    private var _events: AsyncStream<WebhookEvent>?
    private var reconnectAttempts = 0
    private var _isConnected = false
    private var currentOwner: String?
    private var currentJWT: String?
    private var currentGitHubToken: String?
    private var receiveLoopTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var _lastDisconnectReason: StreamDisconnectReason = .none
    private var receivedMessageThisConnection = false

    private static let maxBackoff: TimeInterval = 30
    private static let maxReconnectAttempts = 10
    private static let pingInterval: TimeInterval = 30

    public init(
        baseURL: URL = NotificationConstants.baseURL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public var isConnected: Bool { _isConnected }
    public var lastDisconnectReason: StreamDisconnectReason { _lastDisconnectReason }

    public var events: AsyncStream<WebhookEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<WebhookEvent>.makeStream()
        self.continuation = continuation
        self._events = stream
        return stream
    }

    public func connect(owner: String, jwt: String, githubToken: String?) {
        disconnect()

        currentOwner = owner
        currentJWT = jwt
        currentGitHubToken = githubToken

        _ = events

        startConnection()
    }

    public func disconnect() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        _isConnected = false
        currentOwner = nil
        currentJWT = nil
        currentGitHubToken = nil
        reconnectAttempts = 0

        continuation?.finish()
        continuation = nil
        _events = nil
    }

    private func startConnection() {
        receiveLoopTask?.cancel()
        pingTask?.cancel()
        receivedMessageThisConnection = false
        _lastDisconnectReason = .none

        guard
            let owner = currentOwner,
            let jwt = currentJWT
        else { return }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            log.error("Failed to parse base URL for WebSocket")
            return
        }
        components.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components.path = "/ws/\(owner)"

        guard let wsURL = components.url else {
            log.error("Failed to construct WebSocket URL")
            return
        }

        log.info("Connecting to \(owner)")

        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        if let githubToken = currentGitHubToken {
            request.setValue(githubToken, forHTTPHeaderField: "X-GitHub-Token")
        }

        let wsTask = session.webSocketTask(with: request)
        self.task = wsTask
        wsTask.resume()

        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        pingTask = Task { [weak self] in
            await self?.pingLoop()
        }
    }

    private func receiveLoop() async {
        guard let task else { return }

        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                _isConnected = true
                receivedMessageThisConnection = true
                reconnectAttempts = 0

                switch message {
                case .string(let text):
                    handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                _isConnected = false
                guard !Task.isCancelled else { return }

                if receivedMessageThisConnection {
                    _lastDisconnectReason = .transportError
                    log.warning("WebSocket disconnected: \(error.localizedDescription)")
                    await scheduleReconnect()
                } else if Self.isAuthError(error) {
                    _lastDisconnectReason = .authFailure
                    log.error("WebSocket auth rejected: \(error.localizedDescription)")
                } else {
                    _lastDisconnectReason = .transportError
                    log.warning("WebSocket connection failed (will retry): \(error.localizedDescription)")
                    await scheduleReconnect()
                }
                return
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        struct WireMessage: Codable {
            let type: String
            let event: WireEvent?
            let events: [WireEvent]?
        }

        struct WireEvent: Codable {
            let id: String
            let type: String
            let action: String
            let summary: String
            let repo: String
            let timestamp: Int64
        }

        func wireToEvent(_ wire: WireEvent) -> WebhookEvent {
            WebhookEvent(
                id: wire.id,
                type: wire.type,
                action: wire.action,
                summary: wire.summary,
                repo: wire.repo,
                timestamp: Date(timeIntervalSince1970: TimeInterval(wire.timestamp) / 1000)
            )
        }

        do {
            let msg = try JSONDecoder().decode(WireMessage.self, from: data)

            switch msg.type {
            case "catchup":
                if let events = msg.events {
                    log.info("Received \(events.count) catch-up events")
                    for wire in events {
                        continuation?.yield(wireToEvent(wire))
                    }
                }
            case "event":
                if let wire = msg.event {
                    continuation?.yield(wireToEvent(wire))
                }
            default:
                break
            }
        } catch {
            log.warning("Failed to decode message: \(error.localizedDescription)")
        }
    }

    private func pingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.pingInterval))
            guard !Task.isCancelled, let task else { return }
            task.sendPing { _ in }
        }
    }

    private static func isAuthError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // URLSession WebSocket reports HTTP 401/403 as POSIXError or URLError
        // with specific codes; network timeouts use different domains/codes.
        if nsError.domain == NSURLErrorDomain {
            // Explicit server rejection codes (not timeouts or connectivity)
            return [
                NSURLErrorUserAuthenticationRequired,  // -1013
                NSURLErrorUserCancelledAuthentication,  // -1012
            ].contains(nsError.code)
        }
        return false
    }

    private func scheduleReconnect() async {
        guard currentOwner != nil else { return }
        reconnectAttempts += 1

        if reconnectAttempts > Self.maxReconnectAttempts {
            log.error("Max reconnect attempts (\(Self.maxReconnectAttempts)) exceeded, giving up")
            _isConnected = false
            return
        }

        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), Self.maxBackoff)
        log.info("Reconnecting in \(delay)s (attempt \(self.reconnectAttempts))")

        do {
            try await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            startConnection()
        } catch {
            // Cancelled during sleep
        }
    }
}
