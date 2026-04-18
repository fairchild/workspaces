import Combine
import Foundation
import WorkspaceManagerCore
import os.log

private let log = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "NotificationCoordinator"
)

protocol NotificationCredentialStoreProtocol: Sendable {
    func loadString(key: String) throws -> String
    func saveString(key: String, value: String) throws
    func delete(key: String) throws
}

enum NotificationCredentialStoreError: Error {
    case missingValue(String)
}

struct KeychainNotificationCredentialStore: NotificationCredentialStoreProtocol {
    func loadString(key: String) throws -> String {
        guard let value = try KeychainHelper.loadString(key: key) else {
            throw NotificationCredentialStoreError.missingValue(key)
        }
        return value
    }

    func saveString(key: String, value: String) throws {
        try KeychainHelper.saveString(key: key, value: value)
    }

    func delete(key: String) throws {
        try KeychainHelper.delete(key: key)
    }
}

@MainActor
final class NotificationCoordinator: NotificationCoordinatorProtocol, ObservableObject {
    static let shared = NotificationCoordinator()

    private struct StoredAuthSnapshot: Sendable {
        let login: String?
        let jwtExpiry: Date?
    }

    private actor StoredAuthLoader {
        func loadSnapshot(
            from credentialStore: any NotificationCredentialStoreProtocol
        ) -> StoredAuthSnapshot {
            let login = try? credentialStore.loadString(
                key: NotificationConstants.keychainLoginKey
            )
            let jwt = try? credentialStore.loadString(
                key: NotificationConstants.keychainJWTKey
            )

            return StoredAuthSnapshot(
                login: login,
                jwtExpiry: jwt.flatMap(NotificationCoordinator.parseJWTExpiry)
            )
        }
    }

    @Published private(set) var authState: NotificationAuthState = .signedOut
    @Published private(set) var isStreamConnected = false
    @Published private(set) var events: [WebhookEvent] = []
    @Published private(set) var unseenEventCount: Int = 0

    private let eventStreamService: any EventStreamServiceProtocol
    private let sessionService: any NotificationSessionServiceProtocol
    private let makeDeviceAuth: @Sendable () -> any GitHubDeviceAuthProtocol
    private var currentDeviceAuth: (any GitHubDeviceAuthProtocol)?
    private var eventListenerTask: Task<Void, Never>?
    private var connectionPollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var jwtRefreshTask: Task<Bool, Never>?
    private var storedAuthLoadTask: Task<Void, Never>?
    private var currentRemoteURL: String?
    private var seenEventIDs: Set<String> = []
    private let credentialStore: any NotificationCredentialStoreProtocol
    private let userDefaults: UserDefaults
    private static let maxEvents = 100
    private static let refreshMargin: TimeInterval = 15 * 60
    private static let storedAuthLoader = StoredAuthLoader()

    init(
        eventStreamService: any EventStreamServiceProtocol = EventStreamService(),
        sessionService: any NotificationSessionServiceProtocol = NotificationSessionService(),
        credentialStore: any NotificationCredentialStoreProtocol = KeychainNotificationCredentialStore(),
        userDefaults: UserDefaults = .standard,
        makeDeviceAuth: @escaping @Sendable () -> any GitHubDeviceAuthProtocol = {
            GitHubDeviceAuth(clientID: NotificationConstants.gitHubAppClientID)
        }
    ) {
        self.eventStreamService = eventStreamService
        self.sessionService = sessionService
        self.credentialStore = credentialStore
        self.userDefaults = userDefaults
        self.makeDeviceAuth = makeDeviceAuth
    }

    deinit {
        MainActor.assumeIsolated {
            storedAuthLoadTask?.cancel()
            eventListenerTask?.cancel()
            connectionPollingTask?.cancel()
            refreshTask?.cancel()
            jwtRefreshTask?.cancel()
        }
    }

    func loadStoredAuth() {
        storedAuthLoadTask?.cancel()

        let credentialStore = self.credentialStore
        storedAuthLoadTask = Task { [weak self] in
            let snapshot = await Self.storedAuthLoader.loadSnapshot(from: credentialStore)
            guard !Task.isCancelled else { return }
            self?.applyStoredAuthSnapshot(snapshot)
        }
    }

