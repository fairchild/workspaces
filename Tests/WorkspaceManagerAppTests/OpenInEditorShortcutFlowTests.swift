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
