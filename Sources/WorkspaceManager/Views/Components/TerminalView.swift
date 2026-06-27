//
//  TerminalView.swift
//  WorkspaceManager
//

import AppKit
import SwiftUI
import WorkspaceManagerCore

enum TerminalPaneChromePolicy: Equatable, Sendable {
    case minimal

    static let current: Self = .minimal

    var showsPaneHeader: Bool {
        false
    }

    var showsManualRestartControl: Bool {
        false
    }
}

@MainActor
final class HostTerminalSurfaceStore {
    private var surfaces: [UUID: GhosttySurfaceView] = [:]
    private var sessionIDsBySurfaceIdentity: [ObjectIdentifier: UUID] = [:]
    var hooksSocketPath: String?
    var onSurfaceCreated: (@MainActor (UUID) -> Void)?
    var onSurfaceInvalidated: (@MainActor (UUID) -> Void)?

    func view(
        for session: HostTerminalSession,
        onProcessExit: (() -> Void)? = nil,
        onCloseConfirmationRequired: (() -> Void)? = nil,
        contextMenuProvider: (() -> NSMenu?)? = nil
    ) -> GhosttySurfaceView {
        let sessionID = session.id
        let wrappedOnProcessExit: () -> Void = { [weak self] in
            Task { @MainActor in
                self?.invalidate(sessionID: sessionID)
                onProcessExit?()
            }
        }

        if let existing = surfaces[session.id] {
            InvestigationDiagnostics.emitFocus(
                phase: "surface_store_reused",
                fields: ["session_id": session.id.uuidString]
            )
            sessionIDsBySurfaceIdentity[ObjectIdentifier(existing)] = session.id
            existing.onProcessExit = wrappedOnProcessExit
            existing.onCloseConfirmationRequired = onCloseConfirmationRequired
            existing.contextMenuProvider = contextMenuProvider
            return existing
        }

        let created: GhosttySurfaceView
        if let customCommand = session.customCommand {
            created = GhosttySurfaceView(
                customCommand: customCommand,
                onProcessExit: wrappedOnProcessExit,
                onCloseConfirmationRequired: onCloseConfirmationRequired
            )
        } else {
            created = GhosttySurfaceView(
                workingDirectory: session.directoryURL,
                hostSessionID: session.id,
                hooksSocketPath: hooksSocketPath,
                onProcessExit: wrappedOnProcessExit,
                onCloseConfirmationRequired: onCloseConfirmationRequired
            )
        }
        surfaces[session.id] = created
        sessionIDsBySurfaceIdentity[ObjectIdentifier(created)] = session.id
        created.contextMenuProvider = contextMenuProvider
        InvestigationDiagnostics.emitFocus(
            phase: "surface_store_created",
            fields: [
                "session_id": session.id.uuidString,
                "command_mode": session.customCommand == nil ? "directory" : "custom",
            ]
        )
        onSurfaceCreated?(session.id)

        return created
    }

    func terminal(for sessionID: UUID) -> GhosttySurfaceView? {
        let terminal = surfaces[sessionID]
        InvestigationDiagnostics.emitFocus(
            phase: terminal == nil ? "surface_store_lookup_miss" : "surface_store_lookup_hit",
            fields: ["session_id": sessionID.uuidString]
        )
        return terminal
    }

    func sessionID(for terminal: GhosttySurfaceView) -> UUID? {
        sessionIDsBySurfaceIdentity[ObjectIdentifier(terminal)]
    }

    func displayTitle(for session: HostTerminalSession) -> String {
        if let terminalTitle = surfaces[session.id]?.terminalTitle,
            !terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return terminalTitle
        }

        let fallback = session.directoryURL.lastPathComponent
        return fallback.isEmpty ? "Terminal" : fallback
    }

    func invalidate(sessionID: UUID) {
        if let removed = surfaces.removeValue(forKey: sessionID) {
            sessionIDsBySurfaceIdentity.removeValue(forKey: ObjectIdentifier(removed))
        }
        onSurfaceInvalidated?(sessionID)
    }

    @discardableResult
    func retire(sessionID: UUID) -> Bool {
        guard let removed = surfaces.removeValue(forKey: sessionID) else {
            onSurfaceInvalidated?(sessionID)
            return false
        }

        sessionIDsBySurfaceIdentity.removeValue(forKey: ObjectIdentifier(removed))
        removed.forceCloseForSessionRetirement()
        onSurfaceInvalidated?(sessionID)
        return true
    }
}

