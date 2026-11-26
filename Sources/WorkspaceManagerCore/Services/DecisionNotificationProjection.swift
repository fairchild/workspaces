//
//  DecisionNotificationProjection.swift
//  WorkspaceManagerCore
//
//  Decides which agent decision earns an interruption and what a notification
//  may say about it. Pure, so the rules that govern a person's attention can be
//  tested without a notification centre — the same reason
//  `AgentChromeProjection` holds the permission-prompt rule.
//

import Foundation

/// One decision from an agent decision board, as the app reads it.
///
/// Read-only on purpose. `recommended`, `order` and `topic` are the board's
/// fields and the app never computes them; if it did, two surfaces would
/// disagree about the same decision and neither would be worth trusting.
public struct DecisionCard: Sendable, Equatable {
    /// The board's document id, which is also how an answer addresses it.
    public let id: String
    public let title: String
    public let detail: String
    public let options: [String]
    /// The agent's prediction, marked before anyone answers. The board scores
    /// the answer against it; the app only renders it.
    public let recommended: String?
    public let topic: String?
    /// The board's priority. Lower comes first. 50 is the card writer's default.
    public let order: Int
    public let askedAt: Date?
    /// Kept rather than filtered away at decode. "Answered elsewhere" and
    /// "deleted" are different withdrawal reasons and the surface needs to tell
    /// them apart without a second read.
    public let status: String

    public init(
        id: String,
        title: String,
        detail: String = "",
        options: [String] = [],
        recommended: String? = nil,
        topic: String? = nil,
        order: Int = 50,
        askedAt: Date? = nil,
        status: String = "open"
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.options = options
        self.recommended = recommended
        self.topic = topic
        self.order = order
        self.askedAt = askedAt
        self.status = status
    }

    /// Still waiting for an answer. The board writes an empty status on a card that has
    /// never been touched, so absence reads as open.
    public var isOpen: Bool {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "open"
    }
}

public enum DecisionNotificationProjection {
    /// How many actions the surface will render as buttons before it stops
    /// offering any. macOS collapses actions past a small number into a menu,
    /// which stops being one-tap; the real number is settled by watching a real
    /// notification, so this is a default rather than a constant.
    public static let defaultInlineLimit = 2

    /// The one card that earns the interruption: the board's own priority, then
    /// the oldest ask, then the id so two equal cards never swap places between
    /// polls and restate themselves as a new notification.
    public static func topCard(from cards: [DecisionCard]) -> DecisionCard? {
        cards.filter(\.isOpen).min { left, right in
            if left.order != right.order { return left.order < right.order }
            switch (left.askedAt, right.askedAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate < rightDate
            case (nil, _?):
                // An undated ask is the older one: it predates the stamp.
                return true
            case (_?, nil):
                return false
            default:
                return left.id < right.id
            }
        }
    }

    /// The rest of the queue. It is a count in the body, never a second
    /// notification — the queue depth is information, an interruption is a cost.
    public static func queuedCount(from cards: [DecisionCard]) -> Int {
        max(0, cards.filter(\.isOpen).count - 1)
    }

    /// Every option, or none of them.
    ///
    /// Never a subset. The board scores an answer against a prediction made over
    /// a particular set of options, so a notification showing two of three asks a
    /// different question than the card asked and the alignment record goes on
    /// reporting a number for a question nobody was asked. A card too wide for
    /// the notification gets no buttons and opens the board instead, which is
    /// slower and honest.
    public static func actionableOptions(
        for card: DecisionCard,
        inlineLimit: Int = defaultInlineLimit
    ) -> [String] {
        let usable = card.options.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty, usable.count <= inlineLimit else { return [] }
        return usable
    }

    /// What the notification says under the title: the card's own detail, and the
    /// size of the queue behind it when there is one.
    public static func body(for card: DecisionCard, queued: Int) -> String {
        let detail = card.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = detail.isEmpty ? card.title : detail
        guard queued > 0 else { return lead }
        let tail = queued == 1 ? "1 more decision waiting" : "\(queued) more decisions waiting"
        return lead.isEmpty ? tail : "\(lead)\n\(tail)"
    }
}
