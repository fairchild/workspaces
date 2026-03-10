import Combine
import Foundation
import WorkspaceManagerCore
import os.log

private let log = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "NotificationCoordinator"
)

@MainActor
final class NotificationCoordinator: NotificationCoordinatorProtocol, ObservableObject {
    static let shared = NotificationCoordinator()

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
    private var currentRemoteURL: String?
    private static let maxEvents = 100
    private static let refreshMargin: TimeInterval = 15 * 60

    init(
        eventStreamService: any EventStreamServiceProtocol = EventStreamService(),
        sessionService: any NotificationSessionServiceProtocol = NotificationSessionService(),
        makeDeviceAuth: @escaping @Sendable () -> any GitHubDeviceAuthProtocol = {
            GitHubDeviceAuth(clientID: NotificationConstants.gitHubAppClientID)
        }
    ) {
        self.eventStreamService = eventStreamService
        self.sessionService = sessionService
        self.makeDeviceAuth = makeDeviceAuth
    }

    func loadStoredAuth() {
        guard
            let login = try? KeychainHelper.loadString(
                key: NotificationConstants.keychainLoginKey)
        else {
            return
        }

        authState = .signedIn(login: login)

        if jwtNeedsRefresh() {
            Task { await refreshJWTOrSignOut() }
        } else {
            scheduleRefresh()
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
        refreshTask?.cancel()
        refreshTask = nil
        currentRemoteURL = nil

        for key in [
            NotificationConstants.keychainJWTKey,
            NotificationConstants.keychainLoginKey,
            NotificationConstants.keychainGitHubTokenKey,
        ] {
            do {
                try KeychainHelper.delete(key: key)
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
        events = []
        unseenEventCount = 0
        authState = .signedOut
    }

    func connectStream(remoteURL: String) async {
        let enabled = UserDefaults.standard.bool(forKey: NotificationConstants.enabledKey)
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
        events = []
        unseenEventCount = 0
    }

    func markActivitySeen() {
        unseenEventCount = 0
    }

    // MARK: - Private

    private func handleEvent(_ event: WebhookEvent) {
        isStreamConnected = true
        events.insert(event, at: 0)
        if events.count > Self.maxEvents {
            events.removeLast(events.count - Self.maxEvents)
        }
        unseenEventCount += 1
    }

    private func startStream(
        remoteURL: String, resetActivity: Bool
    ) async {
        var jwt: String?
        var githubToken: String?
        do {
            jwt = try KeychainHelper.loadString(key: NotificationConstants.keychainJWTKey)
            githubToken = try KeychainHelper.loadString(key: NotificationConstants.keychainGitHubTokenKey)
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
            events = []
            unseenEventCount = 0
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
        guard
            let githubToken = try? KeychainHelper.loadString(
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
            scheduleRefresh()
            return true
        } catch {
            log.error("JWT refresh failed: \(error.localizedDescription)")
            return false
        }
    }

    private func refreshJWTOrSignOut() async {
        let refreshed = await refreshJWT()
        if !refreshed {
            signOut()
            return
        }

        let enabled = UserDefaults.standard.bool(
            forKey: NotificationConstants.enabledKey
        )
        guard enabled, let remoteURL = currentRemoteURL else { return }
        await startStream(remoteURL: remoteURL, resetActivity: false)
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()

        guard let expiresAt = jwtExpiry() else { return }

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
            try KeychainHelper.saveString(
                key: NotificationConstants.keychainGitHubTokenKey,
                value: githubToken
            )
            try updateSessionCredentials(jwt: jwt, login: login)
        } catch {
            try? KeychainHelper.delete(key: NotificationConstants.keychainGitHubTokenKey)
            try? KeychainHelper.delete(key: NotificationConstants.keychainJWTKey)
            try? KeychainHelper.delete(key: NotificationConstants.keychainLoginKey)
            throw error
        }
    }

    private func updateSessionCredentials(
        jwt: String, login: String
    ) throws {
        do {
            try KeychainHelper.saveString(
                key: NotificationConstants.keychainJWTKey,
                value: jwt
            )
            try KeychainHelper.saveString(
                key: NotificationConstants.keychainLoginKey,
                value: login
            )
        } catch {
            try? KeychainHelper.delete(key: NotificationConstants.keychainJWTKey)
            try? KeychainHelper.delete(key: NotificationConstants.keychainLoginKey)
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
            let jwt = try? KeychainHelper.loadString(
                key: NotificationConstants.keychainJWTKey)
        else { return nil }
        return Self.parseJWTExpiry(jwt)
    }

    static func parseJWTExpiry(_ jwt: String) -> Date? {
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