struct TerminalContainerView: View {
    let workingDirectory: URL
    let processExitContext: String
    let chromePolicy: TerminalPaneChromePolicy = .current

    static func identityToken(for workingDirectory: URL) -> String {
        workingDirectory.path
    }

    @ViewBuilder
    private var terminalSurface: some View {
        switch chromePolicy {
        case .minimal:
            GhosttyTerminalRepresentable(
                workingDirectory: workingDirectory,
                onProcessExit: {
                    NSLog("[GhosttyTerminal] Process exited for %@", processExitContext)
                }
            )
        }
    }

    var body: some View {
        terminalSurface
            .id(Self.identityToken(for: workingDirectory))
    }
}

extension TerminalContainerView {
    init(workspace: Workspace) {
        self.init(
            workingDirectory: workspace.workspaceURL,
            processExitContext: "workspace '\(workspace.name)'"
        )
    }

    init(hostDirectory: URL) {
        self.init(
            workingDirectory: hostDirectory,
            processExitContext: "host terminal"
        )
    }
}

struct GhosttyTerminalRepresentable: NSViewRepresentable {
    let workingDirectory: URL
    var onProcessExit: (() -> Void)?

    func makeNSView(context: Context) -> GhosttyTerminalScrollContainerView {
        let surfaceView = GhosttySurfaceView(
            workingDirectory: workingDirectory,
            onProcessExit: onProcessExit
        )
        return GhosttyTerminalScrollContainerView(surfaceView: surfaceView)
    }

    func updateNSView(_ nsView: GhosttyTerminalScrollContainerView, context: Context) {
        _ = context
        _ = nsView
    }
}

struct PersistentHostTerminalContainerView: View {
    let session: HostTerminalSession
    let surfaceStore: HostTerminalSurfaceStore
    var onProcessExit: (() -> Void)?
    var onCloseConfirmationRequired: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    let chromePolicy: TerminalPaneChromePolicy = .current

    static func identityToken(for sessionID: UUID) -> UUID {
        sessionID
    }

    @ViewBuilder
    private var terminalSurface: some View {
        switch chromePolicy {
        case .minimal:
            PersistentHostGhosttyRepresentable(
                session: session,
                surfaceStore: surfaceStore,
                contextMenuProvider: contextMenuProvider,
                onCloseConfirmationRequired: onCloseConfirmationRequired,
                onProcessExit: {
                    NSLog("[GhosttyTerminal] Process exited for host session %@", session.id.uuidString)
                    onProcessExit?()
                }
            )
        }
    }

    var body: some View {
        terminalSurface
            .id(Self.identityToken(for: session.id))
    }
}

private struct PersistentHostGhosttyRepresentable: NSViewRepresentable {
    let session: HostTerminalSession
    let surfaceStore: HostTerminalSurfaceStore
    var contextMenuProvider: (() -> NSMenu?)?
    var onCloseConfirmationRequired: (() -> Void)?
    var onProcessExit: (() -> Void)?

    func makeNSView(context: Context) -> GhosttyTerminalScrollContainerView {
        let surfaceView = surfaceStore.view(
            for: session,
            onProcessExit: onProcessExit,
            onCloseConfirmationRequired: onCloseConfirmationRequired,
            contextMenuProvider: contextMenuProvider
        )
        return GhosttyTerminalScrollContainerView(surfaceView: surfaceView)
    }

    func updateNSView(_ nsView: GhosttyTerminalScrollContainerView, context: Context) {
        _ = context
        nsView.surfaceView.onCloseConfirmationRequired = onCloseConfirmationRequired
        nsView.updateContextMenuProvider(contextMenuProvider)
    }
}
