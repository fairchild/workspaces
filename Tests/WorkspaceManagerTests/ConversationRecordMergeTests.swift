//
//  ConversationRecordMergeTests.swift
//  WorkspaceManagerTests
//
//  The merge's property: a set of observations makes the same record whatever order it
//  arrives in, and a repeat changes nothing. These run every order of each named sequence,
//  on a fresh record or one written before sightings, and pin the place each one must end
//  at, then check the property over generated sets.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Conversation record merge")
struct ConversationRecordMergeTests {
    private static let id = "fa08c461-2979-41db-85fb-b5c90c0d2d8b"
    private static let h = "2D4D6044-1E11-49C9-9CB0-A1D7B9F44E31"
    private static let k = "7A0C2B3E-5F44-4E1A-9C0B-2B7E6E1F9D10"
    private static let t1 = ConversationRecord.TmuxSession(serverPID: 4242, sessionID: "$1", name: "wm-one")
    private static let t2 = ConversationRecord.TmuxSession(serverPID: 4242, sessionID: "$2", name: "wm-two")
    private static let t1Bare = ConversationRecord.TmuxSession(serverPID: 4242, sessionID: "$1")
    private static let t1Described = ConversationRecord.TmuxSession(
        serverPID: 4242, sessionID: "$1", createdAt: Date(timeIntervalSince1970: 1_799_999_000), name: "wm-one")

    private static func seen(
        _ holder: String?,
        _ tmux: ConversationRecord.TmuxSession? = nil,
        at seconds: TimeInterval,
        outside: Bool = false,
        by observer: ConversationObserver = .hook,
        cwd: String? = nil
    ) -> ConversationObservation {
        ConversationObservation(
            conversationID: id,
            host: "test-host",
            cwd: cwd,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
            observedBy: observer,
            lastSeenIn: .init(hostSessionID: holder, tmux: tmux, outsideTmux: outside)
        )
    }

    private static func merged(
        _ observations: [ConversationObservation],
        onto base: [String: Any]? = nil
    ) -> [String: Any] {
        observations.reduce(into: base ?? [:]) { object, observation in
            object = ConversationRecordJSON.merge(observation, into: object)
        }
    }

    /// A record as a build before sightings wrote it: one place under `lastSeenIn`, with no
    /// per-field or per-sighting times.
    private static func legacy(_ observation: ConversationObservation) -> [String: Any] {
        var object = ConversationRecordJSON.merge(observation, into: nil)
        for key in [
            ConversationRecordJSON.fieldObservedAtKey, ConversationRecordJSON.sightingsKey,
            ConversationRecordJSON.sightingsAfterKey,
        ] {
            object[key] = nil
        }
        return object
    }

