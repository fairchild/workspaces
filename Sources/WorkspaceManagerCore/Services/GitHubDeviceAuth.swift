import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "GitHubDeviceAuth")

public struct DeviceCodeResponse: Codable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: String
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

public struct GitHubAuthToken: Codable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
    }
}

public enum DeviceAuthError: Error, LocalizedError {
    case requestFailed(Int)
    case expired
    case accessDenied
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let code): "GitHub request failed with status \(code)"
        case .expired: "The device code has expired. Please try again."
        case .accessDenied: "Access was denied. Please try again."
        case .cancelled: "Authentication was cancelled."
        }
    }
}

public actor GitHubDeviceAuth: GitHubDeviceAuthProtocol {
    private let clientID: String
    private let session: URLSession
    private let minPollInterval: Int
    private var isCancelled = false

    public init(clientID: String, session: URLSession = .shared, minPollInterval: Int = 5) {
        self.clientID = clientID
        self.session = session
        self.minPollInterval = minPollInterval
    }

    public func cancel() {
        isCancelled = true
    }

    public func requestDeviceCode(scope: String = "") async throws -> DeviceCodeResponse {
        isCancelled = false

        // swift-format-ignore: NeverForceUnwrap
        // Safe: constant URL string, always parses successfully.
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = ["client_id": clientID]
        if !scope.isEmpty {
            body["scope"] = scope
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeviceAuthError.requestFailed(-1)
        }

        guard httpResponse.statusCode == 200 else {
            log.error("Device code request failed: \(httpResponse.statusCode)")
            throw DeviceAuthError.requestFailed(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        log.info("Device code obtained, user code: \(decoded.userCode)")
        return decoded
    }

    public func pollForToken(deviceCode: String, interval: Int) async throws -> GitHubAuthToken {
        var pollInterval = max(interval, minPollInterval)

        while !isCancelled {
            try await Task.sleep(for: .seconds(pollInterval))

            guard !isCancelled else {
                throw DeviceAuthError.cancelled
            }

            // swift-format-ignore: NeverForceUnwrap
            // Safe: constant URL string, always parses successfully.
            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: String] = [
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ]
            request.httpBody = try JSONEncoder().encode(body)

            let (data, _) = try await session.data(for: request)

            // GitHub returns 200 for all responses, error is in the body
            if let token = try? JSONDecoder().decode(GitHubAuthToken.self, from: data) {
                log.info("Successfully obtained access token")
                return token
            }

            let errorResponse = try JSONDecoder().decode(DeviceAuthErrorResponse.self, from: data)
            switch errorResponse.error {
            case "authorization_pending":
                continue
            case "slow_down":
                pollInterval += 5
                continue
            case "expired_token":
                throw DeviceAuthError.expired
            case "access_denied":
                throw DeviceAuthError.accessDenied
            default:
                log.error("Unexpected poll error: \(errorResponse.error)")
                throw DeviceAuthError.requestFailed(0)
            }
        }

        throw DeviceAuthError.cancelled
    }
}

private struct DeviceAuthErrorResponse: Codable {
    let error: String
}
