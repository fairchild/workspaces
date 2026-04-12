import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("EventStreamService")
struct EventStreamServiceTests {

    @Test("initial state is disconnected")
    func initialState() async {
        let service = EventStreamService(
            baseURL: URL(string: "https://test.example.com")!
        )
        let connected = await service.isConnected
        let reason = await service.lastDisconnectReason
        #expect(connected == false)
        #expect(reason == .none)
    }

    @Test("disconnect is idempotent")
    func disconnectIdempotent() async {
        let service = EventStreamService(
            baseURL: URL(string: "https://test.example.com")!
        )
        await service.disconnect()
        await service.disconnect()
        let connected = await service.isConnected
        #expect(connected == false)
    }

    @Test("events stream is created lazily")
    func eventsStreamCreated() async {
        let service = EventStreamService(
            baseURL: URL(string: "https://test.example.com")!
        )
        let stream = await service.events
        // Stream should be non-nil (it's always returned)
        // Verify we can iterate (will be empty since not connected)
        let task = Task<WebhookEvent?, Never> {
            for await event in stream {
                return event
            }
            return nil
        }
        // Finish the stream by disconnecting
        await service.disconnect()
        let result = await task.value
        #expect(result == nil)
    }

    @Test("WebhookEvent decodes wire format correctly")
    func webhookEventDecoding() throws {
        let json = """
            {
                "id": "evt_123",
                "type": "push",
                "action": "created",
                "summary": "Push to main",
                "repo": "octocat/hello-world",
                "timestamp": "2026-03-09T00:00:00Z"
            }
            """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(WebhookEvent.self, from: data)

        #expect(event.id == "evt_123")
        #expect(event.type == "push")
        #expect(event.action == "created")
        #expect(event.summary == "Push to main")
        #expect(event.repo == "octocat/hello-world")
    }
}
