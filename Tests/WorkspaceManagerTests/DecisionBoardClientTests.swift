// swift-format-ignore-file: NeverForceUnwrap, NeverUseForceTry
// Test fixture; force-unwrap/force-try failures here are loud test crashes, not user-facing risk.
import Foundation
import Testing

@testable import WorkspaceManagerCore

/// The point of this suite is the wire format. A tapped answer has to be
/// indistinguishable from a board click everywhere downstream, because the board
/// derives `agreed` from the write and that record is the only measure of how
/// well the agent predicts the answer.
@Suite("DecisionBoardClient")
struct DecisionBoardClientTests {
    private static let base = URL(string: "http://127.0.0.1:8791")!  // swift-format-ignore: NeverForceUnwrap

    /// URLProtocol hands the body back on the stream, not on `httpBody`.
    private static func body(of request: URLRequest) -> [String: Any] {
        let data: Data
        if let direct = request.httpBody {
            data = direct
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            let size = 4_096
            var buffer = [UInt8](repeating: 0, count: size)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: size)
                if read <= 0 { break }
                collected.append(contentsOf: buffer[0..<read])
            }
            data = collected
        } else {
            return [:]
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func ok(_ request: URLRequest, json: [String: Any] = ["ok": true]) -> (Data, HTTPURLResponse) {
        // swift-format-ignore: NeverUseForceTry, NeverForceUnwrap
        // Test fixture: a malformed literal here is a loud test crash, not a user-facing risk.
        let data = try! JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    @Test("An answer writes the five fields a board click writes, plus the channel")
    func answerWireFormat() async throws {
        let captured = Capture()
        let session = MockURLProtocol.session(requestHandlers: [
            "/api/doc/decisions/demo-card": { request in
                captured.store(Self.body(of: request), method: request.httpMethod ?? "")
                return Self.ok(request)
            }
        ])
        let client = DecisionBoardClient(baseURL: Self.base, session: session)
        let at = Date(timeIntervalSince1970: 1_789_000_000)
        try await client.answer(id: "demo-card", option: "ship it", at: at)

        let body = captured.body
        #expect(captured.method == "PATCH")
        #expect(
            Set(body.keys) == ["status", "answer", "note", "answeredAt", "settleAt", "answeredVia"],
            "the board page sends exactly these fields; an extra one is a second source of truth"
        )
        #expect(body["status"] as? String == "answered")
        #expect(body["answer"] as? String == "ship it")
        #expect(body["note"] as? String == "")
        #expect(body["answeredVia"] as? String == "tap")
        #expect(body["agreed"] == nil, "agreed is the server's verdict, never ours")
    }

    @Test("The answer settles eight seconds later, which is the board's undo window")
    func answerSettleWindow() async throws {
        let captured = Capture()
        let session = MockURLProtocol.session(requestHandlers: [
            "/api/doc/decisions/demo-card": { request in
                captured.store(Self.body(of: request), method: request.httpMethod ?? "")
                return Self.ok(request)
            }
        ])
        let client = DecisionBoardClient(baseURL: Self.base, session: session)
        try await client.answer(id: "demo-card", option: "hold", at: Date(timeIntervalSince1970: 1_789_000_000))

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let answered = try #require((captured.body["answeredAt"] as? String).flatMap(parser.date(from:)))
        let settled = try #require((captured.body["settleAt"] as? String).flatMap(parser.date(from:)))
        #expect(settled.timeIntervalSince(answered) == 8)
    }

    @Test("Undo sends the page's exact revert and names no channel")
    func undoWireFormat() async throws {
        let captured = Capture()
        let session = MockURLProtocol.session(requestHandlers: [
            "/api/doc/decisions/demo-card": { request in
                captured.store(Self.body(of: request), method: request.httpMethod ?? "")
                return Self.ok(request)
            }
        ])
        let client = DecisionBoardClient(baseURL: Self.base, session: session)
        try await client.undo(id: "demo-card")

        #expect(Set(captured.body.keys) == ["status", "answer", "note", "answeredAt", "settleAt"])
        #expect(captured.body["status"] as? String == "open")
        #expect(captured.body["answer"] as? String == "")
    }

    @Test("Open decisions are read; answered, untitled and optionless ones are not")
    func openDecisionsFilters() async throws {
        let docs: [[String: Any]] = [
            [
                "id": "open-one",
                "data": [
                    "title": "Ship it?", "options": ["yes", "no"], "order": 10,
                    "status": "open", "askedAt": "2026-09-13T19:52:55Z",
                ],
            ],
            ["id": "answered", "data": ["title": "Old", "options": ["yes"], "status": "answered"]],
            ["id": "untitled", "data": ["title": "  ", "options": ["yes"], "status": "open"]],
            ["id": "optionless", "data": ["title": "No options", "options": [], "status": "open"]],
        ]
        let session = MockURLProtocol.session(handlers: [
            "/api/collection/decisions": (json: ["collection": "decisions", "docs": docs], statusCode: 200)
        ])
        let client = DecisionBoardClient(baseURL: Self.base, session: session)
        let cards = try await client.openDecisions()

        #expect(cards.map(\.id) == ["open-one"])
        #expect(cards.first?.order == 10)
        #expect(cards.first?.askedAt != nil)
    }

    @Test("A card with no order takes the card writer's default")
    func orderDefaults() async throws {
        let docs: [[String: Any]] = [
            ["id": "no-order", "data": ["title": "Ship it?", "options": ["yes", "no"], "status": "open"]]
        ]
        let session = MockURLProtocol.session(handlers: [
            "/api/collection/decisions": (json: ["collection": "decisions", "docs": docs], statusCode: 200)
        ])
        let client = DecisionBoardClient(baseURL: Self.base, session: session)
        #expect(try await client.openDecisions().first?.order == 50)
    }

    @Test("A refused read is an error, not an empty queue")
    func refusedReadThrows() async {
        let session = MockURLProtocol.session(handlers: [:])
        let client = DecisionBoardClient(baseURL: Self.base, session: session)
        await #expect(throws: DecisionBoardError.self) { try await client.openDecisions() }
    }

    @Test("A rejected measurement never reaches the caller")
    func metricFailureIsSwallowed() async {
        let session = MockURLProtocol.session(handlers: [:])
        let client = DecisionBoardClient(baseURL: Self.base, session: session)
        await client.recordNotifySent(id: "demo-card", queued: 3, visit: "test-visit")
    }

    @Test("The interruption is recorded with the card, the channel and the queue behind it")
    func metricWireFormat() async {
        let captured = Capture()
        let session = MockURLProtocol.session(requestHandlers: [
            "/api/metric": { request in
                captured.store(Self.body(of: request), method: request.httpMethod ?? "")
                return Self.ok(request, json: [:])
            }
        ])
        let client = DecisionBoardClient(baseURL: Self.base, session: session)
        await client.recordNotifySent(id: "demo-card", queued: 3, visit: "launch-visit")

        #expect(captured.method == "POST")
        #expect(captured.body["event"] as? String == "notify-sent")
        #expect(captured.body["id"] as? String == "demo-card")
        #expect(captured.body["channel"] as? String == "macos-notification")
        #expect(captured.body["queued"] as? Int == 3)
        #expect(captured.body["visit"] as? String == "launch-visit")
    }
}

/// The mock handler runs on URLSession's queue, so what it saw has to cross back
/// under a lock rather than by capturing a `var`.
private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Any] = [:]
    private var storedMethod = ""

    func store(_ body: [String: Any], method: String) {
        lock.lock()
        defer { lock.unlock() }
        stored = body
        storedMethod = method
    }

    var body: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var method: String {
        lock.lock()
        defer { lock.unlock() }
        return storedMethod
    }
}
