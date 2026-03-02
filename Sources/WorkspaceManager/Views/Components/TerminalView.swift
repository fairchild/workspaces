//
//  TerminalView.swift
//  WorkspaceManager
//

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

    func view(for session: HostTerminalSession, onProcessExit: (() -> Void)? = nil) -> GhosttySurfaceView {
        if let existing = surfaces[session.id] {
            sessionIDsBySurfaceIdentity[ObjectIdentifier(existing)] = session.id
            return existing
        }

        let sessionID = session.id
        let created = GhosttySurfaceView(
            workingDirectory: session.directoryURL,
            onProcessExit: { [weak self] in
                Task { @MainActor in
                    self?.invalidate(sessionID: sessionID)
                    onProcessExit?()
                }
            }
        )
        surfaces[session.id] = created
        sessionIDsBySurfaceIdentity[ObjectIdentifier(created)] = session.id

        return created
    }

    func terminal(for sessionID: UUID) -> GhosttySurfaceView? {
        surfaces[sessionID]
    }

    func sessionID(for terminal: GhosttySurfaceView) -> UUID? {
        sessionIDsBySurfaceIdentity[ObjectIdentifier(terminal)]
    }

    func invalidate(sessionID: UUID) {
        if let removed = surfaces.removeValue(forKey: sessionID) {
            sessionIDsBySurfaceIdentity.removeValue(forKey: ObjectIdentifier(removed))
        }
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
    var onProcessExit: (() -> Void)?

    func makeNSView(context: Context) -> GhosttySurfaceView {
        surfaceStore.view(for: session, onProcessExit: onProcessExit)
    }

    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
        _ = context
        _ = nsView
    }
}
