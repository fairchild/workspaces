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
    var onSurfaceCreated: (@MainActor (UUID) -> Void)?
    var onSurfaceInvalidated: (@MainActor (UUID) -> Void)?

    func view(
        for session: HostTerminalSession,
        onProcessExit: (() -> Void)? = nil,
        contextMenuProvider: (() -> NSMenu?)? = nil
    ) -> GhosttySurfaceView {
        if let existing = surfaces[session.id] {
            InvestigationDiagnostics.emitFocus(
                phase: "surface_store_reused",
                fields: ["session_id": session.id.uuidString]
            )
            sessionIDsBySurfaceIdentity[ObjectIdentifier(existing)] = session.id
            existing.contextMenuProvider = contextMenuProvider
            return existing
        }

        let sessionID = session.id
        let wrappedOnProcessExit: () -> Void = { [weak self] in
            Task { @MainActor in
                self?.invalidate(sessionID: sessionID)
                onProcessExit?()
            }
        }

        let created: GhosttySurfaceView
        if let customCommand = session.customCommand {
            created = GhosttySurfaceView(
                customCommand: customCommand,
                onProcessExit: wrappedOnProcessExit
            )
        } else {
            created = GhosttySurfaceView(
                workingDirectory: session.directoryURL,
                onProcessExit: wrappedOnProcessExit
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

    func invalidate(sessionID: UUID) {
        if let removed = surfaces.removeValue(forKey: sessionID) {
            sessionIDsBySurfaceIdentity.removeValue(forKey: ObjectIdentifier(removed))
        }
        onSurfaceInvalidated?(sessionID)
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

    func makeNSView(context: Context) -> GhosttySurfaceView {
        GhosttySurfaceView(
            workingDirectory: workingDirectory,
            onProcessExit: onProcessExit
        )
    }

    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
        _ = context
        _ = nsView
    }
}

struct PersistentHostTerminalContainerView: View {
    let session: HostTerminalSession
    let surfaceStore: HostTerminalSurfaceStore
    var onProcessExit: (() -> Void)?
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
    var onProcessExit: (() -> Void)?

    func makeNSView(context: Context) -> GhosttySurfaceView {
        surfaceStore.view(
            for: session,
            onProcessExit: onProcessExit,
            contextMenuProvider: contextMenuProvider
        )
    }

    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
        _ = context
        nsView.contextMenuProvider = contextMenuProvider
    }
}
