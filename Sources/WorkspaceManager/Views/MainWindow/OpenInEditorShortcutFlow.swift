//
//  OpenInEditorShortcutFlow.swift
//  WorkspaceManager
//
//  Shared shortcut flow helpers for Open in Editor behavior.
//

import Foundation

enum OpenInEditorTarget: Equatable {
    case project(rootURL: URL)
    case projectAndFile(rootURL: URL, fileURL: URL)
}

enum OpenInEditorLaunchTrigger: String {
    case shortcut
    case uiPrimaryAction
    case uiMenuSelection
    case unknown
}

enum OpenInEditorShortcutFlow {
    @MainActor
    static func syncRouting(for target: OpenInEditorTarget?) {
        if target != nil {
            ShortcutRoutingPolicy.shared.setOverride(
                .appChrome,
                for: AppChromeShortcut.openInEditor.chord
            )
        } else {
            ShortcutRoutingPolicy.shared.setOverride(
                nil,
                for: AppChromeShortcut.openInEditor.chord
            )
        }
    }

    @MainActor
    static func perform(
        target: OpenInEditorTarget?,
        editorID: ExternalEditorID?,
        externalEditorService: any ExternalEditorServiceProtocol,
        trigger: OpenInEditorLaunchTrigger = .unknown
    ) throws {
        guard let target else {
            NSLog(
                "[EditorLaunch] metric=open_in_editor_launch status=skipped reason=no_target trigger=%@",
                trigger.rawValue
            )
            return
        }

        let resolvedEditorID = editorID ?? externalEditorService.defaultEditor
        let targetKind = target.metricKind
        let attemptID = UUID()

        PerformanceSignposts.beginOpenInEditorLaunch(
            attemptID: attemptID,
            trigger: trigger.rawValue,
            editorID: resolvedEditorID.rawValue,
            targetKind: targetKind
        )

        do {
            switch target {
            case .projectAndFile(let rootURL, let fileURL):
                try externalEditorService.open(
                    projectRootURL: rootURL,
                    fileURL: fileURL,
                    editor: editorID
                )
            case .project(let rootURL):
                try externalEditorService.open(
                    projectRootURL: rootURL,
                    editor: editorID
                )
            }

            PerformanceSignposts.endOpenInEditorLaunchIfNeeded(
                attemptID: attemptID,
                trigger: trigger.rawValue,
                editorID: resolvedEditorID.rawValue,
                targetKind: targetKind,
                outcome: "success",
                failureReason: nil
            )
        } catch {
            PerformanceSignposts.endOpenInEditorLaunchIfNeeded(
                attemptID: attemptID,
                trigger: trigger.rawValue,
                editorID: resolvedEditorID.rawValue,
                targetKind: targetKind,
                outcome: "failure",
                failureReason: failureReason(for: error)
            )
            throw error
        }
    }

    private static func failureReason(for error: Error) -> String {
        guard let editorError = error as? ExternalEditorError else {
            return "unexpected_error"
        }

        switch editorError {
        case .projectRootNotFound:
            return "project_root_not_found"
        case .fileNotFound:
            return "file_not_found"
        case .fileOutsideProject:
            return "file_outside_project"
        case .editorNotInstalled:
            return "editor_not_installed"
        case .editorCLIUnavailable:
            return "editor_cli_unavailable"
        case .launchFailed:
            return "launch_failed"
        }
    }
}

private extension OpenInEditorTarget {
    var metricKind: String {
        switch self {
        case .project:
            return "project"
        case .projectAndFile:
            return "project_and_file"
        }
    }
}
