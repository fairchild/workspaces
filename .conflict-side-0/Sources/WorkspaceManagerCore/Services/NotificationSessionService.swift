import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "NotificationSession")

public struct NotificationSession: Codable, Sendable {
    public let jwt: String
    public let login: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case jwt
        case login
        case expiresAt = "expires_at"
    }
}

public enum NotificationSessionError: Error, LocalizedError {
    case requestFailed(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let code): "Session request failed with status \(code)"
        case .invalidResponse: "Invalid response from server"
        }
    }
}

public actor NotificationSessionService: NotificationSessionServiceProtocol {
    private let baseURL: URL
    private let session: URLSession

    public init(
        baseURL: URL = NotificationConstants.baseURL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public func createSession(githubToken: String) async throws -> NotificationSession {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(["github_token": githubToken])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotificationSessionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            log.error("Session creation failed: \(httpResponse.statusCode) — \(body)")
            throw NotificationSessionError.requestFailed(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NotificationSession.self, from: data)
    }
}