    func startDeviceFlow() async {
        authState = .requestingCode

        let auth = makeDeviceAuth()
        currentDeviceAuth = auth

        do {
            let deviceCode = try await auth.requestDeviceCode()

            authState = .awaitingUserAuth(
                userCode: deviceCode.userCode,
                verificationURL: deviceCode.verificationURI
            )

            let token = try await auth.pollForToken(
                deviceCode: deviceCode.deviceCode,
                interval: deviceCode.interval
            )

            authState = .exchangingToken

            let session = try await sessionService.createSession(
                githubToken: token.accessToken
            )

            try storeCredentials(
                githubToken: token.accessToken,
                jwt: session.jwt,
                login: session.login
            )

            authState = .signedIn(login: session.login)
            scheduleRefresh()
        } catch {
            authState = .failed(error.localizedDescription)
        }

        currentDeviceAuth = nil
    }

    func signOut() {
        currentDeviceAuth = nil
        storedAuthLoadTask?.cancel()
        storedAuthLoadTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        jwtRefreshTask?.cancel()
        jwtRefreshTask = nil
        currentRemoteURL = nil

        for key in [
            NotificationConstants.keychainJWTKey,
            NotificationConstants.keychainLoginKey,
            NotificationConstants.keychainGitHubTokenKey,
        ] {
            do {
                try credentialStore.delete(key: key)
            } catch {
                log.warning("Failed to delete keychain item \(key): \(error.localizedDescription)")
            }
        }

        Task { await eventStreamService.disconnect() }
        eventListenerTask?.cancel()
        eventListenerTask = nil
        connectionPollingTask?.cancel()
        connectionPollingTask = nil
        isStreamConnected = false
        clearActivity()
        authState = .signedOut
    }

    func connectStream(remoteURL: String) async {
        let enabled = userDefaults.bool(forKey: NotificationConstants.enabledKey)
        guard enabled else { return }

        currentRemoteURL = remoteURL

        if jwtNeedsRefresh() {
            let refreshed = await refreshJWT()
            guard refreshed else {
                signOut()
                return
            }
        }

        await startStream(remoteURL: remoteURL, resetActivity: true)
    }

    func disconnectStream() async {
        await eventStreamService.disconnect()
        eventListenerTask?.cancel()
        eventListenerTask = nil
        connectionPollingTask?.cancel()
        connectionPollingTask = nil
        currentRemoteURL = nil
        isStreamConnected = false
        clearActivity()
    }

    func markActivitySeen() {
        unseenEventCount = 0
    }

    // MARK: - Private

    private func handleEvent(_ event: WebhookEvent) {
        isStreamConnected = true
        guard seenEventIDs.insert(event.id).inserted else { return }
        events.insert(event, at: 0)
        if events.count > Self.maxEvents {
            let overflowCount = events.count - Self.maxEvents
            for event in events.suffix(overflowCount) {
                seenEventIDs.remove(event.id)
            }
            events.removeLast(overflowCount)
        }
        unseenEventCount += 1
    }

    private func clearActivity() {
        events = []
        seenEventIDs.removeAll()
        unseenEventCount = 0
    }

