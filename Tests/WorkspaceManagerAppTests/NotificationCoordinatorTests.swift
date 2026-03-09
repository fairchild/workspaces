import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

// MARK: - Mock

actor MockEventStreamService: EventStreamServiceProtocol {
    private var _isConnected = false
    private var _lastDisconnectReason: StreamDisconnectReason = .none
    private var continuation: AsyncStream<WebhookEvent>.Continuation?
    private var _events: AsyncStream<WebhookEvent>?

    var connectCalls: [(owner: String, jwt: String)] = []
    var disconnectCallCount = 0

    var isConnected: Bool { _isConnected }
    var lastDisconnectReason: StreamDisconnectReason { _lastDisconnectReason }

    var events: AsyncStream<WebhookEvent> {
        if let existing = _events { return existing }
        let (stream, cont) = AsyncStream<WebhookEvent>.makeStream()
        self.continuation = cont
        self._events = stream
        return stream
    }

    func connect(owner: String, jwt: String, githubToken: String?) {
        connectCalls.append((owner: owner, jwt: jwt))
        _isConnected = true
        _lastDisconnectReason = .none
        _ = events
    }

    func disconnect() {
        disconnectCallCount += 1
        _isConnected = false
        continuation?.finish()
        continuation = nil
        _events = nil
    }

    func setConnected(_ value: Bool) {
        _isConnected = value
    }

    func setLastDisconnectReason(_ reason: StreamDisconnectReason) {
        _lastDisconnectReason = reason
    }
}

// MARK: - Tests

@MainActor
@Suite("NotificationCoordinator")
struct NotificationCoordinatorTests {

    // MARK: - parseJWTExpiry

    @Test("parseJWTExpiry decodes exp claim from valid JWT")
    func parseJWTExpiryValid() {
        // JWT payload: {"sub":"user","exp":1741564800} (2025-03-10T00:00:00Z)
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIiwiZXhwIjoxNzQxNTY0ODAwfQ.sig"
        let expiry = NotificationCoordinator.parseJWTExpiry(jwt)

        #expect(expiry == Date(timeIntervalSince1970: 1_741_564_800))
    }

    @Test("parseJWTExpiry returns nil for malformed JWT")
    func parseJWTExpiryMalformed() {
        #expect(NotificationCoordinator.parseJWTExpiry("not-a-jwt") == nil)
        #expect(NotificationCoordinator.parseJWTExpiry("") == nil)
        #expect(NotificationCoordinator.parseJWTExpiry("a.b") == nil)
    }

    @Test("parseJWTExpiry returns nil when exp claim is missing")
    func parseJWTExpiryMissingExp() {
        // JWT payload: {"sub":"user"} (no exp)
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.sig"
        #expect(NotificationCoordinator.parseJWTExpiry(jwt) == nil)
    }

    @Test("parseJWTExpiry handles base64url padding")
    func parseJWTExpiryBase64URLPadding() {
        // JWT payload: {"exp":1741564800} — shorter payload needs padding
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjE3NDE1NjQ4MDB9.sig"
        let expiry = NotificationCoordinator.parseJWTExpiry(jwt)

        #expect(expiry == Date(timeIntervalSince1970: 1_741_564_800))
    }

    // MARK: - parseOwner

    @Test("parseOwner extracts owner from SSH remote URL")
    func parseOwnerSSH() {
        let owner = NotificationCoordinator.parseOwner(
            from: "git@github.com:my-org/my-repo.git"
        )
        #expect(owner == "my-org")
    }

    @Test("parseOwner extracts owner from HTTPS remote URL")
    func parseOwnerHTTPS() {
        let owner = NotificationCoordinator.parseOwner(
            from: "https://github.com/octocat/hello-world.git"
        )
        #expect(owner == "octocat")
    }

    @Test("parseOwner handles URL without .git suffix")
    func parseOwnerNoGitSuffix() {
        let owner = NotificationCoordinator.parseOwner(
            from: "https://github.com/octocat/hello-world"
        )
        #expect(owner == "octocat")
    }

    @Test("parseOwner returns nil for invalid URL")
    func parseOwnerInvalid() {
        #expect(NotificationCoordinator.parseOwner(from: "") == nil)
        #expect(NotificationCoordinator.parseOwner(from: "not-a-url") == nil)
    }

    // MARK: - Coordinator initial state

    @Test("Coordinator starts in signedOut state with empty events")
    func initialState() {
        let mock = MockEventStreamService()
        let coordinator = NotificationCoordinator(eventStreamService: mock)

        #expect(coordinator.authState == .signedOut)
        #expect(coordinator.isStreamConnected == false)
        #expect(coordinator.events.isEmpty)
        #expect(coordinator.unseenEventCount == 0)
    }

    @Test("markActivitySeen resets unseen count")
    func markActivitySeen() {
        let mock = MockEventStreamService()
        let coordinator = NotificationCoordinator(eventStreamService: mock)

        coordinator.markActivitySeen()
        #expect(coordinator.unseenEventCount == 0)
    }

    @Test("signOut resets all state")
    func signOutResetsState() {
        let mock = MockEventStreamService()
        let coordinator = NotificationCoordinator(eventStreamService: mock)

        coordinator.signOut()

        #expect(coordinator.authState == .signedOut)
        #expect(coordinator.isStreamConnected == false)
        #expect(coordinator.events.isEmpty)
        #expect(coordinator.unseenEventCount == 0)
    }
}
