// swift-format-ignore-file: NeverForceUnwrap
// Test fixtures/helpers force-unwrap known-good literals or generator output; a failure here is a loud test crash, not a user-facing risk.
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

    var connectCalls: [(owner: String, jwt: String, githubToken: String?)] = []
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
        connectCalls.append((owner: owner, jwt: jwt, githubToken: githubToken))
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

    func emit(_ event: WebhookEvent) {
        continuation?.yield(event)
    }
}

final class MockNotificationCredentialStore: NotificationCredentialStoreProtocol, @unchecked Sendable {
    private var values: [String: String]
    private(set) var deletedKeys: [String] = []

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func loadString(key: String) throws -> String {
        guard let value = values[key] else {
            throw TestStoreError.missingValue(key)
        }
        return value
    }

    func saveString(key: String, value: String) throws {
        values[key] = value
    }

    func delete(key: String) throws {
        values.removeValue(forKey: key)
        deletedKeys.append(key)
    }
}

enum TestStoreError: Error {
    case missingValue(String)
}

// MARK: - Tests

@MainActor
@Suite("NotificationCoordinator")
struct NotificationCoordinatorTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "NotificationCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(false, forKey: NotificationConstants.enabledKey)
        return defaults
    }

    private func makeCoordinator(
        eventStreamService: MockEventStreamService = MockEventStreamService(),
        credentialStore: MockNotificationCredentialStore = MockNotificationCredentialStore(),
        userDefaults: UserDefaults? = nil
    ) -> NotificationCoordinator {
        NotificationCoordinator(
            eventStreamService: eventStreamService,
            credentialStore: credentialStore,
            userDefaults: userDefaults ?? makeDefaults()
        )
    }

    private func makeEvent(
        id: String,
        summary: String,
        timestamp: TimeInterval
    ) -> WebhookEvent {
        WebhookEvent(
            id: id,
            type: "pull_request",
            action: "opened",
            summary: summary,
            repo: "test-org/repo-a",
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
    }

    private func waitForEventCount(
        _ expectedCount: Int,
        coordinator: NotificationCoordinator,
        timeoutMilliseconds: Int = 250
    ) async {
        let attempts = max(timeoutMilliseconds / 10, 1)
        for _ in 0..<attempts {
            if coordinator.events.count == expectedCount {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        Issue.record(
            "Timed out waiting for \(expectedCount) delivered events. Saw \(coordinator.events.count)."
        )
    }

    private func waitForAuthState(
        _ expectedState: NotificationAuthState,
        coordinator: NotificationCoordinator,
        timeoutMilliseconds: Int = 250
    ) async {
        let attempts = max(timeoutMilliseconds / 10, 1)
        for _ in 0..<attempts {
            if coordinator.authState == expectedState {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        Issue.record("Timed out waiting for auth state \(String(describing: expectedState)).")
    }

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
        let coordinator = makeCoordinator()

        #expect(coordinator.authState == .signedOut)
        #expect(coordinator.isStreamConnected == false)
        #expect(coordinator.events.isEmpty)
        #expect(coordinator.unseenEventCount == 0)
    }

    @Test("markActivitySeen resets unseen count")
    func markActivitySeen() {
        let coordinator = makeCoordinator()

        coordinator.markActivitySeen()
        #expect(coordinator.unseenEventCount == 0)
    }

    @Test("signOut resets all state")
    func signOutResetsState() {
        let credentials = MockNotificationCredentialStore(
            values: [
                NotificationConstants.keychainJWTKey: "jwt",
                NotificationConstants.keychainLoginKey: "login",
                NotificationConstants.keychainGitHubTokenKey: "ghp",
            ]
        )
        let coordinator = makeCoordinator(credentialStore: credentials)

        coordinator.signOut()

        #expect(coordinator.authState == .signedOut)
        #expect(coordinator.isStreamConnected == false)
        #expect(coordinator.events.isEmpty)
        #expect(coordinator.unseenEventCount == 0)
        let deletedKeys = Set(credentials.deletedKeys)
        let expectedKeys = Set([
            NotificationConstants.keychainJWTKey,
            NotificationConstants.keychainLoginKey,
            NotificationConstants.keychainGitHubTokenKey,
        ])
        #expect(deletedKeys == expectedKeys)
    }

    @Test("loadStoredAuth restores signed-in state from injected credentials")
    func loadStoredAuthRestoresSignedInState() async {
        let coordinator = makeCoordinator(
            credentialStore: MockNotificationCredentialStore(
                values: [
                    NotificationConstants.keychainLoginKey: "local-test-user",
                    NotificationConstants.keychainJWTKey:
                        "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDB9.sig",
                ]
            )
        )

        coordinator.loadStoredAuth()
        await waitForAuthState(
            .signedIn(login: "local-test-user"),
            coordinator: coordinator
        )

        #expect(coordinator.authState == .signedIn(login: "local-test-user"))
    }

    @Test("connectStream does nothing when notifications are disabled")
    func connectStreamDisabledDoesNothing() async {
        let eventStream = MockEventStreamService()
        let coordinator = makeCoordinator(
            eventStreamService: eventStream,
            credentialStore: MockNotificationCredentialStore(
                values: [
                    NotificationConstants.keychainJWTKey: "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDB9.sig",
                    NotificationConstants.keychainGitHubTokenKey: "ghp_test_token",
                ]
            ),
            userDefaults: makeDefaults()
        )

        await coordinator.connectStream(remoteURL: "https://github.com/test-org/repo-a.git")

        let calls = await eventStream.connectCalls
        #expect(calls.isEmpty)
    }

    @Test("connectStream uses injected credentials when notifications are enabled")
    func connectStreamUsesStoredCredentials() async {
        let eventStream = MockEventStreamService()
        let credentials = MockNotificationCredentialStore(
            values: [
                NotificationConstants.keychainJWTKey: "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDB9.sig",
                NotificationConstants.keychainGitHubTokenKey: "ghp_test_token",
            ]
        )
        let defaults = makeDefaults()
        defaults.set(true, forKey: NotificationConstants.enabledKey)
        let coordinator = makeCoordinator(
            eventStreamService: eventStream,
            credentialStore: credentials,
            userDefaults: defaults
        )

        await coordinator.connectStream(remoteURL: "https://github.com/test-org/repo-a.git")

        let calls = await eventStream.connectCalls
        #expect(calls.count == 1)
        #expect(calls[0].owner == "test-org")
        #expect(calls[0].jwt == "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDB9.sig")
        #expect(calls[0].githubToken == "ghp_test_token")
    }

    @Test("replayed event IDs are ignored without inflating unseen count")
    func replayedEventsIgnored() async {
        let eventStream = MockEventStreamService()
        let credentials = MockNotificationCredentialStore(
            values: [
                NotificationConstants.keychainJWTKey: "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDB9.sig",
                NotificationConstants.keychainGitHubTokenKey: "ghp_test_token",
            ]
        )
        let defaults = makeDefaults()
        defaults.set(true, forKey: NotificationConstants.enabledKey)
        let coordinator = makeCoordinator(
            eventStreamService: eventStream,
            credentialStore: credentials,
            userDefaults: defaults
        )

        await coordinator.connectStream(remoteURL: "https://github.com/test-org/repo-a.git")

        let first = makeEvent(id: "evt-1", summary: "PR #1 opened", timestamp: 1_710_000_000)
        let second = makeEvent(id: "evt-2", summary: "PR #2 opened", timestamp: 1_710_000_100)

        await eventStream.emit(first)
        await eventStream.emit(second)
        await waitForEventCount(2, coordinator: coordinator)

        #expect(coordinator.events.map(\.id) == ["evt-2", "evt-1"])
        #expect(coordinator.unseenEventCount == 2)

        await eventStream.emit(first)
        await eventStream.emit(second)
        await waitForEventCount(2, coordinator: coordinator)

        #expect(coordinator.events.map(\.id) == ["evt-2", "evt-1"])
        #expect(coordinator.unseenEventCount == 2)
    }

    @Test("disconnect clears dedupe state so fresh sessions can show the same event again")
    func disconnectClearsDedupeState() async {
        let eventStream = MockEventStreamService()
        let credentials = MockNotificationCredentialStore(
            values: [
                NotificationConstants.keychainJWTKey: "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDB9.sig",
                NotificationConstants.keychainGitHubTokenKey: "ghp_test_token",
            ]
        )
        let defaults = makeDefaults()
        defaults.set(true, forKey: NotificationConstants.enabledKey)
        let coordinator = makeCoordinator(
            eventStreamService: eventStream,
            credentialStore: credentials,
            userDefaults: defaults
        )

        await coordinator.connectStream(remoteURL: "https://github.com/test-org/repo-a.git")

        let event = makeEvent(id: "evt-1", summary: "PR #1 opened", timestamp: 1_710_000_000)
        await eventStream.emit(event)
        await waitForEventCount(1, coordinator: coordinator)

        #expect(coordinator.events.map(\.id) == ["evt-1"])

        await coordinator.disconnectStream()
        #expect(coordinator.events.isEmpty)
        #expect(coordinator.unseenEventCount == 0)

        await coordinator.connectStream(remoteURL: "https://github.com/test-org/repo-a.git")
        await eventStream.emit(event)
        await waitForEventCount(1, coordinator: coordinator)

        #expect(coordinator.events.map(\.id) == ["evt-1"])
    }
}