    private func startStream(
        remoteURL: String, resetActivity: Bool
    ) async {
        var jwt: String?
        var githubToken: String?
        do {
            jwt = try credentialStore.loadString(key: NotificationConstants.keychainJWTKey)
            githubToken = try credentialStore.loadString(key: NotificationConstants.keychainGitHubTokenKey)
        } catch {
            log.error("Failed to load credentials from keychain: \(error.localizedDescription)")
            jwt = nil
            githubToken = nil
        }
        guard let jwt, let githubToken, let owner = Self.parseOwner(from: remoteURL) else {
            await eventStreamService.disconnect()
            isStreamConnected = false
            return
        }

        if resetActivity {
            clearActivity()
        }

        isStreamConnected = false
        eventListenerTask?.cancel()
        connectionPollingTask?.cancel()

        await eventStreamService.connect(
            owner: owner, jwt: jwt, githubToken: githubToken
        )

        let stream = await eventStreamService.events
        eventListenerTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.handleEvent(event)
            }
        }

        connectionPollingTask = Task { @MainActor [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if await self?.eventStreamService.isConnected == true {
                    self?.isStreamConnected = true
                    return
                }
                if await self?.eventStreamService.lastDisconnectReason == .authFailure {
                    log.warning("Stream auth rejected, signing out")
                    self?.signOut()
                    return
                }
            }
        }
    }

    // MARK: - JWT refresh

    @discardableResult
    private func refreshJWT() async -> Bool {
        if let jwtRefreshTask {
            return await jwtRefreshTask.value
        }

        let task = Task<Bool, Never> { @MainActor in
            guard
                let githubToken = try? credentialStore.loadString(
                    key: NotificationConstants.keychainGitHubTokenKey)
            else {
                log.warning("No stored GitHub token — cannot refresh JWT")
                return false
            }

            do {
                let session = try await sessionService.createSession(
                    githubToken: githubToken
                )
                try updateSessionCredentials(
                    jwt: session.jwt, login: session.login
                )
                log.info("JWT refreshed, expires \(session.expiresAt)")
                scheduleRefresh(expiresAt: session.expiresAt)
                return true
            } catch {
                log.error("JWT refresh failed: \(error.localizedDescription)")
                return false
            }
        }

        jwtRefreshTask = task
        let refreshed = await task.value
        jwtRefreshTask = nil
        return refreshed
    }

    private func refreshJWTOrSignOut() async {
        let refreshed = await refreshJWT()
        if !refreshed {
            signOut()
            return
        }

        let enabled = userDefaults.bool(
            forKey: NotificationConstants.enabledKey
        )
        guard enabled, let remoteURL = currentRemoteURL else { return }
        await startStream(remoteURL: remoteURL, resetActivity: false)
    }

    private func refreshStoredJWTOrSignOut() async {
        let refreshed = await refreshJWT()
        if !refreshed {
            signOut()
        }
    }

    private func scheduleRefresh() {
        guard let expiresAt = jwtExpiry() else { return }
        scheduleRefresh(expiresAt: expiresAt)
    }

    private func scheduleRefresh(expiresAt: Date) {
        refreshTask?.cancel()

        let delay = max(
            expiresAt.timeIntervalSinceNow - Self.refreshMargin, 0
        )
        log.info("JWT refresh scheduled in \(Int(delay))s")

        refreshTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            await self?.refreshJWTOrSignOut()
        }
    }

    // MARK: - Persistence

    private func storeCredentials(
        githubToken: String, jwt: String, login: String
    ) throws {
        do {
            try credentialStore.saveString(
                key: NotificationConstants.keychainGitHubTokenKey,
                value: githubToken
            )
            try updateSessionCredentials(jwt: jwt, login: login)
        } catch {
            try? credentialStore.delete(key: NotificationConstants.keychainGitHubTokenKey)
            try? credentialStore.delete(key: NotificationConstants.keychainJWTKey)
            try? credentialStore.delete(key: NotificationConstants.keychainLoginKey)
            throw error
        }
    }

    private func updateSessionCredentials(
        jwt: String, login: String
    ) throws {
        do {
            try credentialStore.saveString(
                key: NotificationConstants.keychainJWTKey,
                value: jwt
            )
            try credentialStore.saveString(
                key: NotificationConstants.keychainLoginKey,
                value: login
            )
        } catch {
            try? credentialStore.delete(key: NotificationConstants.keychainJWTKey)
            try? credentialStore.delete(key: NotificationConstants.keychainLoginKey)
            throw error
        }
    }

    // MARK: - JWT helpers

    private func jwtNeedsRefresh() -> Bool {
        guard let expiresAt = jwtExpiry() else { return true }
        return expiresAt.timeIntervalSinceNow < Self.refreshMargin
    }

    private func jwtExpiry() -> Date? {
        guard
            let jwt = try? credentialStore.loadString(
                key: NotificationConstants.keychainJWTKey)
        else { return nil }
        return Self.parseJWTExpiry(jwt)
    }

    private func applyStoredAuthSnapshot(_ snapshot: StoredAuthSnapshot) {
        storedAuthLoadTask = nil

        guard let login = snapshot.login else {
            return
        }

        authState = .signedIn(login: login)

        if let jwtExpiry = snapshot.jwtExpiry,
            jwtExpiry.timeIntervalSinceNow >= Self.refreshMargin
        {
            scheduleRefresh(expiresAt: jwtExpiry)
        } else {
            Task { await refreshStoredJWTOrSignOut() }
        }
    }

    nonisolated static func parseJWTExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }

        guard let data = Data(base64Encoded: base64) else { return nil }

        struct Payload: Decodable {
            let exp: TimeInterval
        }

        guard
            let payload = try? JSONDecoder().decode(
                Payload.self, from: data)
        else { return nil }

        return Date(timeIntervalSince1970: payload.exp)
    }

    static func parseOwner(from remoteURL: String) -> String? {
        let cleaned =
            remoteURL
            .replacingOccurrences(of: "git@github.com:", with: "")
            .replacingOccurrences(of: "https://github.com/", with: "")
            .replacingOccurrences(of: ".git", with: "")
        let parts = cleaned.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return String(parts[parts.count - 2])
    }
}
