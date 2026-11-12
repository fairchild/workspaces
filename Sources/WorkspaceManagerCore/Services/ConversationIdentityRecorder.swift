//
//  ConversationIdentityRecorder.swift
//  WorkspaceManagerCore
//
//  The running app's writer of Conversation records. Every hook payload names its
//  conversation, so when the id a tile reports changes — `/resume`, `/clear`, or a
//  start the SessionStart hook missed — the record is rewritten for the new one.
//

import Foundation

public actor ConversationIdentityRecorder {
    private let store: ConversationRecordStore
    private let socketLabel: String?
    private let clock: @Sendable () -> Date
    private var current: [UUID: String] = [:]

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

    /// Writes the record when `identity` names a conversation other than the one this tile
    /// last reported. The first payload a tile sends in a run counts as a change, so each
    /// run confirms where every conversation is. A dropped write is tried again on the next
    /// payload.
    public func observe(_ identity: HookIdentity, hostSessionID: UUID) {
        guard let conversationID = ConversationRecord.normalizedID(identity.sessionID),
            current[hostSessionID] != conversationID
        else { return }
        let observation = ConversationObservation(
            conversationID: conversationID,
            cwd: identity.cwd,
            transcriptPath: identity.transcriptPath,
            socketLabel: socketLabel,
            observedAt: clock(),
            observedBy: .app,
            lastSeenIn: .init(hostSessionID: hostSessionID.uuidString)
        )
        guard (try? store.record(observation)) == .written else { return }
        current[hostSessionID] = conversationID
    }
}
