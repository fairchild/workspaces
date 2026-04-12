import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("GitHubDeviceAuth")
struct GitHubDeviceAuthTests {

    @Test("requestDeviceCode succeeds with valid response")
    func requestDeviceCodeSuccess() async throws {
        let session = MockURLProtocol.session(handlers: [
            "/login/device/code": (
                json: [
                    "device_code": "test-device-code",
                    "user_code": "ABCD-1234",
                    "verification_uri": "https://github.com/login/device",
                    "expires_in": 900,
                    "interval": 5,
                ],
                statusCode: 200
            )
        ])

        let auth = GitHubDeviceAuth(
            clientID: "test-client-id",
            session: session
        )
        let response = try await auth.requestDeviceCode()

        #expect(response.deviceCode == "test-device-code")
        #expect(response.userCode == "ABCD-1234")
        #expect(response.verificationURI == "https://github.com/login/device")
        #expect(response.expiresIn == 900)
        #expect(response.interval == 5)
    }

    @Test("requestDeviceCode throws on 404 (Device Flow not enabled)")
    func requestDeviceCode404() async {
        let session = MockURLProtocol.session(handlers: [
            "/login/device/code": (
                json: ["error": "Not Found"],
                statusCode: 404
            )
        ])

        let auth = GitHubDeviceAuth(
            clientID: "bad-client-id",
            session: session
        )

        do {
            _ = try await auth.requestDeviceCode()
            Issue.record("Expected requestFailed error")
        } catch let error as DeviceAuthError {
            guard case .requestFailed(let code) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(code == 404)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("pollForToken returns token on success")
    func pollForTokenSuccess() async throws {
        let session = MockURLProtocol.session(handlers: [
            "/login/oauth/access_token": (
                json: [
                    "access_token": "ghu_test123",
                    "token_type": "bearer",
                    "scope": "",
                ],
                statusCode: 200
            )
        ])

        let auth = GitHubDeviceAuth(
            clientID: "test-client-id",
            session: session,
            minPollInterval: 0
        )

        let token = try await auth.pollForToken(deviceCode: "test-code", interval: 0)

        #expect(token.accessToken == "ghu_test123")
        #expect(token.tokenType == "bearer")
    }

    @Test("pollForToken throws on expired_token")
    func pollForTokenExpired() async {
        let session = MockURLProtocol.session(handlers: [
            "/login/oauth/access_token": (
                json: ["error": "expired_token"],
                statusCode: 200
            )
        ])

        let auth = GitHubDeviceAuth(
            clientID: "test-client-id",
            session: session,
            minPollInterval: 0
        )

        do {
            _ = try await auth.pollForToken(deviceCode: "test-code", interval: 0)
            Issue.record("Expected expired error")
        } catch let error as DeviceAuthError {
            guard case .expired = error else {
                Issue.record("Expected expired, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("pollForToken throws on access_denied")
    func pollForTokenDenied() async {
        let session = MockURLProtocol.session(handlers: [
            "/login/oauth/access_token": (
                json: ["error": "access_denied"],
                statusCode: 200
            )
        ])

        let auth = GitHubDeviceAuth(
            clientID: "test-client-id",
            session: session,
            minPollInterval: 0
        )

        do {
            _ = try await auth.pollForToken(deviceCode: "test-code", interval: 0)
            Issue.record("Expected accessDenied error")
        } catch let error as DeviceAuthError {
            guard case .accessDenied = error else {
                Issue.record("Expected accessDenied, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("cancel stops polling")
    func cancelStopsPolling() async {
        let session = MockURLProtocol.session(handlers: [
            "/login/oauth/access_token": (
                json: ["error": "authorization_pending"],
                statusCode: 200
            )
        ])

        let auth = GitHubDeviceAuth(
            clientID: "test-client-id",
            session: session,
            minPollInterval: 0
        )

        Task {
            try? await Task.sleep(for: .milliseconds(100))
            await auth.cancel()
        }

        do {
            _ = try await auth.pollForToken(deviceCode: "test-code", interval: 0)
            Issue.record("Expected cancelled error")
        } catch is CancellationError {
            // Task.sleep throws CancellationError, which is fine
        } catch let error as DeviceAuthError {
            guard case .cancelled = error else {
                Issue.record("Expected cancelled, got \(error)")
                return
            }
        } catch {
            // Task cancellation is acceptable
        }
    }
}
