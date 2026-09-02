//
//  SettingsDestination.swift
//  WorkspaceManager
//
//  Where a caller wants the Settings window to land. Settings is one scrolling
//  Form rather than a tab bar, so "Settings → Agents" is a scroll target, not a
//  selection: a caller names a section, opens the window, and SettingsView
//  consumes the request once and scrolls there.
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
/// request is consumed by the first appearance that answers it, so opening
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
    func consumePendingSection() -> SettingsSection? {
        defer { pendingSection = nil }
        return pendingSection
    }
}
