import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("WebhookEvent")
struct WebhookEventTests {

    @Test("Codable roundtrip preserves all fields")
    func codableRoundtrip() throws {
        let event = WebhookEvent(
            id: "evt-123",
            type: "pull_request",
            action: "opened",
            summary: "PR #42 opened by octocat",
            repo: "octocat/hello-world",
            timestamp: Date(timeIntervalSince1970: 1_710_000_000)
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(WebhookEvent.self, from: data)

        #expect(decoded.id == event.id)
        #expect(decoded.type == event.type)
        #expect(decoded.action == event.action)
        #expect(decoded.summary == event.summary)
        #expect(decoded.repo == event.repo)
        #expect(decoded.timestamp == event.timestamp)
    }

    @Test("Wire format from server decodes correctly")
    func wireFormatDecode() throws {
        let json = """
            {
                "id": "abc-def",
                "type": "discussion",
                "action": "created",
                "summary": "Discussion #7 created by user",
                "repo": "my-org/my-repo",
                "timestamp": 1710000000000
            }
            """

        struct WireEvent: Codable {
            let id: String
            let type: String
            let action: String
            let summary: String
            let repo: String
            let timestamp: Int64
        }

        let wire = try JSONDecoder().decode(WireEvent.self, from: Data(json.utf8))
        let event = WebhookEvent(
            id: wire.id,
            type: wire.type,
            action: wire.action,
            summary: wire.summary,
            repo: wire.repo,
            timestamp: Date(timeIntervalSince1970: TimeInterval(wire.timestamp) / 1000)
        )

        #expect(event.id == "abc-def")
        #expect(event.type == "discussion")
        #expect(event.repo == "my-org/my-repo")
        #expect(event.timestamp == Date(timeIntervalSince1970: 1_710_000_000))
    }

    @Test("Catch-up batch format decodes correctly")
    func catchupBatchDecode() throws {
        let json = """
            {
                "type": "catchup",
                "events": [
                    {
                        "id": "evt-1",
                        "type": "pull_request",
                        "action": "opened",
                        "summary": "PR #1 opened",
                        "repo": "my-org/repo-a",
                        "timestamp": 1710000000000
                    },
                    {
                        "id": "evt-2",
                        "type": "check_run",
                        "action": "completed",
                        "summary": "Check \\"ci\\" completed",
                        "repo": "my-org/repo-b",
                        "timestamp": 1710000001000
                    }
                ]
            }
            """

        struct WireEvent: Codable {
            let id: String
            let type: String
            let action: String
            let summary: String
            let repo: String
            let timestamp: Int64
        }

        struct WireMessage: Codable {
            let type: String
            let events: [WireEvent]?
        }

        let msg = try JSONDecoder().decode(WireMessage.self, from: Data(json.utf8))

        #expect(msg.type == "catchup")
        #expect(msg.events?.count == 2)
        #expect(msg.events?[0].id == "evt-1")
        #expect(msg.events?[0].repo == "my-org/repo-a")
        #expect(msg.events?[0].timestamp == 1_710_000_000_000)
        #expect(msg.events?[1].id == "evt-2")
        #expect(msg.events?[1].repo == "my-org/repo-b")
    }
}
