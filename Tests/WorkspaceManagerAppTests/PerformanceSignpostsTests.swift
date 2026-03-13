import Foundation
import Testing

@testable import WorkspaceManager

@Suite("PerformanceSignposts", .serialized)
struct PerformanceSignpostsTests {
    private struct MetricEvent: Equatable {
        let phase: String
        let fields: [String: String]
    }

    @Test("New Workspace metrics record success and duration")
    func newWorkspaceMetricRecordsSuccess() {
        var events: [MetricEvent] = []
        PerformanceSignposts.setNewWorkspaceSheetMetricObserver { phase, fields in
            events.append(MetricEvent(phase: phase, fields: fields))
        }
        defer {
            PerformanceSignposts.setNewWorkspaceSheetMetricObserver(nil)
        }

        let attemptID = PerformanceSignposts.beginNewWorkspaceSheetReady(trigger: "sidebar")
        PerformanceSignposts.endNewWorkspaceSheetReadyIfNeeded(
            attemptID: attemptID,
            outcome: "success"
        )

        #expect(events.count == 2)
        guard events.count == 2 else { return }
        #expect(events[0].phase == "started")
        #expect(events[0].fields["metric"] == "new_workspace_sheet_ready")
        #expect(events[0].fields["status"] == "started")
        #expect(events[0].fields["trigger"] == "sidebar")

        #expect(events[1].phase == "completed")
        #expect(events[1].fields["metric"] == "new_workspace_sheet_ready")
        #expect(events[1].fields["status"] == "completed")
        #expect(events[1].fields["trigger"] == "sidebar")
        #expect(events[1].fields["outcome"] == "success")
        #expect(events[1].fields["duration_ms"] != nil)
    }

    @Test("New Workspace metrics supersede overlapping attempts without double completion")
    func newWorkspaceMetricSupersedesOverlap() {
        var events: [MetricEvent] = []
        PerformanceSignposts.setNewWorkspaceSheetMetricObserver { phase, fields in
            events.append(MetricEvent(phase: phase, fields: fields))
        }
        defer {
            PerformanceSignposts.setNewWorkspaceSheetMetricObserver(nil)
        }

        let firstAttemptID = PerformanceSignposts.beginNewWorkspaceSheetReady(trigger: "landing")
        let secondAttemptID = PerformanceSignposts.beginNewWorkspaceSheetReady(trigger: "sidebar")

        PerformanceSignposts.endNewWorkspaceSheetReadyIfNeeded(
            attemptID: firstAttemptID,
            outcome: "success"
        )
        PerformanceSignposts.endNewWorkspaceSheetReadyIfNeeded(
            attemptID: secondAttemptID,
            outcome: "success"
        )

        #expect(events.count == 4)
        guard events.count == 4 else { return }
        #expect(events[0].phase == "started")
        #expect(events[0].fields["trigger"] == "landing")

        #expect(events[1].phase == "completed")
        #expect(events[1].fields["trigger"] == "landing")
        #expect(events[1].fields["outcome"] == "superseded")

        #expect(events[2].phase == "started")
        #expect(events[2].fields["trigger"] == "sidebar")

        #expect(events[3].phase == "completed")
        #expect(events[3].fields["trigger"] == "sidebar")
        #expect(events[3].fields["outcome"] == "success")
    }
}
