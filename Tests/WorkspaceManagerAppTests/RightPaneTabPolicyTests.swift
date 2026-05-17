import Testing

@testable import WorkspaceManager

@Suite("RightPaneTabPolicy")
struct RightPaneTabPolicyTests {
    @Test("Workspace tabs include activity when notifications are enabled")
    func workspaceTabsIncludeActivityWhenNotificationsEnabled() {
        let policy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showActivity: true,
            notificationsEnabled: true
        )

        #expect(policy.visibleTabs == [.files, .changes, .activity, .diagnostics])
    }

    @Test("Workspace tabs exclude activity when notifications are disabled")
    func workspaceTabsExcludeActivityWhenNotificationsDisabled() {
        let policy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showActivity: true,
            notificationsEnabled: false
        )

        #expect(policy.visibleTabs == [.files, .changes, .diagnostics])
    }

    @Test("Disabling notifications normalizes activity selection to files")
    func disablingNotificationsNormalizesActivitySelectionToFiles() {
        let policy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showActivity: true,
            notificationsEnabled: false
        )

        #expect(policy.normalizedSelection(for: .activity) == .files)
    }

    @Test("Repo tabs exclude activity regardless of notification setting")
    func repoTabsExcludeActivityRegardlessOfNotificationSetting() {
        let disabledPolicy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showActivity: false,
            notificationsEnabled: false
        )
        let enabledPolicy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showActivity: false,
            notificationsEnabled: true
        )

        #expect(disabledPolicy.visibleTabs == [.files, .changes, .diagnostics])
        #expect(enabledPolicy.visibleTabs == [.files, .changes, .diagnostics])
    }

    @Test("Disabled notifications preserve non-activity tab selections")
    func disabledNotificationsPreserveNonActivitySelections() {
        let disabledPolicy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showActivity: true,
            notificationsEnabled: false
        )

        #expect(disabledPolicy.normalizedSelection(for: .files) == .files)
        #expect(disabledPolicy.normalizedSelection(for: .changes) == .changes)
        #expect(disabledPolicy.normalizedSelection(for: .diagnostics) == .diagnostics)
    }

    @Test("Re-enabling notifications keeps a previously normalized files selection")
    func reenablingNotificationsKeepsNormalizedFilesSelection() {
        let disabledPolicy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showActivity: true,
            notificationsEnabled: false
        )
        let normalizedSelection = disabledPolicy.normalizedSelection(for: .activity)
        let reenabledPolicy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showActivity: true,
            notificationsEnabled: true
        )

        #expect(normalizedSelection == .files)
        #expect(reenabledPolicy.normalizedSelection(for: normalizedSelection) == .files)
    }

    @Test("Diagnostics stays visible without filesystem inspection")
    func diagnosticsStaysVisibleWithoutFilesystemInspection() {
        let policy = RightPaneTabPolicy(
            supportsFilesystemInspection: false,
            showActivity: true,
            notificationsEnabled: false
        )

        #expect(policy.visibleTabs == [.files, .diagnostics])
        #expect(policy.normalizedSelection(for: .diagnostics) == .diagnostics)
    }

    @Test("Diagnostics tab uses widened Detail Pane dimensions")
    func diagnosticsTabUsesWidenedDetailPaneDimensions() {
        let policy = RightPaneWidthPolicy()

        #expect(policy.width(for: .files) == RightPaneWidth(minimum: 220, ideal: 280, maximum: 400))
        #expect(policy.width(for: .diagnostics) == RightPaneWidth(minimum: 360, ideal: 640, maximum: 760))
    }
}
