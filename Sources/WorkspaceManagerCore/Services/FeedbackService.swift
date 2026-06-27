import Foundation
import os.log

private let feedbackLog = Logger(subsystem: "com.cloudcompute.workspaces", category: "Feedback")

public enum FeedbackKind: String, Codable, CaseIterable, Sendable {
    case bug
    case idea
    case feedback
}

public struct FeedbackAttachment: Sendable, Equatable {
    public let filename: String
    public let contentType: String
    public let data: Data

    public init(filename: String, contentType: String, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

public struct FeedbackSubmission: Sendable, Equatable {
    public let kind: FeedbackKind
    public let message: String
    public let contactEmail: String?
    public let appVersion: String
    public let osVersion: String
    public let client: String
    public let honeypot: String?
    public let screenshot: FeedbackAttachment?
    public let diagnostics: FeedbackAttachment?

    public init(
        kind: FeedbackKind,
        message: String,
        contactEmail: String?,
        appVersion: String,
        osVersion: String,
        client: String = "macos",
        honeypot: String? = nil,
        screenshot: FeedbackAttachment? = nil,
        diagnostics: FeedbackAttachment? = nil
    ) {
        self.kind = kind
        self.message = message
        self.contactEmail = contactEmail
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.client = client
        self.honeypot = honeypot
        self.screenshot = screenshot
        self.diagnostics = diagnostics
    }
}

public struct FeedbackSubmissionReceipt: Codable, Sendable, Equatable {
    public let id: String
    public let status: String
}

public enum FeedbackServiceError: Error, LocalizedError, Equatable {
    case emptyMessage
    case messageTooLong(Int)
    case requestFailed(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .emptyMessage:
            "Feedback message cannot be empty."
        case .messageTooLong(let limit):
            "Feedback message must be \(limit) characters or fewer."
        case .requestFailed(let code):
            "Feedback submission failed with status \(code)."
        case .invalidResponse:
            "The feedback service returned an invalid response."
        }
    }
}

public protocol FeedbackServiceProtocol: Sendable {
    func submit(_ submission: FeedbackSubmission, jwt: String?) async throws -> FeedbackSubmissionReceipt
}

public actor FeedbackService: FeedbackServiceProtocol {
    public static let shared = FeedbackService()
    public static let maxMessageLength = 10_000

    private let baseURL: URL
    private let session: URLSession

    public init(
        baseURL: URL = NotificationConstants.feedbackBaseURL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public func submit(_ submission: FeedbackSubmission, jwt: String?) async throws -> FeedbackSubmissionReceipt {
        let trimmedMessage = submission.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { throw FeedbackServiceError.emptyMessage }
        guard trimmedMessage.count <= Self.maxMessageLength else {
            throw FeedbackServiceError.messageTooLong(Self.maxMessageLength)
        }

        do {
            return try await submitValidated(submission, jwt: jwt)
        } catch FeedbackServiceError.requestFailed(401) where jwt?.isEmpty == false {
            feedbackLog.notice("Feedback JWT was rejected; retrying anonymously")
            return try await submitValidated(submission, jwt: nil)
        }
    }

    private func submitValidated(
        _ submission: FeedbackSubmission,
        jwt: String?
    ) async throws -> FeedbackSubmissionReceipt {
        var request = URLRequest(url: baseURL.appendingPathComponent("feedback"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jwt, !jwt.isEmpty {
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }

        let boundary = "workspaces-feedback-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.multipartBody(for: submission, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackServiceError.invalidResponse
        }

        guard httpResponse.statusCode == 201 || httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            feedbackLog.error("Feedback submission failed: \(httpResponse.statusCode) - \(body)")
            throw FeedbackServiceError.requestFailed(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(FeedbackSubmissionReceipt.self, from: data)
        } catch {
            throw FeedbackServiceError.invalidResponse
        }
    }

    static func multipartBody(for submission: FeedbackSubmission, boundary: String) throws -> Data {
        var body = Data()
        let payload = FeedbackPayload(submission: submission)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(payload)

        body.appendPart(
            name: "payload",
            filename: nil,
            contentType: "application/json",
            data: payloadData,
            boundary: boundary
        )

        if let screenshot = submission.screenshot {
            body.appendPart(
                name: "screenshot",
                filename: screenshot.filename,
                contentType: screenshot.contentType,
                data: screenshot.data,
                boundary: boundary
            )
        }

        if let diagnostics = submission.diagnostics {
            body.appendPart(
                name: "diagnostics",
                filename: diagnostics.filename,
                contentType: diagnostics.contentType,
                data: diagnostics.data,
                boundary: boundary
            )
        }

        body.appendString("--\(boundary)--\r\n")
        return body
    }
}

private struct FeedbackPayload: Codable {
    let kind: FeedbackKind
    let message: String
    let contactEmail: String?
    let appVersion: String
    let osVersion: String
    let client: String
    let honeypot: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case message
        case contactEmail = "contact_email"
        case appVersion = "app_version"
        case osVersion = "os_version"
        case client
        case honeypot
    }

    init(submission: FeedbackSubmission) {
        kind = submission.kind
        message = submission.message
        contactEmail = submission.contactEmail
        appVersion = submission.appVersion
        osVersion = submission.osVersion
        client = submission.client
        honeypot = submission.honeypot
    }
}

extension Data {
    fileprivate mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }

    fileprivate mutating func appendPart(
        name: String,
        filename: String?,
        contentType: String,
        data: Data,
        boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        if let filename {
            appendString(
                "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
            )
        } else {
            appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n")
        }
        appendString("Content-Type: \(contentType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }
}
