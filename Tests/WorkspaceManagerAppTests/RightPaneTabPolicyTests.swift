import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("RightPaneTabPolicy")
struct RightPaneTabPolicyTests {
    @Test("Workspace tabs include activity when notifications are enabled")
    func workspaceTabsIncludeActivityWhenNotificationsEnabled() {
        let policy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showTimeline: true,
            showActivity: true,
            notificationsEnabled: true
        )

        #expect(policy.visibleTabs == [.files, .changes, .timeline, .activity, .diagnostics])
    }

    @Test("Workspace tabs exclude activity when notifications are disabled")
    func workspaceTabsExcludeActivityWhenNotificationsDisabled() {
        let policy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showTimeline: true,
            showActivity: true,
            notificationsEnabled: false
        )

        #expect(policy.visibleTabs == [.files, .changes, .timeline, .diagnostics])
    }

    @Test("Workspace timeline is independent of notification settings")
    func workspaceTimelineIsIndependentOfNotificationSettings() {
        let disabledPolicy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showTimeline: true,
            showActivity: true,
            notificationsEnabled: false
        )
        let enabledPolicy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showTimeline: true,
            showActivity: true,
            notificationsEnabled: true
        )

        #expect(disabledPolicy.visibleTabs.contains(.timeline))
        #expect(enabledPolicy.visibleTabs.contains(.timeline))
    }

    @Test("Disabling notifications normalizes activity selection to files")
    func disablingNotificationsNormalizesActivitySelectionToFiles() {
        let policy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showTimeline: true,
            showActivity: true,
            notificationsEnabled: false
        )

        #expect(policy.normalizedSelection(for: .activity) == .files)
    }

    @Test("Repo tabs exclude activity regardless of notification setting")
    func repoTabsExcludeActivityRegardlessOfNotificationSetting() {
        let disabledPolicy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showTimeline: false,
            showActivity: false,
            notificationsEnabled: false
        )
        let enabledPolicy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showTimeline: false,
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
            showTimeline: true,
            showActivity: true,
            notificationsEnabled: false
        )

        #expect(disabledPolicy.normalizedSelection(for: .files) == .files)
        #expect(disabledPolicy.normalizedSelection(for: .changes) == .changes)
        #expect(disabledPolicy.normalizedSelection(for: .timeline) == .timeline)
        #expect(disabledPolicy.normalizedSelection(for: .diagnostics) == .diagnostics)
    }

    @Test("Re-enabling notifications keeps a previously normalized files selection")
    func reenablingNotificationsKeepsNormalizedFilesSelection() {
        let disabledPolicy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showTimeline: true,
            showActivity: true,
            notificationsEnabled: false
        )
        let normalizedSelection = disabledPolicy.normalizedSelection(for: .activity)
        let reenabledPolicy = RightPaneTabPolicy(
            supportsFilesystemInspection: true,
            showTimeline: true,
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
            showTimeline: true,
            showActivity: true,
            notificationsEnabled: false
        )

        #expect(policy.visibleTabs == [.files, .timeline, .diagnostics])
        #expect(policy.normalizedSelection(for: .diagnostics) == .diagnostics)
    }

    @Test("Diagnostics tab uses widened Detail Pane dimensions")
    func diagnosticsTabUsesWidenedDetailPaneDimensions() {
        let policy = RightPaneWidthPolicy()

        #expect(policy.width(for: .files) == RightPaneWidth(minimum: 220, ideal: 280, maximum: 400))
        #expect(policy.width(for: .timeline) == RightPaneWidth(minimum: 220, ideal: 280, maximum: 400))
        #expect(policy.width(for: .diagnostics) == RightPaneWidth(minimum: 360, ideal: 640, maximum: 760))
    }

    @Test("Timeline projection names agent events")
    func timelineProjectionNamesAgentEvents() {
        let workspaceID = UUID()
        let hostSessionID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        let tool = WorkspaceTimelinePresentation.event(
            WorkspaceEvent(
                workspaceID: workspaceID,
                hostSessionID: hostSessionID,
                timestamp: timestamp,
                kind: .toolRun(name: "Bash"),
                rowID: "tool"
            )
        )
        #expect(tool.title == "Ran Bash")
        #expect(tool.detail == "Tool execution")
        #expect(tool.tone == WorkspaceTimelinePresentation.Tone.running)

        let awaiting = WorkspaceTimelinePresentation.event(
            WorkspaceEvent(
                workspaceID: workspaceID,
                hostSessionID: hostSessionID,
                timestamp: timestamp,
                kind: .stateTransition(from: .thinking, to: .awaitingInput(reason: .permissionPrompt)),
                rowID: "awaiting"
            )
        )
        #expect(awaiting.title == "Agent needs input")
        #expect(awaiting.detail == "Awaiting input")
        #expect(awaiting.tone == WorkspaceTimelinePresentation.Tone.attention)
    }
}
