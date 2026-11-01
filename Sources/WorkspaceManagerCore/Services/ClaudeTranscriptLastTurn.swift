//
//  ClaudeTranscriptLastTurn.swift
//  WorkspaceManagerCore
//
//  Reads what a Claude conversation actually ran on from its transcript. Each assistant
//  entry records the model that answered and the effort the request carried, which makes
//  the transcript the record of what was sent, where a process's arguments only say what
//  was asked for. Read from the end of the file, since a transcript can run to megabytes.
//

import Foundation

public struct ClaudeTranscriptTurn: Sendable, Equatable {
    public let model: String?
    public let effort: String?
    /// When the turn was written. A turn speaks only for a process running at that moment:
    /// a resumed conversation still shows the turns of the process before it.
    public let timestamp: Date?

    public init(model: String?, effort: String?, timestamp: Date? = nil) {
        self.model = model
        self.effort = effort
        self.timestamp = timestamp
    }

    /// The last turn the main conversation took, or `nil` before there is one. A partial
    /// first line in the window fails to decode and is passed over, as is anything that
    /// is not a main-thread assistant turn.
    public static func last(in transcript: URL, tailBytes: Int = 2 << 20) -> ClaudeTranscriptTurn? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
            let data = try? handle.readToEnd()
        else { return nil }

        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line)),
                entry.type == "assistant", entry.isSidechain != true,
                let model = entry.message?.model, model != syntheticModel
            else { continue }
            return ClaudeTranscriptTurn(
                model: model,
                effort: entry.effort,
                timestamp: entry.timestamp.flatMap(parseTimestamp)
            )
        }
        return nil
    }

    /// Whether `model`, as a caller spelled it, names the model that answered: the full
    /// id, or an alias such as `opus`. A bracketed suffix such as `[1m]` selects a variant
    /// of a model rather than a different one, so it is not compared.
    public static func model(_ observed: String, satisfies requested: String) -> Bool {
        let base = requested.split(separator: "[").first.map(String.init) ?? requested
        return !base.isEmpty && observed.lowercased().contains(base.lowercased())
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        try? Date(
            text,
            strategy: .iso8601.year().month().day().timeZone(separator: .omitted)
                .time(includingFractionalSeconds: true)
        )
    }

    /// What claude writes for a message it generated locally, such as an API error.
    private static let syntheticModel = "<synthetic>"

    private struct Entry: Decodable {
        struct Message: Decodable { let model: String? }
        let type: String?
        let isSidechain: Bool?
        let effort: String?
        let timestamp: String?
        let message: Message?
    }
}
