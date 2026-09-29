//
//  DecisionNotificationSurface.swift
//  WorkspaceManager
//
//  Delivers the one decision an agent is waiting on as a notification whose
//  buttons are that decision's own options, and returns a tap to the board's
//  answer route. One slot, replaced rather than added to, so "one interruption
//  at a time" is a property of the identifier and not a policy a later edit can
//  forget.
//

import AppKit
import Foundation
import UserNotifications
import WorkspaceManagerCore
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "DecisionNotifications")

@MainActor
public final class DecisionNotificationSurface: NSObject {
    /// The single delivered notification. Posting over a delivered identifier
    /// replaces it, which is what keeps exactly one decision on screen without a
    /// bookkeeping pass that has to be right every time.
    static let slotIdentifier = "agent.decision.current"
    static let confirmationIdentifier = "agent.decision.confirmation"
    static let categoryIdentifier = "agent.decision"
    static let confirmationCategoryIdentifier = "agent.decision.undo"
    static let undoActionIdentifier = "undo"
    /// Action identifiers carry the option's index, never its text: an option is
    /// a sentence the agent wrote, and it may contain anything.
    static let optionActionPrefix = "option."
    private static let userInfoCardKey = "cardID"
    private static let userInfoOptionsKey = "options"

    /// Absent when this launch has no board it is allowed to answer against. The
    /// surface still claims the delegate in that case; it just never posts.
    private let client: DecisionBoardClient?
    private let boardURL: URL?
    private let pollInterval: Duration
    private let inlineLimit: Int
    private let visit: String
    private let notifications: UNUserNotificationCenter?

    private var pollTask: Task<Void, Never>?
    private var deliveredCardID: String?
    private var lastPostedAt: Date?
    private var confirmationDismissal: Task<Void, Never>?

    /// At most one interruption per window, matching `AgentNotificationPoster`,
    /// so a burst of card writes cannot strobe the banner.
    private static let coalescingWindow: TimeInterval = 30

    public init(
        boardURL: URL? = DecisionBoardConstants.resolvedBoardURL(),
        client: DecisionBoardClient? = nil,
        pollInterval: Duration = .seconds(30),
        inlineLimit: Int = DecisionNotificationProjection.defaultInlineLimit,
        visit: String = UUID().uuidString
    ) {
        self.boardURL = boardURL
        self.client = client ?? boardURL.map { DecisionBoardClient(baseURL: $0) }
        self.pollInterval = pollInterval
        self.inlineLimit = inlineLimit
        self.visit = visit
        self.notifications = Self.availableCenter()
        super.init()
    }

    /// Claims the notification delegate, whether or not this surface is going to
    /// post anything.
    ///
    /// The delegate has to be claimed before the app finishes launching, or a tap
    /// that launches the app arrives with nobody listening. Claiming it also
    /// repairs a defect that predates this surface (#1623): with no delegate at
    /// all, macOS suppresses every notification while WorkSpaces is frontmost, so
    /// the agent-permission notifications were being dropped in exactly the case
    /// they exist for — someone working in a tile while an agent waits on them.
    /// `willPresent` below answers for every notification the app posts, not only
    /// for decisions.
    public func claimDelegate() {
        notifications?.delegate = self
    }

    /// Starts asking the board what needs an answer.
    public func start() {
        claimDelegate()
        guard client != nil else {
            log.error("decision notifications: no board to answer against, so nothing will be posted")
            return
        }
        guard let notifications else {
            // Every reason this happens is a launch that is not a real .app, and
            // silence here reads exactly like a working surface with nothing to say.
            log.error(
                "decision notifications: no notification centre — bundle=\(Bundle.main.bundleIdentifier ?? "none", privacy: .public) url=\(Bundle.main.bundleURL.path, privacy: .public)"
            )
            return
        }
        log.info("decision notifications: polling \(self.boardURL?.absoluteString ?? "nowhere", privacy: .public)")

        // Authorization is asked for alongside the poll, never in front of it.
        // The request suspends until the person answers the system prompt, and a
        // prompt can sit unanswered indefinitely behind another window — waiting
        // on it would mean the surface never even reads the board, which is a
        // silence indistinguishable from having nothing to say.
        Task { _ = try? await notifications.requestAuthorization(options: [.alert, .sound]) }
        beginPolling()
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        confirmationDismissal?.cancel()
        confirmationDismissal = nil
    }

    private func beginPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// One pass over the board: what earns the slot now, and what should leave it.
    func tick() async {
        guard let client else { return }
        let cards: [DecisionCard]
        do {
            cards = try await client.decisions()
        } catch {
            // A board that cannot be read is a silent surface, which is the right
            // behaviour and the wrong thing to be unable to see.
            log.error("decision notifications: board unreadable — \(String(describing: error), privacy: .public)")
            return
        }
        guard let top = DecisionNotificationProjection.topCard(from: cards) else {
            // Nothing is waiting, so nothing should be on screen. Silence has to
            // mean silence or the channel stops being worth reading.
            withdrawSlot()
            return
        }
        guard top.id != deliveredCardID else { return }
        guard !isCoalescing else { return }
        await post(card: top, queued: DecisionNotificationProjection.queuedCount(from: cards))
    }

    private var isCoalescing: Bool {
        guard let lastPostedAt else { return false }
        return Date().timeIntervalSince(lastPostedAt) < Self.coalescingWindow
    }

