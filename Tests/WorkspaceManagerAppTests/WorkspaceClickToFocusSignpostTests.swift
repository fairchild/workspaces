//
//  WorkspaceClickToFocusSignpostTests.swift
//  WorkspaceManagerAppTests
//
//  Tests for workspace_click_to_focus metric lifecycle.
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("PerformanceSignposts workspace_click_to_focus", .serialized)
struct WorkspaceClickToFocusSignpostTests {
    init() {
        PerformanceSignposts.setWorkspaceClickMetricObserver(nil)
    }

    @Test("begin emits started event")
    func beginEmitsStarted() async {
        var captured: [(phase: String, fields: [String: String])] = []
        PerformanceSignposts.setWorkspaceClickMetricObserver { phase, fields in
            captured.append((phase, fields))
        }
        defer { PerformanceSignposts.setWorkspaceClickMetricObserver(nil) }

        let sessionID = UUID()
        PerformanceSignposts.beginWorkspaceClickToFocusedInput(
            sessionID: sessionID,
            workspacePath: "/tmp/test-workspace"
        )
        PerformanceSignposts.cancelWorkspaceClickToFocusedInputIfNeeded(
            sessionID: sessionID,
            reason: "test_cleanup"
        )

        let startedEvents = captured.filter { $0.fields["status"] == "started" }
        #expect(startedEvents.count == 1)
        #expect(startedEvents.first?.fields["metric"] == "workspace_click_to_focus")
        #expect(startedEvents.first?.fields["session"] == sessionID.uuidString)
    }

    @Test("end emits completed event with duration")
    func endEmitsCompleted() async {
        var captured: [(phase: String, fields: [String: String])] = []
        PerformanceSignposts.setWorkspaceClickMetricObserver { phase, fields in
            captured.append((phase, fields))
        }
        defer { PerformanceSignposts.setWorkspaceClickMetricObserver(nil) }

        let sessionID = UUID()
        PerformanceSignposts.beginWorkspaceClickToFocusedInput(
            sessionID: sessionID,
            workspacePath: "/tmp/test-workspace"
        )
        PerformanceSignposts.endWorkspaceClickToFocusedInputIfNeeded(
            sessionID: sessionID,
            outcome: "focused"
        )

        let completedEvents = captured.filter {
            $0.fields["status"] == "completed" && $0.fields["outcome"] == "focused"
        }
        #expect(completedEvents.count == 1)
        #expect(completedEvents.first?.fields["duration_ms"] != nil)
    }

    @Test("end without begin is a no-op")
    func endWithoutBeginIsNoOp() async {
        var captured: [(phase: String, fields: [String: String])] = []
        PerformanceSignposts.setWorkspaceClickMetricObserver { phase, fields in
            captured.append((phase, fields))
        }
        defer { PerformanceSignposts.setWorkspaceClickMetricObserver(nil) }

        PerformanceSignposts.endWorkspaceClickToFocusedInputIfNeeded(
            sessionID: UUID(),
            outcome: "focused"
        )

        #expect(captured.isEmpty)
    }

    @Test("restarting the same session supersedes the prior interval")
    func supersedeClosesPrevious() async {
        var captured: [(phase: String, fields: [String: String])] = []
        PerformanceSignposts.setWorkspaceClickMetricObserver { phase, fields in
            captured.append((phase, fields))
        }
        defer { PerformanceSignposts.setWorkspaceClickMetricObserver(nil) }

        let sessionID = UUID()

        PerformanceSignposts.beginWorkspaceClickToFocusedInput(
            sessionID: sessionID,
            workspacePath: "/tmp/workspace-a"
        )
        PerformanceSignposts.beginWorkspaceClickToFocusedInput(
            sessionID: sessionID,
            workspacePath: "/tmp/workspace-b"
        )
        PerformanceSignposts.cancelWorkspaceClickToFocusedInputIfNeeded(
            sessionID: sessionID,
            reason: "test_cleanup"
        )

        let supersededEvents = captured.filter { $0.fields["outcome"] == "superseded" }
        #expect(supersededEvents.count == 1)
        #expect(supersededEvents.first?.fields["session"] == sessionID.uuidString)
    }

    @Test("cancel closes interval with reason")
    func cancelClosesWithReason() async {
        var captured: [(phase: String, fields: [String: String])] = []
        PerformanceSignposts.setWorkspaceClickMetricObserver { phase, fields in
            captured.append((phase, fields))
        }
        defer { PerformanceSignposts.setWorkspaceClickMetricObserver(nil) }

        let sessionID = UUID()
        PerformanceSignposts.beginWorkspaceClickToFocusedInput(
            sessionID: sessionID,
            workspacePath: "/tmp/test-workspace"
        )
        PerformanceSignposts.cancelWorkspaceClickToFocusedInputIfNeeded(
            sessionID: sessionID,
            reason: "workspace_selected"
        )

        let cancelledEvents = captured.filter { $0.fields["outcome"] == "workspace_selected" }
        #expect(cancelledEvents.count == 1)
        #expect(cancelledEvents.first?.fields["session"] == sessionID.uuidString)
    }

    @Test("cancel with wrong session is a no-op")
    func cancelWrongSessionNoOp() async {
        var captured: [(phase: String, fields: [String: String])] = []
        PerformanceSignposts.setWorkspaceClickMetricObserver { phase, fields in
            captured.append((phase, fields))
        }
        defer { PerformanceSignposts.setWorkspaceClickMetricObserver(nil) }

        let activeSession = UUID()
        PerformanceSignposts.beginWorkspaceClickToFocusedInput(
            sessionID: activeSession,
            workspacePath: "/tmp/test-workspace"
        )
        PerformanceSignposts.cancelWorkspaceClickToFocusedInputIfNeeded(
            sessionID: UUID(),
            reason: "wrong_session"
        )

        let completedEvents = captured.filter { $0.fields["status"] == "completed" }
        #expect(completedEvents.isEmpty)

        PerformanceSignposts.cancelWorkspaceClickToFocusedInputIfNeeded(
            sessionID: activeSession,
            reason: "test_cleanup"
        )
    }
}