    private static func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }

    /// Every order of `observations`, each also with its first observation delivered twice,
    /// lands on one object; returns that object's place.
    private static func placeInEveryOrder(
        _ observations: [ConversationObservation],
        onto base: [String: Any]? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> ConversationRecord.LastSeenIn? {
        let orders = permutations(observations).flatMap { [$0, $0 + [$0[0]]] }
        let reference = merged(orders[0], onto: base) as NSDictionary
        for order in orders.dropFirst() {
            #expect(merged(order, onto: base) as NSDictionary == reference, sourceLocation: sourceLocation)
        }
        return (reference["lastSeenIn"] as? [String: Any]).map(ConversationRecordJSON.lastSeenIn(from:))
    }

    struct Case: Sendable, CustomStringConvertible {
        let description: String
        var legacy: ConversationObservation? = nil
        let observations: [ConversationObservation]
        let expected: ConversationRecord.LastSeenIn
    }

    static let cases: [Case] = [
        Case(
            description: "an app sighting without tmux, then two hook sightings delivered late",
            observations: [seen(h, at: 30, by: .app), seen(h, t1, at: 10), seen(h, t2, at: 20)],
            expected: .init(hostSessionID: h, tmux: t2)
        ),
        Case(
            description: "H, then K, then H again without tmux, with H's first sighting repeated late",
            observations: [seen(h, t1, at: 10), seen(k, t2, at: 20), seen(h, at: 30, by: .app), seen(h, t1, at: 10)],
            expected: .init(hostSessionID: h)
        ),
        Case(
            description: "H to K to H in one tmux session",
            observations: [seen(h, t1, at: 10), seen(k, t1, at: 20), seen(h, t1, at: 30)],
            expected: .init(hostSessionID: h, tmux: t1)
        ),
        Case(
            description: "a tile's sighting, then a newer one from its session with no tile known",
            observations: [seen(h, t1, at: 10), seen(nil, t1, at: 20, by: .wsLaunch)],
            expected: .init(hostSessionID: h, tmux: t1)
        ),
        Case(
            description: "a launch's session, then a newer sighting of a tile with no tmux known",
            observations: [seen(nil, t1, at: 10, by: .wsLaunch), seen(h, at: 20, by: .app)],
            expected: .init(hostSessionID: h, tmux: t1)
        ),
        Case(
            description: "a launch's session, then a newer hook outside tmux",
            observations: [seen(nil, t1, at: 10, by: .wsLaunch), seen(h, at: 20, outside: true)],
            expected: .init(hostSessionID: h, outsideTmux: true)
        ),
        Case(
            description: "a newer launch in another session with no tile known",
            observations: [seen(h, t1, at: 10), seen(nil, t2, at: 20, by: .wsLaunch)],
            expected: .init(hostSessionID: nil, tmux: t2)
        ),
        Case(
            description: "a described session, a move to another tile and session, a return without description",
            observations: [seen(h, t1Described, at: 10), seen(k, t2, at: 20), seen(h, t1Bare, at: 30)],
            expected: .init(hostSessionID: h, tmux: t1Bare)
        ),
        Case(
            description: "a described session, a move to another session only, a return without description",
            observations: [seen(h, t1Described, at: 10), seen(h, t2, at: 20), seen(h, t1Bare, at: 30)],
            expected: .init(hostSessionID: h, tmux: t1Bare)
        ),
        Case(
            description: "a described session, a move to another tile only, a return without description",
            observations: [seen(h, t1Described, at: 10), seen(k, t1Bare, at: 20), seen(h, t1Bare, at: 30)],
            expected: .init(hostSessionID: h, tmux: t1Bare)
        ),
        Case(
            description: "a record from before sightings, a newer move, and a newer observation with no place",
            legacy: seen(h, t1, at: 10),
            observations: [seen(k, t2, at: 20), seen(nil, at: 30, by: .app)],
            expected: .init(hostSessionID: k, tmux: t2)
        ),
    ]

    @Test("Every order of a sequence makes one record, at the place it must end at", arguments: cases)
    func everyOrderAgrees(_ sequence: Case) {
        let base = sequence.legacy.map(Self.legacy)
        #expect(Self.placeInEveryOrder(sequence.observations, onto: base) == sequence.expected)
    }

    @Test("A field takes the newest value that was observed, whatever arrived in between")
    func fieldsKeepTheirOwnTimes() {
        let observations = [
            Self.seen(Self.h, at: 1, cwd: "/a"),
            Self.seen(Self.h, at: 3, by: .app),
            Self.seen(Self.h, at: 2, cwd: "/b"),
        ]
        _ = Self.placeInEveryOrder(observations)
        let record = ConversationRecordJSON.record(from: Self.merged(observations))
        #expect(record?.cwd == "/b")
        #expect(record?.observedBy == .app)
        #expect(record?.observedAt == Date(timeIntervalSince1970: 1_800_000_003))
        #expect(record?.createdAt == Date(timeIntervalSince1970: 1_800_000_001))
    }

    /// Generated sets over two holders, every tmux fact, each optional session attribute
    /// present or absent, close times and two values per field, so ties, contradictions and
    /// returns without a description come up often. Half start from a record written before
    /// sightings.
    @Test("Generated sets of up to five observations merge the same in every order")
    func generatedSetsAgree() {
        var generator = SplitMix64(seed: 0x5EED)
        let holders: [String?] = [nil, Self.h, Self.k]
        let names: [String?] = [nil, "wm-one", "renamed"]
        let created: [Date?] = [
            nil, Date(timeIntervalSince1970: 1_799_999_000), Date(timeIntervalSince1970: 1_799_999_500),
        ]
        let observers: [ConversationObserver] = [.hook, .app, .wsLaunch, .migration]
        func observation(_ generator: inout SplitMix64) -> ConversationObservation {
            let tmux: ConversationRecord.TmuxSession?
            var outside = false
            switch Int.random(in: 0...3, using: &generator) {
            case 0: tmux = nil
            case 1:
                tmux = nil
                outside = true
            default:
                tmux = ConversationRecord.TmuxSession(
                    serverPID: 4242,
                    sessionID: ["$1", "$2"].randomElement(using: &generator)!,
                    createdAt: created.randomElement(using: &generator)!,
                    name: names.randomElement(using: &generator)!
                )
            }
            return Self.seen(
                holders.randomElement(using: &generator)!,
                tmux,
                at: TimeInterval(Int.random(in: 0...3, using: &generator)),
                outside: outside,
                by: observers.randomElement(using: &generator)!,
                cwd: ["/a", "/b", nil].randomElement(using: &generator)!
            )
        }
        for _ in 0..<120 {
            let base = Bool.random(using: &generator) ? Self.legacy(observation(&generator)) : nil
            let count = Int.random(in: 2...5, using: &generator)
            let observations = (0..<count).map { _ in observation(&generator) }
            _ = Self.placeInEveryOrder(observations, onto: base)
        }
    }
}

/// A small seeded generator, so a failing generated set is the same on every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
