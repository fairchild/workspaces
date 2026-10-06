//
//  DecisionBoardClient.swift
//  WorkspaceManagerCore
//
//  Reads open decisions from an agent decision board and writes an answer back
//  through the board's own answer route — the route that stamps `agreed` and
//  appends the record line. Answering any other way would break the only
//  feedback loop the agent has, so this speaks the board page's wire format
//  exactly and computes nothing the server computes.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "DecisionBoard")

public enum DecisionBoardConstants {
    /// The board binds loopback. The override exists so a demonstrated run can
    /// point at a scratch board instead of the live instrument.
    public static let boardURLEnvironmentKey = "WORKSPACES_DECISION_BOARD_URL"

    public static let boardBaseURL: URL = {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment[boardURLEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let url = URL(string: raw)
        {
            return url
        }
        // swift-format-ignore: NeverForceUnwrap
        // A string literal that is a valid URL; a nil here is a programmer error
        // caught the first time this type is constructed, not a runtime condition.
        return URL(string: "http://127.0.0.1:8791")!
    }()

    /// The board's undo window. An answer is final once it passes, and the
    /// agent reads only answers whose `settleAt` is already behind it.
    public static let undoWindow: TimeInterval = 8

    /// Where this launch is allowed to answer decisions, or nothing.
    ///
    /// The default is the live board, which is right for the shipped surface and
    /// wrong for every isolated run — and an isolated run that silently falls
    /// back to it writes a real answer into the real store, stamps the alignment
    /// record with a verdict nobody gave, and looks like it worked. There
    /// is no undo for that beyond editing the card by hand.
    ///
    /// `WORKSPACES_SYNTHETIC_ROOT` already means "this run must not touch the
    /// owner's real roots". The board is one, so under a synthetic root the
    /// board URL must be named outright or the surface does not run at all.
    public static func resolvedBoardURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let explicit = environment[boardURLEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty, let url = URL(string: explicit) {
            return url
        }
        let isolated = (environment[LaunchPreferencesEnvironment.syntheticRootKey] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isolated.isEmpty else { return nil }
        return boardBaseURL
    }
}

public enum DecisionBoardError: Error, LocalizedError {
    case requestFailed(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let code): "Board request failed with status \(code)"
        case .invalidResponse: "Invalid response from the decision board"
        }
    }
}

public actor DecisionBoardClient {
    private let baseURL: URL
    private let session: URLSession

    public init(
        baseURL: URL = DecisionBoardConstants.boardBaseURL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Every decision the board holds, answered ones included — the surface needs
    /// to see a card leave the open set to know it should withdraw. A card with
    /// no title or no options is dropped, because there is nothing a notification
    /// could say about it that anyone could act on.
    public func decisions() async throws -> [DecisionCard] {
        let request = URLRequest(url: baseURL.appendingPathComponent("api/collection/decisions"))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DecisionBoardError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw DecisionBoardError.requestFailed(http.statusCode)
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let docs = root["docs"] as? [[String: Any]]
        else { throw DecisionBoardError.invalidResponse }

        return docs.compactMap(Self.card(fromDocument:))
    }

    /// Records an answer the way a click on the board records it: the page's own
    /// fields, plus the channel. The server derives `agreed` from this write, so
    /// nothing here may derive it too.
    public func answer(id: String, option: String, at: Date) async throws {
        let answeredAt = BoardTimestamp.write(at)
        let settleAt = BoardTimestamp.write(at.addingTimeInterval(DecisionBoardConstants.undoWindow))
        try await patchDecision(
            id: id,
            body: [
                "status": "answered",
                "answer": option,
                "note": "",
                "answeredAt": answeredAt,
                "settleAt": settleAt,
                "answeredVia": "tap",
            ]
        )
    }

    /// The page's exact revert. The server clears `agreed` and `answeredVia` when
    /// a card stops being answered, so neither is named here.
    public func undo(id: String) async throws {
        try await patchDecision(
            id: id,
            body: ["status": "open", "answer": "", "note": "", "answeredAt": "", "settleAt": ""]
        )
    }

    /// One interruption, recorded. `queued` is how many other decisions were
    /// waiting and deliberately not sent, which is the one-at-a-time rule making
    /// itself measurable. A measurement is never worth an exception, so this
    /// swallows its failures after logging them.
    public func recordNotifySent(id: String, queued: Int, visit: String) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/metric"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "event": "notify-sent", "id": id, "channel": "macos-notification",
            "queued": queued, "visit": visit,
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.warning("notify-sent rejected with status \(http.statusCode, privacy: .public)")
            }
        } catch {
            log.warning("notify-sent not recorded: \(String(describing: error), privacy: .public)")
        }
    }

    private func patchDecision(id: String, body: [String: String]) async throws {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/doc/decisions").appendingPathComponent(id)
        )
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DecisionBoardError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw DecisionBoardError.requestFailed(http.statusCode)
        }
    }

    /// The board wraps each document as `{id, data}`. A card is kept only when it
    /// is still open and there is something to ask.
    private static func card(fromDocument document: [String: Any]) -> DecisionCard? {
        guard
            let id = document["id"] as? String,
            let data = document["data"] as? [String: Any]
        else { return nil }

        let status = (data["status"] as? String ?? "open").trimmingCharacters(in: .whitespacesAndNewlines)

        let title = (data["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let options = (data["options"] as? [String] ?? [])
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !options.isEmpty else { return nil }

        return DecisionCard(
            id: id,
            title: title,
            detail: data["detail"] as? String ?? "",
            options: options,
            recommended: (data["recommended"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            topic: (data["topic"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            order: data["order"] as? Int ?? 50,
            askedAt: (data["askedAt"] as? String).flatMap(BoardTimestamp.read(_:)),
            status: status
        )
    }

}
