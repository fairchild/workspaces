import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("NotificationSessionService")
struct NotificationSessionServiceTests {

    @Test("createSession returns JWT on valid GitHub token")
    func createSessionSuccess() async throws {
        let session = MockURLProtocol.session(handlers: [
            "/auth/session": (
                json: [
                    "jwt": "eyJ.test.jwt",
                    "login": "octocat",
                    "expires_at": "2026-03-09T00:00:00Z",
                ],
                statusCode: 200
            )
        ])

        let service = NotificationSessionService(
            baseURL: URL(string: "https://mock.test")!,
            session: session
        )

        let result = try await service.createSession(githubToken: "ghu_valid")

        #expect(result.jwt == "eyJ.test.jwt")
        #expect(result.login == "octocat")
    }

    @Test("createSession throws on 401")
    func createSessionUnauthorized() async {
        let session = MockURLProtocol.session(handlers: [
            "/auth/session": (
                json: ["error": "Invalid GitHub token"],
                statusCode: 401
            )
        ])

        let service = NotificationSessionService(
            baseURL: URL(string: "https://mock.test")!,
            session: session
        )

        do {
            _ = try await service.createSession(githubToken: "bad-token")
            Issue.record("Expected requestFailed error")
        } catch let error as NotificationSessionError {
            guard case .requestFailed(let code) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(code == 401)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
