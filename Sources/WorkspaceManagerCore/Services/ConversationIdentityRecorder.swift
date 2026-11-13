//
//  ConversationIdentityRecorder.swift
//  WorkspaceManagerCore
//
//  The running app's writer of Conversation records. Every hook payload names its
//  conversation, so each one is written as a sighting in its tile. That is how `/resume`,
//  `/clear`, or a start the SessionStart hook missed reach the record.
//

import Foundation

public actor ConversationIdentityRecorder {
    private let store: ConversationRecordStore
    private let socketLabel: String?
    private let clock: @Sendable () -> Date

    public init(
        store: ConversationRecordStore,
        socketLabel: String? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.socketLabel = socketLabel
        self.clock = clock
    }

    /// The fields of a Claude hook payload that say which conversation it came from.
    public struct HookIdentity: Decodable, Equatable, Sendable {
        public let sessionID: String
        public let cwd: String?
        public let transcriptPath: String?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case cwd
            case transcriptPath = "transcript_path"
        }

        public static func decode(from payload: Data) -> HookIdentity? {
            try? JSONDecoder().decode(HookIdentity.self, from: payload)
        }
    }

    /// Writes every payload's sighting. The file is the only place that knows whether this
    /// conversation is still the tile's newest, since the SessionStart observer and `ws launch`
    /// write it too, so no sighting is skipped on what this writer last saw. A dropped write
    /// is covered by the tile's next payload.
    public func observe(_ identity: HookIdentity, hostSessionID: UUID) {
        guard let conversationID = ConversationRecord.normalizedID(identity.sessionID) else { return }
        let observation = ConversationObservation(
            conversationID: conversationID,
            cwd: identity.cwd,
            transcriptPath: identity.transcriptPath,
            socketLabel: socketLabel,
            observedAt: clock(),
            observedBy: .app,
            lastSeenIn: .init(hostSessionID: hostSessionID.uuidString)
        )
        _ = try? store.record(observation)
    }
}
