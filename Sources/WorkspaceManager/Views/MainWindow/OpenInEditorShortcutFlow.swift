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
        externalEditorService: any ExternalEditorServiceProtocol
    ) throws {
        guard let target else { return }

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
    }
}
