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

        #expect(policy.visibleTabs == [.files, .changes, .activity])
    }

    @Test("Workspace tabs exclude activity when notifications are disabled")
    func workspaceTabsExcludeActivityWhenNotificationsDisabled() {
        let policy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showActivity: true,
            notificationsEnabled: false
        )

        #expect(policy.visibleTabs == [.files, .changes])
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

    @Test("Re-enabling notifications preserves the normalized non-activity selection")
    func reenablingNotificationsPreservesNormalizedSelection() {
        let disabledPolicy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showActivity: true,
            notificationsEnabled: false
        )
        let normalizedSelection = disabledPolicy.normalizedSelection(for: .activity)

        let enabledPolicy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showActivity: true,
            notificationsEnabled: true
        )

        #expect(normalizedSelection == .files)
        #expect(enabledPolicy.normalizedSelection(for: normalizedSelection) == .files)
    }
}
