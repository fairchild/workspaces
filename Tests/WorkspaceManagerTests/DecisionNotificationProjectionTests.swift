import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("DecisionNotificationProjection")
struct DecisionNotificationProjectionTests {
    private func card(
        _ id: String,
        order: Int = 50,
        askedAt: Date? = nil,
        options: [String] = ["yes", "no"],
        title: String = "A decision",
        detail: String = ""
    ) -> DecisionCard {
        DecisionCard(
            id: id, title: title, detail: detail, options: options,
            recommended: options.first, topic: "releases", order: order, askedAt: askedAt
        )
    }

    @Test("The board's priority decides which decision interrupts first")
    func topCardFollowsOrder() {
        let cards = [card("b", order: 20), card("a", order: 10), card("c", order: 30)]
        #expect(DecisionNotificationProjection.topCard(from: cards)?.id == "a")
    }

    @Test("Equal priority gives way to the decision that has waited longest")
    func topCardBreaksTiesByAge() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let cards = [card("new", order: 10, askedAt: new), card("old", order: 10, askedAt: old)]
        #expect(DecisionNotificationProjection.topCard(from: cards)?.id == "old")
    }

    @Test("Two otherwise equal decisions keep a stable order between polls")
    func topCardIsStable() {
        let at = Date(timeIntervalSince1970: 1_000)
        let forward = [card("a", order: 10, askedAt: at), card("b", order: 10, askedAt: at)]
        let reversed = Array(forward.reversed())
        #expect(DecisionNotificationProjection.topCard(from: forward)?.id == "a")
        #expect(DecisionNotificationProjection.topCard(from: reversed)?.id == "a")
    }

    @Test("Nothing waiting means nothing to say")
    func topCardOfNothing() {
        #expect(DecisionNotificationProjection.topCard(from: []) == nil)
    }

    @Test("The rest of the queue is counted, not delivered")
    func queuedCounts() {
        #expect(DecisionNotificationProjection.queuedCount(from: []) == 0)
        #expect(DecisionNotificationProjection.queuedCount(from: [card("a")]) == 0)
        #expect(DecisionNotificationProjection.queuedCount(from: [card("a"), card("b"), card("c")]) == 2)
    }

    @Test("A decision that fits offers every one of its options")
    func optionsAtTheLimit() {
        let two = card("a", options: ["ship it", "hold"])
        #expect(DecisionNotificationProjection.actionableOptions(for: two, inlineLimit: 2) == ["ship it", "hold"])
    }

    @Test("A decision too wide to show offers none of its options rather than some")
    func optionsPastTheLimit() {
        let three = card("a", options: ["one", "two", "three"])
        #expect(DecisionNotificationProjection.actionableOptions(for: three, inlineLimit: 2).isEmpty)
    }

    @Test("A single option is still offered")
    func singleOption() {
        let one = card("a", options: ["acknowledge"])
        #expect(DecisionNotificationProjection.actionableOptions(for: one, inlineLimit: 2) == ["acknowledge"])
    }

    @Test("Blank options are not options")
    func blankOptionsIgnored() {
        let padded = card("a", options: ["real", "   ", ""])
        #expect(DecisionNotificationProjection.actionableOptions(for: padded, inlineLimit: 2) == ["real"])
    }

    @Test("The body says how many others are waiting, and only when some are")
    func bodyCarriesTheQueue() {
        let one = card("a", detail: "Nine pull requests waited eleven hours.")
        #expect(DecisionNotificationProjection.body(for: one, queued: 0) == "Nine pull requests waited eleven hours.")
        #expect(DecisionNotificationProjection.body(for: one, queued: 1).hasSuffix("1 more decision waiting"))
        #expect(DecisionNotificationProjection.body(for: one, queued: 3).hasSuffix("3 more decisions waiting"))
    }

    @Test("A decision with no detail falls back to its own title")
    func bodyFallsBackToTitle() {
        let bare = card("a", title: "Should the release publish itself?", detail: "   ")
        #expect(DecisionNotificationProjection.body(for: bare, queued: 0) == "Should the release publish itself?")
    }

    @Test("An answered card is not offered, and is not counted in the queue")
    func answeredCardsAreNotOffered() {
        let open = DecisionCard(id: "open", title: "Open", options: ["a"], order: 20, status: "open")
        let answered = DecisionCard(
            id: "done", title: "Done", options: ["a"], order: 10, status: "answered")
        #expect(DecisionNotificationProjection.topCard(from: [answered, open])?.id == "open")
        #expect(DecisionNotificationProjection.queuedCount(from: [answered, open]) == 0)
    }

    @Test("A card with no status yet is open")
    func absentStatusIsOpen() {
        #expect(DecisionCard(id: "a", title: "A", options: ["x"], status: "").isOpen)
    }
}

@Suite("BoardTimestamp")
struct BoardTimestampTests {
    @Test("Both stamp shapes the store actually holds are read")
    func readsBothShapes() throws {
        // The page writes fractional seconds; the card writer writes whole ones.
        // A reader that took only one would return nil for half the store and
        // quietly reorder which decision interrupts first, failing no test.
        let fractional = try #require(BoardTimestamp.read("2026-09-13T19:39:04.857Z"))
        let whole = try #require(BoardTimestamp.read("2026-09-13T04:32:45Z"))
        #expect(fractional > whole)
    }

    @Test("Nothing is not a time")
    func readsNothing() {
        #expect(BoardTimestamp.read("") == nil)
        #expect(BoardTimestamp.read("   ") == nil)
        #expect(BoardTimestamp.read("not a stamp") == nil)
    }

    @Test("A written stamp is the shape the board page writes, and reads back")
    func writesThePageShape() throws {
        let at = Date(timeIntervalSince1970: 1_789_000_000.5)
        let written = BoardTimestamp.write(at)
        #expect(written.hasSuffix("Z"))
        #expect(written.contains("."))
        let round = try #require(BoardTimestamp.read(written))
        #expect(abs(round.timeIntervalSince(at)) < 0.002)
    }
}

@Suite("Board URL resolution")
struct DecisionBoardURLTests {
    private let key = DecisionBoardConstants.boardURLEnvironmentKey
    private let syntheticKey = LaunchPreferencesEnvironment.syntheticRootKey

    @Test("An ordinary launch answers against the live board")
    func defaultsToLive() {
        #expect(
            DecisionBoardConstants.resolvedBoardURL(environment: [:])?.absoluteString
                == "http://127.0.0.1:8791")
    }

    @Test("An isolated run with no board named gets no board at all")
    func isolatedWithoutOverrideFailsClosed() {
        // The default is production. A synthetic run that fell back to it would
        // write a real verdict into the real store and look like it worked.
        #expect(
            DecisionBoardConstants.resolvedBoardURL(environment: [syntheticKey: "/tmp/scratch"]) == nil)
    }

    @Test("An isolated run that names its board uses it")
    func isolatedWithOverride() {
        let url = DecisionBoardConstants.resolvedBoardURL(
            environment: [syntheticKey: "/tmp/scratch", key: "http://127.0.0.1:8850"])
        #expect(url?.absoluteString == "http://127.0.0.1:8850")
    }

    @Test("A named board wins over the default even without isolation")
    func overrideWinsAnyway() {
        let url = DecisionBoardConstants.resolvedBoardURL(environment: [key: "http://127.0.0.1:9999"])
        #expect(url?.absoluteString == "http://127.0.0.1:9999")
    }
}
