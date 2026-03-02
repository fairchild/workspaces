//
//  OpenInEditorShortcutFlowTests.swift
//  WorkspaceManagerAppTests
//
//  End-to-end shortcut flow regression tests for Open in Editor behavior.
//

import Foundation
import Testing

@testable import WorkspaceManager

@MainActor
@Suite("OpenInEditorShortcutFlow", .serialized)
struct OpenInEditorShortcutFlowTests {
    private struct MetricEvent: Equatable {
        let phase: String
        let fields: [String: String]
    }

    @Test("Launch metrics record success and duration for shortcut trigger")
    func launchMetricsRecordSuccessForShortcutTrigger() throws {
        let service = RecordingExternalEditorService()
        let projectRootURL = URL(fileURLWithPath: "/tmp/workspaces-shortcut-success")
        let target = OpenInEditorTarget.project(rootURL: projectRootURL)

        let events = try captureOpenInEditorMetricEvents {
            try OpenInEditorShortcutFlow.perform(
                target: target,
                editorID: nil,
                externalEditorService: service,
                trigger: .shortcut
            )
        }

        #expect(events.count == 2)
        guard events.count == 2 else { return }
        #expect(events[0].phase == "started")
        #expect(events[0].fields["metric"] == "open_in_editor_launch")
        #expect(events[0].fields["status"] == "started")
        #expect(events[0].fields["trigger"] == "shortcut")
        #expect(events[0].fields["editor"] == "zed")
        #expect(events[0].fields["target"] == "project")

        #expect(events[1].phase == "completed")
        #expect(events[1].fields["metric"] == "open_in_editor_launch")
        #expect(events[1].fields["status"] == "completed")
        #expect(events[1].fields["outcome"] == "success")
        #expect(events[1].fields["failure_reason"] == nil)
        #expect(events[1].fields["duration_ms"] != nil)
    }

    @Test("Launch metrics record categorized failure reason")
    func launchMetricsRecordCategorizedFailureReason() {
        let service = FailingExternalEditorService(error: .editorNotInstalled(.zed))
        let projectRootURL = URL(fileURLWithPath: "/tmp/workspaces-shortcut-failure")
        let target = OpenInEditorTarget.project(rootURL: projectRootURL)

        var events: [MetricEvent] = []
        PerformanceSignposts.setOpenInEditorMetricObserver { phase, fields in
            events.append(MetricEvent(phase: phase, fields: fields))
        }
        defer {
            PerformanceSignposts.setOpenInEditorMetricObserver(nil)
        }

        do {
            try OpenInEditorShortcutFlow.perform(
                target: target,
                editorID: .zed,
                externalEditorService: service,
                trigger: .uiPrimaryAction
            )
            Issue.record("Expected editorNotInstalled error")
        } catch let error as ExternalEditorError {
            #expect(error == .editorNotInstalled(.zed))
        } catch {
            Issue.record("Expected ExternalEditorError, got \(error)")
        }

        #expect(events.count == 2)
        guard events.count == 2 else { return }
        #expect(events[1].phase == "completed")
        #expect(events[1].fields["status"] == "completed")
        #expect(events[1].fields["outcome"] == "failure")
        #expect(events[1].fields["failure_reason"] == "editor_not_installed")
        #expect(events[1].fields["duration_ms"] != nil)
    }

    @Test("No-target guardrail skips launch without metric interval")
    func noTargetGuardrailSkipsLaunchWithoutMetricInterval() throws {
        let service = RecordingExternalEditorService()

        let events = try captureOpenInEditorMetricEvents {
            try OpenInEditorShortcutFlow.perform(
                target: nil,
                editorID: nil,
                externalEditorService: service,
                trigger: .shortcut
            )
        }

        #expect(events.isEmpty)
        #expect(service.calls.isEmpty)
    }

