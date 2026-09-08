//
//  SettingsDestination.swift
//  WorkspaceManager
//
//  Where a caller wants the Settings window to land. Settings is one scrolling
//  Form rather than a tab bar, so "Settings → Agents" is a scroll target, not a
//  selection: a caller names a section, opens the window, and the scroller
//  below gets it on screen and then clears the request.
//

import SwiftUI

/// A named anchor inside the Settings form. The raw value doubles as the
/// `ScrollViewReader` id, so a section and its anchor cannot drift apart.
enum SettingsSection: String, Hashable, CaseIterable, Identifiable {
    case agents

    var id: String { rawValue }
}

/// Carries a one-shot "open Settings at this section" request between whoever
/// offers the affordance and the Settings window. One-shot is the point: the
/// request is cleared once a scroll has actually been attempted, so opening
/// Settings by ordinary means afterwards lands where the user left it rather
/// than re-scrolling to a destination nobody asked for.
@MainActor
final class SettingsDestinationRouter: ObservableObject {
    static let shared = SettingsDestinationRouter()

    @Published private(set) var pendingSection: SettingsSection?

    init(pendingSection: SettingsSection? = nil) {
        self.pendingSection = pendingSection
    }

    func request(_ section: SettingsSection) {
        pendingSection = section
    }

    /// Returns the pending section, if any, and clears it.
    @discardableResult
    func consumePendingSection() -> SettingsSection? {
        defer { pendingSection = nil }
        return pendingSection
    }
}

/// Gets a requested section on screen, then clears the request.
///
/// The retry is the whole point. Both `onAppear` and `.task` run before the
/// first rendered frame, and `ScrollViewProxy.scrollTo` against an id the Form
/// has not registered yet is a silent no-op. A single immediate attempt would
/// therefore consume the request and leave the user at the top of Settings —
/// the one outcome this feature exists to prevent. So the request survives
/// every attempt and is cleared only once they are spent.
///
/// The collaborators are injected so the rule is testable without a rendered
/// Form; `SettingsView` supplies the real sleep and the real proxy.
@MainActor
struct SettingsSectionScroller {
    static let defaultAttempts = 3
    static let defaultDelay = Duration.milliseconds(120)

    var attempts: Int = Self.defaultAttempts
    var delay: Duration = Self.defaultDelay
    var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    var scrollTo: (SettingsSection) -> Void

    func run(_ router: SettingsDestinationRouter) async {
        guard router.pendingSection != nil else { return }
        for _ in 0..<max(attempts, 1) {
            await sleep(delay)
            if Task.isCancelled { return }
            guard let section = router.pendingSection else { return }
            scrollTo(section)
        }
        router.consumePendingSection()
    }
}
