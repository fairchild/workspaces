import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("FeedbackService")
struct FeedbackServiceTests {
    @Test("submit sends multipart payload and optional JWT")
    func submitMultipart() async throws {
        final class RequestBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: URLRequest?

            var request: URLRequest? {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }

            func save(_ request: URLRequest) {
                lock.lock()
                stored = request
                lock.unlock()
            }
        }

        let requestBox = RequestBox()
        let session = MockURLProtocol.session(requestHandlers: [
            "/feedback": { request in
                requestBox.save(request)
                let data = Data(#"{"id":"fb_123","status":"new"}"#.utf8)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (data, response)
            }
        ])
        let service = FeedbackService(
            baseURL: URL(string: "https://mock.test")!,
            session: session
        )

        let receipt = try await service.submit(
            FeedbackSubmission(
                kind: .bug,
                message: "The terminal vanished.",
                contactEmail: "user@example.com",
                appVersion: "1.2.3",
                osVersion: "14.5",
                screenshot: FeedbackAttachment(
                    filename: "screenshot.png",
                    contentType: "image/png",
                    data: Data([1, 2, 3])
                )
            ),
            jwt: "jwt-token"
        )

        #expect(receipt == FeedbackSubmissionReceipt(id: "fb_123", status: "new"))
        let request = try #require(requestBox.request)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
        let bodyData = try #require(request.httpBody ?? Data(reading: request.httpBodyStream))
        let body = String(data: bodyData, encoding: .utf8)
        #expect(body?.contains("\"message\":\"The terminal vanished.\"") == true)
        #expect(body?.contains("name=\"screenshot\"; filename=\"screenshot.png\"") == true)
    }

    @Test("submit retries anonymously when optional JWT is rejected")
    func submitRetriesAnonymouslyAfterRejectedJWT() async throws {
        final class RequestRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var authorizationHeaders: [String?] = []

            func append(_ value: String?) {
                lock.lock()
                authorizationHeaders.append(value)
                lock.unlock()
            }

            var values: [String?] {
                lock.lock()
                defer { lock.unlock() }
                return authorizationHeaders
            }
        }

        let recorder = RequestRecorder()
        let session = MockURLProtocol.session(requestHandlers: [
            "/feedback": { request in
                let authorization = request.value(forHTTPHeaderField: "Authorization")
                recorder.append(authorization)

                if authorization != nil {
                    let data = Data(#"{"error":"invalid jwt"}"#.utf8)
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 401,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    return (data, response)
                }

                let data = Data(#"{"id":"fb_retry","status":"new"}"#.utf8)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (data, response)
            }
        ])
        let service = FeedbackService(
            baseURL: URL(string: "https://mock.test")!,
            session: session
        )

        let receipt = try await service.submit(
            FeedbackSubmission(
                kind: .feedback,
                message: "Please keep accepting feedback.",
                contactEmail: nil,
                appVersion: "1.2.3",
                osVersion: "14.5"
            ),
            jwt: "stale-jwt"
        )

        #expect(receipt == FeedbackSubmissionReceipt(id: "fb_retry", status: "new"))
        #expect(recorder.values == ["Bearer stale-jwt", nil])
    }

    @Test("submit rejects empty message locally")
    func submitRejectsEmptyMessage() async {
        let service = FeedbackService(baseURL: URL(string: "https://mock.test")!)

        do {
            _ = try await service.submit(
                FeedbackSubmission(
                    kind: .feedback,
                    message: " ",
                    contactEmail: nil,
                    appVersion: "dev",
                    osVersion: "14.5"
                ),
                jwt: nil
            )
            Issue.record("Expected emptyMessage")
        } catch let error as FeedbackServiceError {
            #expect(error == .emptyMessage)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

extension Data {
    fileprivate init?(reading stream: InputStream?) {
        guard let stream else { return nil }
        self.init()
        stream.open()
        defer { stream.close() }

        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                append(buffer, count: read)
            } else if read < 0 {
                return nil
            } else {
                break
            }
        }
    }
}