    @Test("Shortcut routing falls back to Ghostty when no open target exists")
    func shortcutRoutingFallsBackToGhosttyWithoutTarget() {
        ShortcutRoutingPolicy.shared.clearOverrides()
        defer { ShortcutRoutingPolicy.shared.clearOverrides() }

        OpenInEditorShortcutFlow.syncRouting(for: nil)

        #expect(ShortcutRoutingPolicy.shared.route(for: AppChromeShortcut.openInEditor.chord) == .ghostty)
    }

    @Test("Repo-selected shortcut opens project root only")
    func repoSelectedShortcutOpensProjectRootOnly() throws {
        let service = RecordingExternalEditorService()
        let projectRootURL = URL(fileURLWithPath: "/tmp/workspaces-shortcut-repo-only")

        ShortcutRoutingPolicy.shared.clearOverrides()
        defer { ShortcutRoutingPolicy.shared.clearOverrides() }

        let target = OpenInEditorTarget.project(rootURL: projectRootURL)
        OpenInEditorShortcutFlow.syncRouting(for: target)

        #expect(ShortcutRoutingPolicy.shared.route(for: AppChromeShortcut.openInEditor.chord) == .appChrome)

        try OpenInEditorShortcutFlow.perform(
            target: target,
            editorID: nil,
            externalEditorService: service
        )

        #expect(service.calls == [.openProject(projectRootURL, editor: nil)])
    }

    @Test("File-selected shortcut opens project and active file")
    func fileSelectedShortcutOpensProjectAndFile() throws {
        let service = RecordingExternalEditorService()
        let projectRootURL = URL(fileURLWithPath: "/tmp/workspaces-shortcut-file")
        let fileURL = projectRootURL.appendingPathComponent("Sources/App/main.swift")

        ShortcutRoutingPolicy.shared.clearOverrides()
        defer { ShortcutRoutingPolicy.shared.clearOverrides() }

        let target = OpenInEditorTarget.projectAndFile(
            rootURL: projectRootURL,
            fileURL: fileURL
        )
        OpenInEditorShortcutFlow.syncRouting(for: target)

        #expect(ShortcutRoutingPolicy.shared.route(for: AppChromeShortcut.openInEditor.chord) == .appChrome)

        try OpenInEditorShortcutFlow.perform(
            target: target,
            editorID: .zed,
            externalEditorService: service
        )

        #expect(service.calls == [.openProjectAndFile(projectRootURL, fileURL, editor: .zed)])
    }

    private func captureOpenInEditorMetricEvents(
        _ body: () throws -> Void
    ) rethrows -> [MetricEvent] {
        var events: [MetricEvent] = []
        PerformanceSignposts.setOpenInEditorMetricObserver { phase, fields in
            events.append(MetricEvent(phase: phase, fields: fields))
        }
        defer {
            PerformanceSignposts.setOpenInEditorMetricObserver(nil)
        }
        try body()
        return events
    }
}

private final class RecordingExternalEditorService: ExternalEditorServiceProtocol {
    enum Call: Equatable {
        case openProject(URL, editor: ExternalEditorID?)
        case openProjectAndFile(URL, URL, editor: ExternalEditorID?)
    }

    var defaultEditor: ExternalEditorID = .zed
    var availableEditors: [ExternalEditorDescriptor] = []
    private(set) var calls: [Call] = []

    func open(projectRootURL: URL, editor: ExternalEditorID?) throws {
        calls.append(.openProject(projectRootURL, editor: editor))
    }

    func open(projectRootURL: URL, fileURL: URL, editor: ExternalEditorID?) throws {
        calls.append(.openProjectAndFile(projectRootURL, fileURL, editor: editor))
    }
}

private final class FailingExternalEditorService: ExternalEditorServiceProtocol {
    let defaultEditor: ExternalEditorID = .zed
    let availableEditors: [ExternalEditorDescriptor] = []
    private let error: ExternalEditorError

    init(error: ExternalEditorError) {
        self.error = error
    }

    func open(projectRootURL: URL, editor: ExternalEditorID?) throws {
        throw error
    }

    func open(projectRootURL: URL, fileURL: URL, editor: ExternalEditorID?) throws {
        throw error
    }
}