    private func post(card: DecisionCard, queued: Int) async {
        guard let notifications else { return }
        let options = DecisionNotificationProjection.actionableOptions(for: card, inlineLimit: inlineLimit)

        let content = UNMutableNotificationContent()
        content.title = card.title
        content.body = DecisionNotificationProjection.body(for: card, queued: queued)
        content.sound = .default
        content.userInfo = [Self.userInfoCardKey: card.id, Self.userInfoOptionsKey: options]
        content.categoryIdentifier = Self.categoryIdentifier

        // Categories are registered app-wide, so the set is rebuilt for the card
        // about to be posted rather than accumulated per card — a registry that
        // grows with every decision would outlive the decisions themselves.
        notifications.setNotificationCategories([
            Self.category(options: options, recommended: card.recommended),
            Self.confirmationCategory(),
        ])

        let request = UNNotificationRequest(
            identifier: Self.slotIdentifier, content: content, trigger: nil)
        do {
            try await notifications.add(request)
        } catch {
            // Worth naming the authorization state beside the refusal: "not
            // allowed" with a notDetermined status is an unanswered system
            // prompt, not a bug in the surface, and the two look identical from
            // the outside — both are simply no notification.
            let settings = await notifications.notificationSettings()
            log.error(
                "decision notifications: post refused — \(String(describing: error), privacy: .public) authorization=\(settings.authorizationStatus.rawValue, privacy: .public)"
            )
            return
        }
        log.info(
            "decision notifications: posted \(card.id, privacy: .public) with \(options.count, privacy: .public) buttons, \(queued, privacy: .public) queued"
        )
        deliveredCardID = card.id
        lastPostedAt = Date()
        await client?.recordNotifySent(id: card.id, queued: queued, visit: visit)
    }

    private static func category(options: [String], recommended: String?) -> UNNotificationCategory {
        let actions = options.enumerated().map { index, option in
            UNNotificationAction(
                identifier: optionActionPrefix + String(index),
                // The agent's prediction is marked before anyone answers, which is
                // what makes a click a verdict on a guess rather than a vote.
                title: option == recommended ? "\(option) (recommended)" : option,
                options: [.foreground]
            )
        }
        return UNNotificationCategory(
            identifier: categoryIdentifier, actions: actions,
            intentIdentifiers: [], options: [.customDismissAction])
    }

    private static func confirmationCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: confirmationCategoryIdentifier,
            actions: [UNNotificationAction(identifier: undoActionIdentifier, title: "Undo", options: [])],
            intentIdentifiers: [], options: [])
    }

    private func withdrawSlot() {
        deliveredCardID = nil
        notifications?.removeDeliveredNotifications(withIdentifiers: [Self.slotIdentifier])
    }

    /// The board's own undo window, made visible. A board click gets eight
    /// seconds and a toast; a tap would get neither, and a channel whose
    /// mis-taps cannot be taken back gets used slowly.
    private func confirm(option: String, cardID: String) {
        guard let notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "Recorded"
        content.body = option
        content.categoryIdentifier = Self.confirmationCategoryIdentifier
        content.userInfo = [Self.userInfoCardKey: cardID]
        let request = UNNotificationRequest(
            identifier: Self.confirmationIdentifier, content: content, trigger: nil)

        confirmationDismissal?.cancel()
        confirmationDismissal = Task { [weak self] in
            try? await notifications.add(request)
            try? await Task.sleep(for: .seconds(DecisionBoardConstants.undoWindow))
            guard !Task.isCancelled else { return }
            self?.notifications?.removeDeliveredNotifications(
                withIdentifiers: [Self.confirmationIdentifier])
        }
    }

    private func openBoard() {
        guard let boardURL else { return }
        // The board root, not a fragment: the page injects its cards after an
        // async fetch, so an anchor resolves against a document that does not yet
        // hold the element and lands at the top regardless.
        NSWorkspace.shared.open(boardURL)
    }

    private static func availableCenter() -> UNUserNotificationCenter? {
        guard UserNotificationsAvailability.isAvailable else { return nil }
        return UNUserNotificationCenter.current()
    }
}

extension DecisionNotificationSurface: UNUserNotificationCenterDelegate {
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // A decision is worth showing even when the app is frontmost; that is the
        // whole point of the surface.
        [.banner, .sound]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        // Captured when the notification was posted, so it still names the card
        // that was actually tapped even if the slot has moved on since.
        guard let cardID = info[Self.userInfoCardKey] as? String else { return }
        let options = info[Self.userInfoOptionsKey] as? [String] ?? []
        await handle(action: response.actionIdentifier, cardID: cardID, options: options)
    }

    private func handle(action: String, cardID: String, options: [String]) async {
        switch action {
        case UNNotificationDefaultActionIdentifier:
            openBoard()
        case Self.undoActionIdentifier:
            try? await client?.undo(id: cardID)
            confirmationDismissal?.cancel()
            notifications?.removeDeliveredNotifications(withIdentifiers: [Self.confirmationIdentifier])
            deliveredCardID = nil
        case let identifier where identifier.hasPrefix(Self.optionActionPrefix):
            let raw = identifier.dropFirst(Self.optionActionPrefix.count)
            guard let index = Int(raw), options.indices.contains(index) else { return }
            let option = options[index]
            do {
                try await client?.answer(id: cardID, option: option, at: Date())
                withdrawSlot()
                confirm(option: option, cardID: cardID)
            } catch {
                // The answer did not land, so the decision is still open and the
                // notification should not claim otherwise.
                deliveredCardID = nil
            }
        default:
            break
        }
    }
}
